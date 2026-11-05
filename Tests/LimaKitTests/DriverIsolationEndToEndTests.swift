import Foundation
import NetworkKit
import Testing
@testable import LimaKit

/// The isolation profile of HanaLima's driver (docs/06 §7, docs/09 stage 4): a VM with
/// `vmOpts.hanalima.usernet: false` has no Lima user-mode network. First with no NIC at all:
/// SSH and the guest agent arrive over vsock, port forwarding still works through Lima's SSH
/// tunnel, and the guest reaches nothing (no route, no DNS, not the host). Then with one NIC on
/// a HanaLima host-only network: the guest reaches that subnet's gateway (the Mac) and still
/// not the internet.
///
/// Needs `scripts/build-app.sh` first. The guest needs systemd 256+ (sshd on vsock), so the
/// default template is ubuntu-lts; `HANALIMA_E2E_TEMPLATE` can pick another. A few minutes.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DriverIsolationEndToEndTests {
    let vm = "hanalima-e2e-isolated"
    static let template = ProcessInfo.processInfo.environment["HANALIMA_E2E_TEMPLATE"] ?? "ubuntu-lts"
    static let helpers = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/Helpers")
    let client = LimaClient(limactlURL: LimaClient.locate()!,
                            environment: ProcessInfo.processInfo.environment.merging(["LIMA_DRIVERS_PATH": helpers.path]) { $1 })
    let network = VirtualNetwork(name: "e2e-isolated", mode: .host, gateway: "192.168.239.1", prefixLength: 24)

    @Test(.timeLimit(.minutes(15)))
    func isolatedVMReachesOnlyItsOwnNetwork() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "lima-driver-hanalima").path),
                     "run scripts/build-app.sh first")
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm], environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }

        // 1. No NIC at all.
        _ = try await drain(client.create(CreateOptions(
            name: vm, template: Self.template, cpus: 2, memoryGiB: 2, diskGiB: 10, vmType: .hanalima,
            setExpressions: [".vmOpts.hanalima.usernet = false"])))
        let created = try #require(try await client.list().first { $0.name == vm })
        #expect(!created.usesUsernet)
        let dir = URL(filePath: created.dir, directoryHint: .isDirectory)
        let started = Date.now
        _ = try await drain(client.start(vm))
        print("isolated: boot \(Int(Date.now.timeIntervalSince(started))) s")
        let log = (try? String(contentsOf: dir.appending(path: "driver.stderr.log"), encoding: .utf8)) ?? ""
        #expect(log.contains("usernet is off"))
        #expect(log.contains("ssh over vsock"))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "default_ep.sock").path), "no usernet process")
        // eth0 exists (Lima's MAC, so cloud-init's network config applies) but has no carrier.
        #expect(try await sh("ip -o link show eth0 | grep -c NO-CARRIER") == "1")
        #expect(try await sh("ip -4 -o addr show | grep -v ' lo ' | wc -l") == "0", "no address on any NIC")
        #expect(try await sh("ip route | wc -l") == "0", "no route at all")
        #expect(try await sh("curl -s -m 3 -o /dev/null http://1.1.1.1/ && echo reachable || echo unreachable") == "unreachable")
        #expect(try await sh("ping -c1 -W1 192.168.5.2 >/dev/null 2>&1 && echo reachable || echo unreachable") == "unreachable")
        #expect(try await sh("getent hosts example.com >/dev/null 2>&1 && echo resolves || echo no-dns") == "no-dns")
        #expect(try await sh("cloud-init status 2>/dev/null | head -1") == "status: done", "Lima's boot scripts don't need the network")
        #expect(try await sh("systemctl is-active systemd-networkd-wait-online.service; true") != "failed", "eth0 is optional, nothing waits for it")
        // The guest agent over vsock, and Lima's port forwarding through the SSH tunnel.
        #expect(try await sh("ps -eo args | grep -c '[l]ima-guestagent daemon.*vsock-port 2222'") == "1")
        _ = try await sh("mkdir -p /tmp/www && echo isolated > /tmp/www/index.html && (nohup python3 -m http.server 18082 -d /tmp/www >/dev/null 2>&1 &)")
        let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 3; return c }())
        var forwarded = ""
        for _ in 0..<20 {
            try await Task.sleep(for: .seconds(1))
            if let data = try? await session.data(from: URL(string: "http://127.0.0.1:18082/")!).0,
               let text = String(data: data, encoding: .utf8) { forwarded = text; break }
        }
        #expect(forwarded.contains("isolated"))
        _ = try await drain(client.stop(vm))

        // 2. One NIC on a HanaLima host-only network: that subnet and nothing else.
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
        _ = try await drain(client.edit(vm, set: [#".networks = [{"socket": "\#(network.socketPath)"}]"#]))
        _ = try await drain(client.start(vm))
        #expect(try await sh("ip -4 -o addr show lima0 | grep -c 192.168.239.") == "1")
        #expect(try await sh("ping -c1 -W2 192.168.239.1 >/dev/null 2>&1 && echo reachable || echo unreachable") == "reachable", "the Mac on that subnet")
        #expect(try await sh("curl -s -m 3 -o /dev/null http://1.1.1.1/ && echo reachable || echo unreachable") == "unreachable", "host-only: no internet")
        #expect(try await sh("ping -c1 -W1 192.168.5.2 >/dev/null 2>&1 && echo reachable || echo unreachable") == "unreachable")
        _ = try await drain(client.stop(vm))
        for name in ["hanalima.pid", "hanalima.drv.sock", DriverControl.socketName, DriverControl.serialSocketName] {
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: name).path), Comment(rawValue: name))
        }
    }

    private func sh(_ script: String) async throws -> String {
        let out = try? await client.runner.run(["shell", vm, "sh", "-c", script])
        if out == nil { print("failed: \(script.prefix(80))") }
        return (out?.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
