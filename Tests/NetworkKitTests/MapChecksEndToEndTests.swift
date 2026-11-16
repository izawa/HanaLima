import AgentKit
import Foundation
import LimaKit
import Testing
@testable import NetworkKit

/// The network map's reachability checks (docs/16 §5) on real guests: a router and a client on a
/// throwaway guest-only network, planned from the map and run with `limactl shell` as the app does.
/// The pings are bound to the NIC found by its MAC (`ping -I`). Stopping the router turns the
/// client's router probe into "couldn't confirm". Needs `scripts/build-app.sh` first.
/// `HANALIMA_E2E_TEMPLATE` changes the guest (alpine by default; ubuntu-lts checks iputils' ping).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct MapChecksEndToEndTests {
    static let template = ProcessInfo.processInfo.environment["HANALIMA_E2E_TEMPLATE"] ?? "alpine"
    let routerMAC = "52:55:55:e2:e1:01", clientMAC = "52:55:55:e2:e1:02"
    var network: VirtualNetwork {
        VirtualNetwork(name: "e2e-mapcheck", mode: .guestOnly, gateway: "192.168.234.254", prefixLength: 24,
                       reservations: [DHCPReservation(mac: routerMAC, ip: "192.168.234.1", comment: "router"),
                                      DHCPReservation(mac: clientMAC, ip: "192.168.234.11", comment: "client")],
                       router: "192.168.234.1")
    }
    let router = "hanalima-e2e-map-router", clientVM = "hanalima-e2e-map-client"
    let agents = LaunchAgentManager()
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    static var bundledHelper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/HanaLima.app/Contents/Helpers/hanalima-netd")
    }

    @Test(.timeLimit(.minutes(15)))
    func pingsBoundToEachNIC() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.bundledHelper.path), "run scripts/build-app.sh first")
        try HelperInstaller.installIfNeeded(from: Self.bundledHelper)
        let network = network
        var saved = try NetworkStore.load().filter { $0.name != network.name }
        let original = saved
        saved.append(network)
        try NetworkStore.save(saved)
        defer {
            agents.uninstall(network.name)
            try? NetworkStore.save(original)
        }
        try agents.install(network)

        let vms = [router, clientVM]
        for vm in vms { _ = try? await drain(client.delete(vm, force: true)) }
        defer { E2ECleanup.deleteInstances(vms) }
        for (vm, mac) in [(router, routerMAC), (clientVM, clientMAC)] {
            _ = try await drain(client.create(CreateOptions(name: vm, template: Self.template, cpus: 1, memoryGiB: 1, diskGiB: 10, vmType: .vz)))
            _ = try await drain(client.edit(vm, set: [#".networks = [{"socket":"\#(network.socketPath)","macAddress":"\#(mac)"}]"#]))
        }
        for vm in vms { _ = try await drain(client.start(vm)) }
        // Lima is ready before DHCP on the extra NIC.
        for vm in vms {
            for _ in 0..<30 {
                let out = (try? await client.runner.run(["shell", vm, "ip", "-4", "-o", "addr"]))?.stdoutString ?? ""
                if out.contains("192.168.234.") { break }
                try await Task.sleep(for: .seconds(2))
            }
        }

        func check(_ vm: String) async throws -> MapCheckRecord {
            let list = try await client.list()
            let map = NetworkMap.build(instances: list.filter { vms.contains($0.name) }, networks: [network],
                                       limaNetworks: [], leases: DHCPLeases.load())
            let probes = try #require(MapChecks.plan(map, vms: [vm], outside: nil) { _ in nil }[vm])
            var output = ""
            for try await line in client.runScript(in: vm, script: MapChecks.script(probes: probes, macs: [clientMAC, routerMAC]), asRoot: false) {
                if case .stdout(let s) = line { output += s + "\n" }
            }
            return MapChecks.record(probes: probes, output: output, runError: nil, at: .now)
        }

        let fromClient = try await check(clientVM)
        let clientTargets: [MapProbe.Target] = [.router("192.168.234.1")]  // the router is also the peer: one ping
        let clientGot = fromClient.probes.map(\.target)
        #expect(clientGot == clientTargets)
        #expect(fromClient.outcomes.values.allSatisfy { $0.reached })
        #expect(fromClient.observed[clientMAC] == ["192.168.234.11"])
        #expect(MapChecks.state(bus: network.socketPath, in: fromClient) == .reached)

        let fromRouter = try await check(router)
        let routerTargets: [MapProbe.Target] = [.peer(vm: clientVM, ip: "192.168.234.11")]
        let routerGot = fromRouter.probes.map(\.target)
        #expect(routerGot == routerTargets)
        #expect(fromRouter.outcomes.values.allSatisfy { $0.reached })

        _ = try await drain(client.stop(router))
        let alone = try await check(clientVM)
        #expect(alone.outcomes.values.allSatisfy { !$0.reached && $0.reason == "no reply" })
        #expect(MapChecks.state(bus: network.socketPath, in: alone) == .unverified)
    }
}

private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
