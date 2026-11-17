import Foundation
import LimaKit
import Testing
@testable import NetworkKit

/// One VM with two NICs on the same guest-only network: each NIC gets its own lease, the lease
/// lookup by MAC finds each NIC's address (not one for both, as by name), and netd's DNS answers
/// the VM's name with both addresses, lowest first, to a real resolver in the guest. Alpine on
/// Lima's vz, one boot. Needs `scripts/build-app.sh` first; don't run it alongside the other
/// guest-only suites.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct TwoNICEndToEndTests {
    var network: VirtualNetwork {
        VirtualNetwork(name: "e2e-twonic", mode: .guestOnly, gateway: "192.168.230.1", prefixLength: 24)
    }
    let vm = "hanalima-e2e-twonic"
    let macs = ["52:55:55:e2:20:01", "52:55:55:e2:20:02"]
    let agents = LaunchAgentManager()
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(10)))
    func eachNICHasItsAddressAndTheNameBoth() async throws {
        let helper = GuestOnlyEndToEndTests.bundledHelper
        try #require(FileManager.default.isExecutableFile(atPath: helper.path), "run scripts/build-app.sh first")
        try HelperInstaller.installIfNeeded(from: helper)
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

        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm]) }
        _ = try await drain(client.create(CreateOptions(name: vm, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10, vmType: .vz)))
        let nics = macs.map { #"{"socket":"\#(network.socketPath)","macAddress":"\#($0)"}"# }.joined(separator: ",")
        _ = try await drain(client.edit(vm, set: [".networks = [\(nics)]"]))
        _ = try await drain(client.start(vm))

        let a = try await address(on: "lima0")
        let b = try await address(on: "lima1")
        #expect(a != b)

        // The lease lookup by MAC gives each NIC its own address.
        let subnet = try #require(network.subnet)
        let leases = DHCPLeases.parse(try String(contentsOf: NetworkPaths.leases(for: network.name), encoding: .utf8))
        #expect(DHCPLeases.address(mac: macs[0], instance: vm, in: subnet, leases: leases)?.ip == a)
        #expect(DHCPLeases.address(mac: macs[1], instance: vm, in: subnet, leases: leases)?.ip == b)

        // netd's DNS: both addresses, lowest first, as a real resolver reads them.
        let out = try await sh("nslookup lima-\(vm) 192.168.230.1")
        let answered = out.split(separator: "\n").dropFirst(2).compactMap { $0.firstMatch(of: /(192\.168\.230\.\d+)/).map { String($0.1) } }
        let expected = [a, b].sorted { IPv4($0)! < IPv4($1)! }
        #expect(answered == expected, "\(out)")

        _ = try await drain(client.stop(vm))
    }

    /// The lease on `iface`, not the link-local address dhcpcd may pick while waiting.
    private func address(on iface: String) async throws -> String {
        for _ in 0..<30 {
            if let m = try await sh("ip -4 -o addr show \(iface) 2>/dev/null").firstMatch(of: /inet (192\.168\.230\.\d+)/) { return String(m.1) }
            try await Task.sleep(for: .seconds(2))
        }
        throw NSError(domain: "e2e", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(vm): no address on \(iface)"])
    }

    private func sh(_ script: String) async throws -> String {
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
