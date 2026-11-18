import Foundation
import LimaKit
import Testing
@testable import NetworkKit

/// A `hanalima` Alpine VM on a guest-only network, hibernated and resumed several times: after
/// each resume the driver takes the NICs' links down and up, the guest's DHCP client confirms its
/// lease, and netd grants it again (its expiry moves on). Prints, per round, whether the guest
/// saw the link go down and how many DHCP requests reached netd (a packet capture): a request
/// sent right as the link came back could be lost, and Alpine's dhcpcd then kept its lease
/// without asking again (why the driver keeps the link down for three seconds). `HANALIMA_E2E_ROUNDS`
/// (default 3) and `HANALIMA_E2E_HIBERNATE_SECONDS` (default 5) set the rounds and how long each
/// hibernation lasts. Needs `scripts/build-app.sh` first and the Mac unlocked; don't run it
/// alongside the other guest-only suites.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct HibernateLeaseEndToEndTests {
    var network: VirtualNetwork {
        VirtualNetwork(name: "e2e-hiblease", mode: .guestOnly, gateway: "192.168.229.1", prefixLength: 24)
    }
    let vm = "hanalima-e2e-hiblease"
    let mac = "52:55:55:e2:29:01"
    let rounds = Int(ProcessInfo.processInfo.environment["HANALIMA_E2E_ROUNDS"] ?? "") ?? 3
    let pause = Double(ProcessInfo.processInfo.environment["HANALIMA_E2E_HIBERNATE_SECONDS"] ?? "") ?? 5
    static let helpers = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "build/HanaLima.app/Contents/Helpers")
    let agents = LaunchAgentManager()
    let client = LimaClient(limactlURL: LimaClient.locate()!,
                            environment: ProcessInfo.processInfo.environment.merging(["LIMA_DRIVERS_PATH": helpers.path]) { $1 })

    @Test(.timeLimit(.minutes(60)))
    func resumedGuestsConfirmTheirLease() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "lima-driver-hanalima").path),
                     "run scripts/build-app.sh first")
        try #require(rounds >= 1 && pause.isFinite && pause >= 0, "HANALIMA_E2E_ROUNDS ≥ 1, HANALIMA_E2E_HIBERNATE_SECONDS ≥ 0")
        try HelperInstaller.installIfNeeded(from: GuestOnlyEndToEndTests.bundledHelper)
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
        defer { E2ECleanup.deleteInstances([vm], environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }
        _ = try await drain(client.create(CreateOptions(name: vm, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10,
                                                        vmType: .hanalima, mountNone: true)))
        _ = try await drain(client.edit(vm, set: [#".networks = [{"socket":"\#(network.socketPath)","macAddress":"\#(mac)"}]"#]))
        let dir = URL(filePath: try #require(try await client.list().first { $0.name == vm }).dir, directoryHint: .isDirectory)
        _ = try await drain(client.start(vm))
        _ = try await address()
        let bootID = try await sh("cat /proc/sys/kernel/random/boot_id")
        try #require(!bootID.isEmpty)
        let control = NetworkPaths.control(for: network.name).path
        var regranted = 0
        for round in 1...rounds {
            let before = try #require(leaseExpiry(), "a lease before round \(round)")
            let carrierBefore = try await carrierLost()
            let capture = try #require(try NetdControl.send(.init(op: .startCapture), to: control).capture)
            defer {  // also when the round throws
                _ = try? NetdControl.send(.init(op: .stopCapture, capture: capture.id), to: control)
                for suffix in ["", ".partial", ".json"] { try? FileManager.default.removeItem(atPath: capture.file + suffix) }
            }
            _ = try DriverControl.send(DriverControl.Request(op: .hibernate), instanceDir: dir, timeout: 120)
            try await Task.sleep(for: .seconds(pause))
            _ = try await drain(client.start(vm))
            // A resume, not a fresh boot (which would lease anew and prove nothing).
            #expect(try await sh("cat /proc/sys/kernel/random/boot_id") == bootID, "round \(round) resumed the saved state")
            // The guest asks again within seconds of the relink, or not at all.
            var after = before
            for _ in 0..<30 where after <= before {
                try await Task.sleep(for: .seconds(1))
                after = leaseExpiry() ?? before
            }
            let sawLink = try await carrierLost() > carrierBefore
            if after > before { regranted += 1 }
            // What reached netd: the guest's DHCP requests (to port 67) and netd's answers (to 68).
            _ = try? NetdControl.send(.init(op: .stopCapture, capture: capture.id), to: control)
            let frames = ObservationEndToEndTests.frames(in: (try? Data(contentsOf: URL(filePath: capture.file))) ?? Data())
            let requests = frames.filter { ObservationEndToEndTests.isUDP($0, port: 67) }.count
            let answers = frames.filter { ObservationEndToEndTests.isUDP($0, port: 68) }.count
            print("round \(round): lease \(after > before ? "granted again" : "NOT granted again"), guest \(sawLink ? "saw" : "did NOT see") the link go down, netd got \(requests) DHCP request(s) and sent \(answers) answer(s)")
        }
        #expect(regranted == rounds, "\(regranted) of \(rounds) resumes confirmed the lease")
        _ = try await drain(client.stop(vm))
    }

    /// When netd's lease for the VM's NIC ends.
    private func leaseExpiry() -> Date? {
        guard let text = try? String(contentsOf: NetworkPaths.leases(for: network.name), encoding: .utf8) else { return nil }
        return DHCPLeases.parse(text).first { DHCPLeases.mac(of: $0) == mac }?.expires
    }

    /// How many times the guest's DHCP client logged the link going down (both logs, so a
    /// rotation in between doesn't hide one).
    private func carrierLost() async throws -> Int {
        Int(try await sh("sudo cat /var/log/messages.0 /var/log/messages 2>/dev/null | grep -c 'lima0: carrier lost' || true")) ?? 0
    }

    private func address() async throws -> String {
        for _ in 0..<30 {
            if let m = try await sh("ip -4 -o addr show lima0 2>/dev/null").firstMatch(of: /inet (192\.168\.229\.\d+)/) { return String(m.1) }
            try await Task.sleep(for: .seconds(2))
        }
        throw NSError(domain: "e2e", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(vm): no address on lima0"])
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
