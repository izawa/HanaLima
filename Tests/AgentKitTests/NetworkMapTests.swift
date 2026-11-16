import Foundation
import Testing
@testable import AgentKit
import LimaKit
import NetworkKit

struct NetworkMapTests {
    private func vm(_ name: String, running: Bool = true, nics: [NetworkAttachment] = [],
                    usernet: Bool = true, vmType: String = "hanalima") -> LimaInstance {
        var inst = try! JSONDecoder().decode(LimaInstance.self, from: Data("""
            {"name": "\(name)", "status": "\(running ? "Running" : "Stopped")", "dir": "/tmp/\(name)", "vmType": "\(vmType)"}
            """.utf8))
        inst.networks = nics
        if !usernet { inst.config = .object(["vmOpts": .object(["hanalima": .object(["usernet": .bool(false)])])]) }
        return inst
    }

    private func nic(_ net: VirtualNetwork, _ mac: String) -> NetworkAttachment {
        NetworkAttachment(socket: net.socketPath, macAddress: mac)
    }

    private let lab = VirtualNetwork(name: "lab", mode: .guestOnly, gateway: "10.20.0.254",
                                     reservations: [DHCPReservation(mac: "52:55:55:00:00:01", ip: "10.20.0.1", comment: "gateway")],
                                     router: "10.20.0.1")
    private let demo = VirtualNetwork(name: "demo", mode: .shared, gateway: "192.168.200.1")

    @Test func wiresVMsToTheirNetworks() {
        let lease = DHCPLease(name: "lima-guest1", ip: "10.20.0.11", hwAddress: "1,52:55:55:0:0:2", expires: .distantFuture)
        let map = NetworkMap.build(
            instances: [vm("gateway", nics: [nic(lab, "52:55:55:00:00:01")]),
                        vm("guest1", nics: [nic(lab, "52:55:55:00:00:02")], usernet: false),
                        vm("dev", nics: [nic(demo, "52:55:55:00:00:03"), NetworkAttachment(vzNAT: true)], vmType: "vz")],
            networks: [lab, demo], limaNetworks: [], leases: [lease])

        #expect(map.rows.map(\.name) == ["gateway", "guest1", "dev"])
        let gateway = map.rows[0], guest1 = map.rows[1], dev = map.rows[2]
        #expect(gateway.routerOf == [lab.socketPath])
        #expect(gateway.ports.first?.addresses == [.init(ip: "10.20.0.1", source: .reservation)])
        #expect(guest1.ports.first?.addresses == [.init(ip: "10.20.0.11", source: .lease)])
        #expect(guest1.usernet == false)
        #expect(dev.vzNAT && dev.usernet)
        #expect(dev.ports.map(\.bus) == [demo.socketPath])  // vzNAT is no bus
        let labBus = map.buses.first { $0.id == lab.socketPath }
        #expect(labBus?.kind == .guestOnly(router: "10.20.0.1", routerVM: "gateway"))
        #expect(labBus?.macOnSegment == false)
        #expect(map.mac.ports.map(\.bus) == [demo.socketPath])  // the Mac isn't on guest-only networks
        #expect(map.mac.ports.first?.addresses.first?.ip == "192.168.200.1")
        #expect(map.members(of: lab.socketPath).map(\.name) == ["gateway", "guest1"])
    }

    @Test func showsOnlyCurrentLeasesOfRunningVMs() {
        let old = DHCPLease(name: "lima-a", ip: "192.168.200.20", hwAddress: "", expires: .distantPast)
        let stopped = DHCPLease(name: "lima-b", ip: "192.168.200.21", hwAddress: "", expires: .distantFuture)
        let map = NetworkMap.build(instances: [vm("a", nics: [nic(demo, "52:55:55:00:00:0a")]),
                                               vm("b", running: false, nics: [nic(demo, "52:55:55:00:00:0b")])],
                                   networks: [demo], limaNetworks: [], leases: [old, stopped])
        #expect(map.rows.allSatisfy { $0.ports.first?.addresses.isEmpty == true })
    }

    @Test func aRouterNoVMHoldsIsUnassigned() {
        let map = NetworkMap.build(instances: [vm("x", nics: [nic(lab, "52:55:55:00:00:09")])],
                                   networks: [lab], limaNetworks: [], leases: [])
        #expect(map.buses.first?.kind == .guestOnly(router: "10.20.0.1", routerVM: nil))
        #expect(map.rows[0].routerOf.isEmpty)
    }

    @Test func deletedAndLimaNetworksAndTwoNICsOnOneNetwork() {
        let gone = NetworkAttachment(socket: NetworkPaths.socket(for: "old").path, macAddress: "52:55:55:00:00:0c")
        let map = NetworkMap.build(
            instances: [vm("a", nics: [gone, NetworkAttachment(lima: "user-v2"), nic(demo, "52:55:55:00:00:0d"), nic(demo, "52:55:55:00:00:0e")])],
            networks: [demo], limaNetworks: [LimaNetworks.Network(name: "user-v2", mode: "user-v2")], leases: [])
        let kinds = Dictionary(uniqueKeysWithValues: map.buses.map { ($0.name, $0.kind) })
        #expect(kinds["old"] == .deleted)
        #expect(kinds["lima:user-v2"] == .lima(mode: "user-v2"))
        #expect(map.buses.first { $0.name == "lima:user-v2" }?.macOnSegment == false)
        #expect(map.rows[0].ports.count == 3)  // the two demo NICs share one dot
        #expect(map.rows[0].ports.first { $0.bus == demo.socketPath }?.macs == ["52:55:55:00:00:0d", "52:55:55:00:00:0e"])
    }

    @Test func leasesFollowEachNICAndBridgesIgnoreReservations() {
        let l1 = DHCPLease(name: "lima-a", ip: "192.168.200.31", hwAddress: "1,52:55:55:0:0:31", expires: .distantFuture)
        let l2 = DHCPLease(name: "lima-a", ip: "192.168.200.32", hwAddress: "1,52:55:55:0:0:32", expires: .distantFuture)
        let lan = VirtualNetwork(name: "lan", mode: .bridged, reservations: [DHCPReservation(mac: "52:55:55:00:00:33", ip: "192.168.200.50", comment: "")])
        let map = NetworkMap.build(instances: [vm("a", nics: [nic(demo, "52:55:55:00:00:31"), nic(demo, "52:55:55:00:00:32"), nic(lan, "52:55:55:00:00:33")])],
                                   networks: [demo, lan], limaNetworks: [], leases: [l1, l2])
        let ports = Dictionary(uniqueKeysWithValues: map.rows[0].ports.map { ($0.bus, $0) })
        #expect(ports[demo.socketPath]?.addresses.map(\.ip) == ["192.168.200.31", "192.168.200.32"])
        #expect(ports[lan.socketPath]?.addresses.isEmpty == true)
        let outside = NetworkMap.build(instances: [vm("b", nics: [NetworkAttachment(socket: "/tmp/mine.sock")])],
                                       networks: [], limaNetworks: [], leases: [])
        #expect(outside.buses.first?.kind == .socket)
    }

    @Test func ordersBusesForTheFewestCrossings() {
        func row(_ name: String, _ buses: [String]) -> NetworkMap.Row {
            .init(kind: .vm, name: name, running: true, vmType: nil, group: nil,
                  ports: buses.map { .init(bus: $0, nics: []) }, usernet: true, vzNAT: false, vzNATMAC: nil, routerOf: [])
        }
        func bus(_ id: String) -> NetworkMap.Bus { .init(id: id, name: id, kind: .nat, subnet: nil, gateway: nil, macOnSegment: true) }
        // "a" is used most, so it would come first; but two rows on b+c would then cross a.
        let rows = [row("1", ["a"]), row("2", ["a"]), row("3", ["a"]), row("4", ["b", "c"]), row("5", ["b", "c"]), row("6", ["a", "c"])]
        let order = NetworkMap.order([bus("a"), bus("b"), bus("c")], rows: rows).map(\.id)
        let total = rows.reduce(0) { $0 + NetworkMap.crossings($1, order: order) }
        #expect(total == 2)
        #expect(NetworkMap.crossings(row("x", ["c"]), order: ["a", "b", "c"]) == 2)
        #expect(NetworkMap.crossings(row("x", []), order: ["a", "b", "c"]) == 0)
    }
}
