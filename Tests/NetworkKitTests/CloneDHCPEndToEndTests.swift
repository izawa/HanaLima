import Foundation
import LimaKit
import NetworkKit
import Testing

/// A VM and its `limactl clone` copy on one HanaLima network, without reservations, must get
/// different addresses. The copy keeps the guest's DUID (a file on the disk), and bootpd
/// identifies a client by its DHCP client identifier when one is sent. `HANALIMA_E2E_TEMPLATE`
/// picks the guest (default alpine). Needs `scripts/build-app.sh` first.
/// Run with `HANALIMA_E2E=1 swift test --filter CloneDHCPEndToEnd`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct CloneDHCPEndToEndTests {
    static let template = ProcessInfo.processInfo.environment["HANALIMA_E2E_TEMPLATE"] ?? "alpine"
    let vm = "hanalima-e2e-dupsrc"
    let copy = "hanalima-e2e-dupcopy"
    let agents = LaunchAgentManager()
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(20)))
    func copiesGetDifferentAddresses() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: NetworkEndToEndTests.bundledHelper.path),
                     "run scripts/build-app.sh first")
        try HelperInstaller.installIfNeeded(from: NetworkEndToEndTests.bundledHelper)
        // A throwaway subnet: a helper killed mid-test leaves it unusable until reboot.
        let third = Int.random(in: 10...250)
        let network = VirtualNetwork(name: "e2e-dup", mode: .shared, gateway: "10.252.\(third).1", prefixLength: 24)
        let original = try NetworkStore.load().filter { $0.name != network.name }
        try NetworkStore.save(original + [network])
        try agents.install(network)
        defer {
            agents.uninstall(network.name)
            try? NetworkStore.save(original)
        }

        for name in [vm, copy] { _ = try? await drain(client.delete(name, force: true)) }
        defer { E2ECleanup.deleteInstances([vm, copy]) }
        _ = try await drain(client.create(CreateOptions(name: vm, template: Self.template, cpus: 2, memoryGiB: 2,
                                                        diskGiB: 10, vmType: .vz, mountNone: true,
                                                        setExpressions: [#".networks = [{"socket":"\#(network.socketPath)"}]"#])))
        _ = try await drain(client.start(vm))  // the guest writes its DUID on the first boot
        _ = try await drain(client.stop(vm))
        _ = try await drain(client.clone(vm, as: copy))

        _ = try await drain(client.start(vm))
        _ = try await drain(client.start(copy))
        let a = try await lima0Address(vm)
        let b = try await lima0Address(copy)
        print("source:", a, "copy:", b)
        #expect(!a.isEmpty && !b.isEmpty && a != b)

        for name in [vm, copy] { _ = try await drain(client.delete(name, force: true)) }
    }

    private func lima0Address(_ name: String) async throws -> String {
        for _ in 0..<30 {
            let out = (try? await client.runner.run(["shell", name, "ip", "-4", "-o", "addr", "show", "lima0"]))?.stdoutString ?? ""
            if let ip = out.firstMatch(of: /inet (\d+\.\d+\.\d+\.\d+)/).map({ String($0.1) }), !ip.hasPrefix("169.254.") {
                return ip
            }
            try await Task.sleep(for: .seconds(2))
        }
        Issue.record("\(name): lima0 got no DHCP address")
        return ""
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
