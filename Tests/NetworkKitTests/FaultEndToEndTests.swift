import Foundation
import LimaKit
import Testing
@testable import NetworkKit

/// Faults on a guest-only network (docs/18) with the real helper and two Alpine VMs: a block set
/// before boot keeps the VM's DHCP from getting through, a delay lengthens pings to it, a loss
/// drops part of them, and a block ends by itself at its deadline. Needs `scripts/build-app.sh`
/// first; don't run it alongside the other guest-only E2E suites.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct FaultEndToEndTests {
    var network: VirtualNetwork {
        VirtualNetwork(name: "e2e-fault", mode: .guestOnly, gateway: "192.168.232.254", prefixLength: 24)
    }
    let vms = ["hanalima-e2e-fault-a", "hanalima-e2e-fault-b"]
    let macs = ["52:55:55:e2:fa:01", "52:55:55:e2:fa:02"]
    let agents = LaunchAgentManager()
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(20)))
    func delayLossAndBlock() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: ObservationEndToEndTests.bundledHelper.path), "run scripts/build-app.sh first")
        try HelperInstaller.installIfNeeded(from: ObservationEndToEndTests.bundledHelper)
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
        let control = NetworkPaths.control(for: network.name).path
        let a = macs[0]

        // Before any VM: a block on A (the control socket starts the helper).
        let block = try #require(try NetdControl.send(.init(op: .startFault, fault: .init(target: a, block: true, seconds: 600)), to: control).faults?.first)
        #expect(throws: NetdControl.Failure.self) {
            try NetdControl.send(.init(op: .startFault, fault: .init(target: NetworkFault.Spec.everyone, delayMs: 10, seconds: 60)), to: control)
        }

        for vm in vms { _ = try? await drain(client.delete(vm, force: true)) }
        defer { E2ECleanup.deleteInstances(vms) }
        for (vm, mac) in zip(vms, macs) {
            _ = try await drain(client.create(CreateOptions(name: vm, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10, vmType: .vz)))
            _ = try await drain(client.edit(vm, set: [#".networks = [{"socket":"\#(network.socketPath)","macAddress":"\#(mac)"}]"#]))
        }
        for vm in vms { _ = try await drain(client.start(vm)) }
        _ = try await lima0Address(vms[1])
        #expect(try await sh(vms[0], "ip -4 -o addr show lima0").contains("inet 192.168.232.") == false, "A got no lease through the block")
        let blockedCount = try port(a).droppedBlocked.frames
        #expect(blockedCount > 0, "A's DHCP requests were block")

        // Remove the block: A's DHCP client gets its lease.
        _ = try NetdControl.send(.init(op: .stopFault, faultID: block.id), to: control)
        let addressA = try await lima0Address(vms[0], tries: 60)

        // Delay on A: pings from B to A take about 100 ms longer.
        let before = try #require(try await pingAverage(from: vms[1], to: addressA))
        _ = try NetdControl.send(.init(op: .startFault, fault: .init(target: a, delayMs: 100, seconds: 120)), to: control)
        let delayed = try #require(try await pingAverage(from: vms[1], to: addressA))
        #expect(delayed - before >= 90, "RTT \(before) → \(delayed) ms")
        #expect(try port(a).droppedFull.frames == 0)
        _ = try NetdControl.send(.init(op: .stopFault), to: control)

        // Loss on A: some pings get through, and the loss counter grows.
        let lostBefore = try port(a).droppedLoss.frames
        _ = try NetdControl.send(.init(op: .startFault, fault: .init(target: a, lossPercent: 50, seconds: 120)), to: control)
        let received = try await sh(vms[1], "ping -c 30 -W 1 \(addressA) | sed -n 's/.* \\([0-9]*\\) packets received.*/\\1/p'")
        _ = try NetdControl.send(.init(op: .stopFault), to: control)
        try await Task.sleep(for: .seconds(2))
        #expect(try port(a).droppedLoss.frames - lostBefore >= 5)
        #expect((Int(received) ?? 0) > 0 && (Int(received) ?? 30) < 30, "received \(received) of 30")

        // A 10-second block ends by itself.
        _ = try NetdControl.send(.init(op: .startFault, fault: .init(target: a, block: true, seconds: 10)), to: control)
        #expect(try await sh(vms[1], "ping -c 2 -W 1 \(addressA) >/dev/null && echo ok") != "ok")
        try await Task.sleep(for: .seconds(11))
        #expect(try await sh(vms[1], "ping -c 3 -W 2 \(addressA) >/dev/null && echo ok") == "ok")
        #expect(try NetdControl.send(.init(op: .status), to: control).faults?.isEmpty == true)

        for vm in vms { _ = try await drain(client.stop(vm)) }
    }

    /// The live port of the helper that learned `mac`.
    private func port(_ mac: String) throws -> NetworkObservation.Port {
        try #require(NetworkDaemonStatus.load(for: network.name)?.observation?.ports.first { $0.connected && $0.macs.contains(mac) })
    }

    /// The average round trip of a few pings, in milliseconds.
    private func pingAverage(from vm: String, to address: String) async throws -> Double? {
        let out = try await sh(vm, "ping -c 5 -W 3 \(address)")
        return out.firstMatch(of: /= [\d.]+\/([\d.]+)\//).flatMap { Double($0.1) }
    }

    private func lima0Address(_ vm: String, tries: Int = 30) async throws -> String {
        for _ in 0..<tries {
            let out = try await sh(vm, "ip -4 -o addr show lima0 2>/dev/null")
            // The lease, not the link-local address dhcpcd picks while DHCP gets no answer.
            if let m = out.firstMatch(of: /inet (192\.168\.232\.\d+)/) { return String(m.1) }
            try await Task.sleep(for: .seconds(2))
        }
        throw NSError(domain: "e2e", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(vm): no address on lima0"])
    }

    private func sh(_ vm: String, _ script: String) async throws -> String {
        let out = try? await client.runner.run(["shell", vm, "sh", "-c", script])
        return (out?.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
