import Foundation
import LimaKit
import Testing
@testable import NetworkKit

/// A guest-only network (stage 5): hanalima-netd switches frames between the VMs itself, with no
/// vmnet and no host interface. Two Alpine VMs on Lima's vz (no driver needed) get distinct
/// addresses from netd's DHCP (one reserved), reach each other, get the reserved one as the
/// default route of that NIC (the network names it as the router) while usernet's route on eth0
/// keeps the internet, resolve each other's `lima-<name>` through netd's DNS while the internet still resolves
/// through usernet's, can't reach the server address with ICMP (only ARP answers), and the Mac
/// has no interface on the subnet. Needs `scripts/build-app.sh` first.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct GuestOnlyEndToEndTests {
    let reservedMAC = "52:55:55:e2:e0:01"
    var network: VirtualNetwork {
        VirtualNetwork(name: "e2e-guestonly", mode: .guestOnly, gateway: "192.168.233.1", prefixLength: 24,
                       reservations: [DHCPReservation(mac: reservedMAC, ip: "192.168.233.50", comment: "e2e")],
                       router: "192.168.233.50")
    }
    let vms = ["hanalima-e2e-guest-a", "hanalima-e2e-guest-b"]
    let agents = LaunchAgentManager()
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    static var bundledHelper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/HanaLima.app/Contents/Helpers/hanalima-netd")
    }

    @Test(.timeLimit(.minutes(15)))
    func twoVMsTalkOnlyToEachOther() async throws {
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
        #expect(FileManager.default.fileExists(atPath: network.socketPath))

        for vm in vms { _ = try? await drain(client.delete(vm, force: true)) }
        defer { E2ECleanup.deleteInstances(vms) }
        for (i, vm) in vms.enumerated() {
            _ = try await drain(client.create(CreateOptions(name: vm, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10, vmType: .vz)))
            let nic = i == 0 ? #"{"socket":"\#(network.socketPath)","macAddress":"\#(reservedMAC)"}"# : #"{"socket":"\#(network.socketPath)"}"#
            _ = try await drain(client.edit(vm, set: [".networks = [\(nic)]"]))
        }
        for vm in vms { _ = try await drain(client.start(vm)) }
        guard case .running = agents.state(of: network.name) else {
            Issue.record("helper not running: \(agents.state(of: network.name))")
            return
        }
        #expect(NetworkDaemonStatus.load(for: network.name)?.clients.count == 2)

        // Addresses: the reservation lands, the other VM gets a different pool address.
        let a = try await lima0Address(vms[0])
        let b = try await lima0Address(vms[1])
        print("guest-only: a=\(a) b=\(b)")
        #expect(a == "192.168.233.50")
        #expect(b != a)
        #expect(IPv4(b).map { network.subnet!.contains($0) } == true)
        // The router (VM a) is the default route on lima0 for VM b; usernet's route on eth0 has
        // the lower metric, so the internet still goes there. VM a is the router itself and gets
        // the same option (a route to its own address is harmless on Linux). netd's DNS
        // resolves the other VM, bare and under the search domain, and refuses anything else.
        // Lima's Alpine keeps cloud-init's resolv.conf (usernet's resolver only) while usernet
        // is on, so the server is asked directly here; an isolated VM uses it as its resolver
        // (DriverIsolationEndToEndTests). The internet still resolves through usernet's.
        #expect(try await sh(vms[1], "ip route show dev lima0 | grep -c 'default via 192.168.233.50'; true") == "1")
        #expect(try await sh(vms[1], "ip route show default | head -1 | grep -c eth0; true") == "1", "usernet stays the preferred route")
        #expect(try await sh(vms[0], "nslookup lima-\(vms[1]) \(network.gateway) 2>/dev/null | grep -c 'Address: \(b)$'") == "1")
        #expect(try await sh(vms[0], "nslookup lima-\(vms[1]).hanalima \(network.gateway) 2>/dev/null | grep -c 'Address: \(b)$'") == "1")
        #expect(try await sh(vms[0], "nslookup example.com \(network.gateway) >/dev/null 2>&1 && echo resolves || echo refused") == "refused")
        #expect(try await sh(vms[0], "nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1 && echo ok") == "ok", "the internet still resolves")
        // They reach each other; the server address answers ARP but nothing else.
        #expect(try await sh(vms[0], "ping -c 2 -W 2 \(b) >/dev/null && echo ok") == "ok")
        #expect(try await sh(vms[1], "ping -c 2 -W 2 \(a) >/dev/null && echo ok") == "ok")
        #expect(try await sh(vms[0], "ping -c 1 -W 1 \(network.gateway) >/dev/null 2>&1 && echo reachable || echo unreachable") == "unreachable")
        #expect(try await sh(vms[0], "ip neigh show \(network.gateway) | grep -c lladdr") == "1", "ARP for the server address is answered")
        // The Mac is not on the segment.
        #expect(!(try await hostInterfaces()).contains("192.168.233."))
        // netd's lease file names both VMs, and the app's merged lease view finds them.
        let leases = DHCPLeases.load()
        #expect(DHCPLeases.address(of: vms[0], in: network.subnet!, leases: leases) == a)
        #expect(DHCPLeases.address(of: vms[1], in: network.subnet!, leases: leases) == b)

        for vm in vms { _ = try await drain(client.stop(vm)) }
        try await Task.sleep(for: .seconds(2))
        #expect(NetworkDaemonStatus.load(for: network.name)?.clients.isEmpty ?? true)
    }

    private func lima0Address(_ vm: String) async throws -> String {
        for _ in 0..<30 {
            let out = try await sh(vm, "ip -4 -o addr show lima0 2>/dev/null")
            if let m = out.firstMatch(of: /inet (\d+\.\d+\.\d+\.\d+)/) { return String(m.1) }
            try await Task.sleep(for: .seconds(2))
        }
        throw NSError(domain: "e2e", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(vm): no address on lima0"])
    }

    private func sh(_ vm: String, _ script: String) async throws -> String {
        let out = try? await client.runner.run(["shell", vm, "sh", "-c", script])
        if out == nil { print("failed: \(vm): \(script.prefix(80))") }
        return (out?.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hostInterfaces() async throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: "/sbin/ifconfig")
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
