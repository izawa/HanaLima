import Foundation
import LimaKit
import Testing
@testable import NetworkKit

/// Bridges a real VM to a host interface through hanalima-netd (no root) and checks that it gets a
/// LAN address, can reach the host, and that the host interface keeps its IPv4 address.
///
/// This puts the host interface into a bridge, so it only runs when asked for explicitly:
/// `HANALIMA_E2E_BRIDGE=en0 swift test --filter BridgeEndToEnd` (after `scripts/build-app.sh`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E_BRIDGE"] != nil))
struct BridgeEndToEndTests {
    let interface = ProcessInfo.processInfo.environment["HANALIMA_E2E_BRIDGE"] ?? "en0"
    var network: VirtualNetwork { VirtualNetwork(name: "e2e-bridge", mode: .bridged, bridgedInterface: interface) }
    let vm = "hanalima-e2e-bridge"
    let agents = LaunchAgentManager()
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(15)))
    func vmJoinsLAN() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: NetworkEndToEndTests.bundledHelper.path),
                     "run scripts/build-app.sh first")
        try HelperInstaller.installIfNeeded(from: NetworkEndToEndTests.bundledHelper)
        let hostIP = try #require(hostAddress(), "\(interface) has no IPv4 address")

        let original = try NetworkStore.load().filter { $0.name != network.name }
        try NetworkStore.save(original + [network])
        defer {
            agents.uninstall(network.name)
            try? NetworkStore.save(original)
        }
        try agents.install(network)

        _ = try? await drain(client.delete(vm, force: true))
        _ = try await drain(client.create(CreateOptions(name: vm, template: "alpine", cpus: 1, memoryGiB: 1,
                                                        diskGiB: 10, vmType: .vz,
                                                        setExpressions: [#".networks = [{"socket":"\#(network.socketPath)"}]"#])))
        // Twice: the second boot gets a new bridged interface from the same helper process.
        for boot in 1...2 {
            _ = try await drain(client.start(vm))
            #expect(NetworkDaemonStatus.load(for: network.name)?.clients.count == 1)
            let ip = try await lima0Address()
            print("boot \(boot): lima0 \(ip), host \(interface) \(hostAddress() ?? "none")")
            #expect(!ip.isEmpty)
            #expect(hostAddress() == hostIP)
            let ping = try await client.runner.run(["shell", vm, "ping", "-c", "2", "-W", "2", hostIP])
            #expect(ping.stdoutString.contains("2 packets received"))
            _ = try await drain(client.stop(vm))
        }
        _ = try await drain(client.delete(vm))
        agents.uninstall(network.name)
        #expect(hostAddress() == hostIP)
    }

    private func hostAddress() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        p.arguments = ["getifaddr", interface]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let ip = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ip.isEmpty ? nil : ip
    }

    /// The LAN's DHCP server may answer a few seconds after `limactl start` returns, so poll.
    private func lima0Address() async throws -> String {
        for _ in 0..<30 {
            let out = (try? await client.runner.run(["shell", vm, "ip", "-4", "-o", "addr", "show", "lima0"]))?.stdoutString ?? ""
            if let ip = out.firstMatch(of: /inet (\d+\.\d+\.\d+\.\d+)/).map({ String($0.1) }), !ip.hasPrefix("169.254.") {
                return ip
            }
            try await Task.sleep(for: .seconds(2))
        }
        Issue.record("lima0 got no DHCP address")
        return ""
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
