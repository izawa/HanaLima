import Foundation
import LimaKit
import Testing
@testable import NetworkKit

/// Registers a real LaunchAgent, boots an Alpine VM on it and checks DHCP, host access and
/// helper status. Needs `scripts/build-app.sh` first (for the entitlement-signed helper).
/// Run with `HANALIMA_E2E=1 swift test --filter NetworkEndToEnd`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct NetworkEndToEndTests {
    let network = VirtualNetwork(name: "e2e-test", mode: .shared, gateway: "192.168.231.1", prefixLength: 24)
    let vm = "hanalima-e2e-net"
    let agents = LaunchAgentManager()
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    static var bundledHelper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/HanaLima.app/Contents/Helpers/hanalima-netd")
    }

    @Test(.timeLimit(.minutes(10)))
    func vmGetsAddressOnVirtualNetwork() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.bundledHelper.path),
                     "run scripts/build-app.sh first")
        try HelperInstaller.installIfNeeded(from: Self.bundledHelper)

        var saved = try NetworkStore.load().filter { $0.name != network.name }
        let original = saved
        saved.append(network)
        try NetworkStore.save(saved)
        defer {
            agents.uninstall(network.name)
            try? NetworkStore.save(original)
        }
        try agents.install(network)
        #expect(agents.state(of: network.name) != .notLoaded)
        #expect(FileManager.default.fileExists(atPath: network.socketPath))

        _ = try? await drain(client.delete(vm, force: true))
        defer { Task { [client, vm] in _ = try? await drain(client.delete(vm, force: true)) } }
        let opts = CreateOptions(name: vm, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10, vmType: .vz)
        _ = try await drain(client.create(opts))
        _ = try await drain(client.edit(vm, set: [#".networks = [{"socket":"\#(network.socketPath)"}]"#]))
        _ = try await drain(client.start(vm))

        // launchd started the helper on the VM's connection.
        guard case .running = agents.state(of: network.name) else {
            Issue.record("helper not running: \(agents.state(of: network.name))")
            return
        }
        #expect(NetworkDaemonStatus.load(for: network.name)?.clients.count == 1)

        let addr = try await client.runner.run(["shell", vm, "ip", "-4", "-o", "addr", "show", "lima0"]).stdoutString
        print("lima0:", addr)
        let ip = try #require(addr.firstMatch(of: /inet (\d+\.\d+\.\d+\.\d+)/).map { String($0.1) })
        #expect(network.subnet!.contains(IPv4(ip)!))

        // Guest reaches the host side of the network.
        let ping = try await client.runner.run(["shell", vm, "ping", "-c", "2", "-W", "2", network.gateway])
        #expect(ping.stdoutString.contains("2 packets received"))

        _ = try await drain(client.stop(vm))
        _ = try await drain(client.delete(vm))
    }
}

/// DHCP reservations: a VM's NIC gets the reserved address after the network is reconfigured.
/// Alpine by default; `HANALIMA_E2E_TEMPLATE=ubuntu-lts` checks a guest that sends a DUID from
/// systemd-networkd (Alpine's dhcpcd is the other common client).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DHCPReservationEndToEndTests {
    static let template = ProcessInfo.processInfo.environment["HANALIMA_E2E_TEMPLATE"] ?? "alpine"
    let vm = template == "alpine" ? "hanalima-e2e-dhcp" : "hanalima-e2e-dhcp-\(template.prefix { $0 != "-" })"
    let agents = LaunchAgentManager()
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(20)))
    func reservedAddressIsAssigned() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: NetworkEndToEndTests.bundledHelper.path),
                     "run scripts/build-app.sh first")
        try HelperInstaller.installIfNeeded(from: NetworkEndToEndTests.bundledHelper)
        var network = VirtualNetwork(name: "e2e-dhcp", mode: .shared, gateway: "192.168.236.1", prefixLength: 24)

        let original = try NetworkStore.load().filter { $0.name != network.name }
        func save(_ n: VirtualNetwork) throws {
            try NetworkStore.save(original + [n])
            try agents.install(n)
        }
        defer {
            agents.uninstall(network.name)
            try? NetworkStore.save(original)
        }
        try save(network)

        _ = try? await drain(client.delete(vm, force: true))
        _ = try await drain(client.create(CreateOptions(name: vm, template: Self.template, cpus: 2, memoryGiB: 2,
                                                        diskGiB: 10, vmType: .vz,
                                                        setExpressions: [#".networks = [{"socket":"\#(network.socketPath)"}]"#])))
        _ = try await drain(client.start(vm))
        let first = try await lima0Address()
        print("before reservation:", first)

        // The guest uses the MAC Lima filled into the effective config.
        let inst = try #require(try await client.list().first { $0.name == vm })
        let mac = try #require(inst.networks?.first { $0.socket == network.socketPath }?.macAddress)
        print("guest MAC:", mac)

        network.reservations = [DHCPReservation(mac: mac, ip: "192.168.236.50", comment: vm)]
        #expect(network.validate(against: []).isEmpty)
        _ = try await drain(client.stop(vm))
        try save(network)
        _ = try await drain(client.start(vm))
        let second = try await lima0Address()
        print("after reservation:", second)
        #expect(second == "192.168.236.50")

        // A second boot on the same helper process must keep the reserved address.
        _ = try await drain(client.stop(vm))
        _ = try await drain(client.start(vm))
        let third = try await lima0Address()
        print("second boot:", third)
        #expect(third == "192.168.236.50")

        _ = try await drain(client.stop(vm))
        _ = try await drain(client.delete(vm))
    }

    /// `limactl start` can return before the guest's DHCP client finishes, so poll.
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
