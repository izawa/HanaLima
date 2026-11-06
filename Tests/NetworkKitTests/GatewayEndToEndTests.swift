import Foundation
import LimaKit
import Testing
@testable import NetworkKit

/// The gateway example behind a guest-only network's router: an Alpine gateway VM (Lima's NIC 0
/// out, a reserved address on the guest-only network that the network names as its router) and
/// an Alpine client VM on the same network. The client gets the gateway as its default route and
/// DNS, reaches an allowed host through it, cannot reach anything else, and can once "*" is added
/// and the example's script is run again. Both on Lima's vz. Needs `scripts/build-app.sh` first.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct GatewayEndToEndTests {
    let routerMAC = "52:55:55:e2:e0:10"
    let routerIP = "192.168.234.10"
    var network: VirtualNetwork {
        VirtualNetwork(name: "e2e-gateway", mode: .guestOnly, gateway: "192.168.234.1", prefixLength: 24,
                       reservations: [DHCPReservation(mac: routerMAC, ip: routerIP, comment: "e2e gateway")],
                       router: routerIP)
    }
    let gateway = "hanalima-e2e-gw"
    let client = "hanalima-e2e-gw-client"
    let agents = LaunchAgentManager()
    let lima = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(20)))
    func clientReachesOnlyTheAllowList() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: GuestOnlyEndToEndTests.bundledHelper.path), "run scripts/build-app.sh first")
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

        let vms = [gateway, client]
        for vm in vms { _ = try? await drain(lima.delete(vm, force: true)) }
        defer { E2ECleanup.deleteInstances(vms) }
        let example = ProvisionExamples.example(.gateway)
        _ = try await drain(lima.create(CreateOptions(
            name: gateway, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10, vmType: .vz, mountNone: true,
            setExpressions: [".provision = \(JSONValue.array(example.entries.map(\.json)).jsonText)",
                             #".networks = [{"socket":"\#(network.socketPath)","macAddress":"\#(routerMAC)"}]"#])))
        _ = try await drain(lima.create(CreateOptions(
            name: client, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10, vmType: .vz, mountNone: true,
            setExpressions: [#".networks = [{"socket":"\#(network.socketPath)"}]"#])))
        _ = try await drain(lima.start(gateway))
        _ = try await drain(lima.start(client))

        // The gateway did its job: table, forwarding, dnsmasq on lima0 only, NAT out of eth0.
        #expect(try await sh(gateway, "sudo nft list table inet hanalima | grep -c masquerade") == "1")
        #expect(try await sh(gateway, "cat /proc/sys/net/ipv4/ip_forward") == "1")
        #expect(try await sh(gateway, "grep -c 'except-interface=eth0' /etc/dnsmasq.d/hanalima-gateway.conf") == "1")
        #expect(try await sh(gateway, "grep -c 'nftset=/dl-cdn.alpinelinux.org/4#inet#hanalima#allowed' /etc/dnsmasq.d/hanalima-gateway.conf") == "1")

        // The client: netd handed out the gateway as the default route of lima0 and as DNS.
        let clientIP = try await lima0Address(client)
        print("gateway e2e: client \(clientIP), gateway \(routerIP)")
        #expect(try await sh(client, "ip route show dev lima0 | grep -c 'default via \(routerIP)'; true") == "1")
        // Make the guest-only NIC the only way out, as an isolated VM would have it: drop usernet's
        // default route (SSH stays: 192.168.5.0/24 is on-link) and resolve through the gateway.
        _ = try await sh(client, "sudo ip route del default dev eth0; printf 'nameserver \(routerIP)\\n' | sudo tee /etc/resolv.conf >/dev/null")
        #expect(try await sh(client, "ip route show default | grep -c lima0") == "1")
        #expect(try await sh(client, "ping -c 2 -W 2 \(routerIP) >/dev/null && echo ok") == "ok")
        // Names resolve through the gateway's dnsmasq; only the allowed host is reachable.
        #expect(try await sh(client, "nslookup example.com \(routerIP) >/dev/null 2>&1 && echo ok") == "ok", "the gateway resolves everything")
        #expect(try await sh(client, "wget -qO- --timeout=15 http://dl-cdn.alpinelinux.org/alpine/MIRRORS.txt | head -c 4 | wc -c | tr -d ' '") == "4", "allowed host")
        #expect(try await sh(client, "wget -qO- --timeout=5 http://example.com >/dev/null 2>&1 && echo reached || echo blocked") == "blocked")
        #expect(try await sh(client, "ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && echo reached || echo blocked") == "blocked")
        // The gateway learned the allowed host's addresses and logged the drops.
        #expect(try await sh(gateway, "sudo nft list set inet hanalima allowed | grep -c 'elements'") == "1")
        #expect(try await sh(gateway, "sudo dmesg | grep -c 'hanalima-gateway drop'") != "0")

        // Open it up: "*" in the allow list, then the example's script again (as "Run now" does).
        _ = try await sh(gateway, "echo '*' | sudo tee -a /etc/hanalima/gateway.conf >/dev/null")
        let script = example.entries.first { $0.mode == .system }!.script
        for try await _ in lima.runner.lines(["shell", "--tty=false", gateway, "sudo", "sh", "-s"], input: Data(script.utf8)) {}
        #expect(try await sh(gateway, "sudo nft list chain inet hanalima forward | grep -c 'oifname \"eth0\" accept'") == "1")
        #expect(try await sh(client, "wget -qO- --timeout=10 http://example.com >/dev/null 2>&1 && echo reached || echo blocked") == "reached")

        for vm in vms { _ = try await drain(lima.stop(vm)) }
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
        let out = try? await lima.runner.run(["shell", vm, "sh", "-c", script])
        if out == nil { print("failed: \(vm): \(script.prefix(80))") }
        return (out?.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
