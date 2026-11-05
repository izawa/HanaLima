import Foundation
import NetworkKit
import Testing
@testable import LimaKit

/// HanaLima's VM driver for Lima (Driver/, docs/09): a VM created with `--vm-type=hanalima`
/// boots under Lima through `lima-driver-hanalima` (VZ in the driver's process, NIC 0 on
/// `limactl usernet`), answers over SSH with DNS, the virtiofs share, the guest agent over
/// vsock and port forwarding, has its HanaLima-network NIC, vzNAT NIC and additional disk,
/// and stops without leaving processes, pid files or disk locks behind.
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

    let disk = "hanalima-e2e-driver-disk"
    let network = VirtualNetwork(name: "e2e-driver", mode: .shared, gateway: "192.168.237.1", prefixLength: 24)

    @Test(.timeLimit(.minutes(15)))
    func bootsUnderLimaWithTheDriver() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "lima-driver-hanalima").path),
                     "run scripts/build-app.sh first")
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm], environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }

        // A HanaLima network (netd) for a `socket:` NIC, and a raw additional disk (the driver
        // attaches raw only; Lima's vz converts qcow2 in place, this driver doesn't).
        _ = try HelperInstaller.installIfNeeded(from: Self.helpers.appending(path: "hanalima-netd"))
        let agents = LaunchAgentManager()
        var saved = try NetworkStore.load().filter { $0.name != network.name }
        let original = saved
        saved.append(network)
        try NetworkStore.save(saved)
        defer {
            agents.uninstall(network.name)
            try? NetworkStore.save(original)
        }
        try agents.install(network)
        _ = try? await drain(client.deleteDisk(disk))
        _ = try await drain(client.createDisk(disk, size: "1GiB", format: "raw"))
        defer { E2ECleanup.deleteDisks([disk]) }

        // Create must succeed before anything else: `limactl start <missing name>` would make a
        // VM from the default template instead.
        _ = try await drain(client.create(CreateOptions(
            name: vm, template: Self.template, cpus: 2, memoryGiB: 2, diskGiB: 10, vmType: .hanalima,
            setExpressions: [#".networks = [{"socket": "\#(network.socketPath)"}, {"vzNAT": true}]"#,
                             #".additionalDisks = [{"name": "\#(disk)"}]"#])))
        let created = try #require(try await client.list().first { $0.name == vm })
        #expect(created.vmType == "hanalima")
        let dir = URL(filePath: created.dir, directoryHint: .isDirectory)

        let started = Date.now
        do {
            _ = try await drain(client.start(vm))
        } catch {
            for name in ["driver.stderr.log", "ha.stderr.log", "hanalima-usernet.log"] {
                let text = (try? String(contentsOf: dir.appending(path: name), encoding: .utf8)) ?? ""
                print("--- \(name)\n" + text.split(separator: "\n").suffix(12).joined(separator: "\n"))
            }
            throw error
        }
        print("driver: boot \(Int(Date.now.timeIntervalSince(started))) s")
        let running = try #require(try await client.list().first { $0.name == vm })
        #expect(running.status == .running)

        // The guest: DNS through usernet's gateway (resolv.conf on Alpine, systemd-resolved on
        // Ubuntu), the home share, the guest agent.
        #expect(try await sh("{ cat /etc/resolv.conf; resolvectl status 2>/dev/null; } | grep -q 192.168.5.2 && echo ok") == "ok")
        #expect(try await sh("nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1 && echo ok") == "ok")
        #expect(try await sh("mount | grep -c virtiofs") == "1")
        #expect(try await sh("ls \(NSHomeDirectory()) >/dev/null && echo ok") == "ok")
        #expect(try await sh("ps -o args= 2>/dev/null | grep '[l]ima-guestagent' | grep -c 'vsock-port 2222'") != "0")
        // NIC 1 on the HanaLima network, NIC 2 on vzNAT, the additional disk mounted by Lima.
        #expect(try await sh("ip -4 -o addr show lima0 | grep -c 192.168.237.") == "1")
        #expect(try await sh("ip -4 -o addr show lima1 | grep -c 192.168.64.") == "1")
        let mounted = try await sh("mount | grep -c '/mnt/lima-\(disk)'")
        if mounted != "1" {
            print("--- disk not mounted; boot log around 05-lima-disks.sh:\n" +
                  (try await sh("sudo grep -n -B2 -A25 '05-lima-disks.sh' /var/log/cloud-init-output.log | tail -40; lsblk 2>/dev/null; ls -l /dev/vd*")))
        }
        #expect(mounted == "1")
        let lock = Self.limaHome.appending(path: "_disks/\(disk)/in_use_by")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: lock.path) == dir.path)
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
        #expect(!FileManager.default.fileExists(atPath: lock.path), "disk lock released")
    }

    static var limaHome: URL {
        URL(filePath: ProcessInfo.processInfo.environment["LIMA_HOME"] ?? NSHomeDirectory() + "/.lima", directoryHint: .isDirectory)
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
