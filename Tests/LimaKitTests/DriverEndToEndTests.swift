import Foundation
import Testing
@testable import LimaKit

/// HanaLima's VM driver for Lima (Driver/, docs/09): a VM created with `--vm-type=hanalima`
/// boots under Lima through `lima-driver-hanalima` (VZ in the driver's process, NIC 0 on
/// `limactl usernet`), answers over SSH with DNS, the virtiofs share and the guest agent, and
/// stops without leaving processes or pid files behind.
///
/// Needs `scripts/build-app.sh` first (the signed driver is in the app bundle).
/// `HANALIMA_E2E_TEMPLATE` picks the guest (default alpine). A few minutes.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DriverEndToEndTests {
    let vm = "hanalima-e2e-driver"
    static let template = ProcessInfo.processInfo.environment["HANALIMA_E2E_TEMPLATE"] ?? "alpine"
    static let helpers = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/Helpers")
    /// limactl with the bundle's driver on its path.
    let client = LimaClient(limactlURL: LimaClient.locate()!,
                            environment: ProcessInfo.processInfo.environment.merging(["LIMA_DRIVERS_PATH": helpers.path]) { $1 })

    @Test(.timeLimit(.minutes(15)))
    func bootsUnderLimaWithTheDriver() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "lima-driver-hanalima").path),
                     "run scripts/build-app.sh first")
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm], environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }

        // Create must succeed before anything else: `limactl start <missing name>` would make a
        // VM from the default template instead.
        _ = try await drain(client.create(CreateOptions(
            name: vm, template: Self.template, cpus: 2, memoryGiB: 2, diskGiB: 10, vmType: .hanalima)))
        let created = try #require(try await client.list().first { $0.name == vm })
        #expect(created.vmType == "hanalima")
        let dir = URL(filePath: created.dir, directoryHint: .isDirectory)

        let started = Date.now
        _ = try await drain(client.start(vm))
        print("driver: boot \(Int(Date.now.timeIntervalSince(started))) s")
        let running = try #require(try await client.list().first { $0.name == vm })
        #expect(running.status == .running)

        // The guest: DNS through usernet's gateway (resolv.conf on Alpine, systemd-resolved on
        // Ubuntu), the home share, the guest agent.
        #expect(try await sh("{ cat /etc/resolv.conf; resolvectl status 2>/dev/null; } | grep -q 192.168.5.2 && echo ok") == "ok")
        #expect(try await sh("nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1 && echo ok") == "ok")
        #expect(try await sh("mount | grep -c virtiofs") == "1")
        #expect(try await sh("ls \(NSHomeDirectory()) >/dev/null && echo ok") == "ok")
        #expect(try await sh("ps | grep -c '[l]ima-guestagent'") != "0")
        // Port forwarding (the guest agent reports the port over the forwarded ga.sock).
        // python3 where it exists (Ubuntu's image has no nc), busybox nc on Alpine.
        _ = try await sh("""
            mkdir -p /tmp/www && echo hanalima > /tmp/www/index.html
            if command -v python3 >/dev/null; then nohup python3 -m http.server 18080 -d /tmp/www >/dev/null 2>&1 &
            else nohup sh -c "while true; do printf 'HTTP/1.0 200 OK\\r\\n\\r\\nhanalima' | nc -l -p 18080; done" >/dev/null 2>&1 & fi
            """)
        let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 3; return c }())
        var forwarded = ""
        for _ in 0..<20 {
            try await Task.sleep(for: .seconds(1))
            if let data = try? await session.data(from: URL(string: "http://127.0.0.1:18080/")!).0,
               let text = String(data: data, encoding: .utf8) { forwarded = text; break }
        }
        #expect(forwarded.contains("hanalima"))

        let stopping = Date.now
        _ = try await drain(client.stop(vm))
        print("driver: stop \(Int(Date.now.timeIntervalSince(stopping))) s")
        let stopped = try #require(try await client.list().first { $0.name == vm })
        #expect(stopped.status == .stopped)
        for name in ["hanalima.pid", "hanalima-usernet.pid", "hanalima.drv.sock", "default_ep.sock", "default_fd.sock"] {
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: name).path), Comment(rawValue: name))
        }
        #expect(try await processes(matching: "lima-driver-hanalima --inst-dir \(dir.path)") == 0)
        #expect(try await processes(matching: "limactl usernet --endpoint \(dir.path)") == 0)
    }

    private func sh(_ script: String) async throws -> String {
        let out = try? await client.runner.run(["shell", vm, "sh", "-c", script])
        if out == nil { print("failed: \(script.prefix(80))") }
        return (out?.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func processes(matching pattern: String) async throws -> Int {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self).split(separator: "\n").count
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
