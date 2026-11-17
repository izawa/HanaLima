import Foundation
import LimaKit
import Synchronization
import NetworkKit

/// What the network map (docs/16) draws: networks as buses, the Mac and each VM as a row wired to
/// the buses it has a NIC on. Built from the configuration and the DHCP leases only; nothing here
/// says that traffic actually gets through.
public struct NetworkMap: Equatable, Sendable {
    public struct Bus: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case nat, hostOnly
            case bridged(interface: String)
            /// `router`: the router address set on the network; `routerVM`: the VM holding it.
            case guestOnly(router: String?, routerVM: String?)
            /// A Lima network (`lima:<name>`), with its mode from networks.yaml.
            case lima(mode: String)
            /// A NIC whose HanaLima network has been deleted.
            case deleted
            /// A `socket:` NIC outside HanaLima's networks (set up by hand).
            case socket
        }

        /// The socket path for HanaLima networks, `lima:<name>` for Lima's.
        public var id: String
        public var name: String
        public var kind: Kind
        public var subnet: String?
        /// For HanaLima's NAT and host-only networks, the Mac's address; for guest-only ones,
        /// netd's DHCP and DNS server.
        public var gateway: String?
        public var macOnSegment: Bool
    }

    public struct Address: Equatable, Sendable {
        /// `host`: the Mac's own address on the network. `leaseByName`: a lease found by the VM's
        /// host name rather than this NIC's MAC (shown, but not trusted as the NIC's address).
        public enum Source: Equatable, Sendable { case reservation, lease, leaseByName, host }
        public var ip: String
        public var source: Source
    }

    /// One NIC: its MAC (nil when the guest uses another, e.g. NIC 0's for a user-v2 network that
    /// replaces it) and the addresses HanaLima knows for it.
    public struct NIC: Equatable, Sendable {
        public var mac: String?
        public var addresses: [Address]
    }

    /// The NICs a row has on one bus (usually one; two NICs on a network share a dot).
    public struct Port: Equatable, Sendable {
        public var bus: String
        public var nics: [NIC]
        public var macs: [String] { nics.compactMap(\.mac) }
        public var addresses: [Address] {
            nics.flatMap(\.addresses).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case mac, vm }
        public var id: String { kind == .mac ? "\u{0}mac" : name }
        public var kind: Kind
        public var name: String
        public var running: Bool
        public var vmType: String?
        public var group: String?
        public var ports: [Port]
        /// Lima's user-mode network (NIC 0), each VM's own way out.
        public var usernet: Bool
        /// A vzNAT NIC: VZ's NAT, also drawn per VM (whether vzNAT VMs share a segment is unchecked).
        public var vzNAT: Bool
        /// The vzNAT NIC's MAC, if any.
        public var vzNATMAC: String?
        /// Buses this VM is the router of.
        public var routerOf: [String]
    }

    public var buses: [Bus]
    public var mac: Row
    public var rows: [Row]

    /// The VMs (not the Mac) with a NIC on `bus`.
    public func members(of bus: String) -> [Row] { rows.filter { $0.ports.contains { $0.bus == bus } } }

    // MARK: - Building

    /// - Parameters:
    ///   - instances: in the order the rows should have (the sidebar's).
    ///   - groups: each VM's group, by name.
    public static func build(instances: [LimaInstance], groups: [String: String] = [:],
                             networks: [VirtualNetwork], limaNetworks: [LimaNetworks.Network],
                             leases: [DHCPLease], now: Date = .now) -> NetworkMap {
        var buses: [String: Bus] = [:]
        for net in networks {
            let kind: Bus.Kind = switch net.mode {
            case .shared: .nat
            case .host: .hostOnly
            case .bridged: .bridged(interface: net.bridgedInterface)
            case .guestOnly: .guestOnly(router: net.routerAddress?.description, routerVM: nil)
            }
            buses[net.socketPath] = Bus(id: net.socketPath, name: net.name, kind: kind,
                                        subnet: net.subnet.map { "\($0.network)/\(net.prefixLength)" },
                                        gateway: net.gatewayAddress?.description, macOnSegment: !net.isGuestOnly)
        }
        let live = leases.filter { ($0.expires ?? .distantFuture) > now }
        var rows: [Row] = []
        for inst in instances {
            var ports: [Port] = []
            var vzNAT = false
            var vzNATMAC: String?
            var replacedNIC0 = false
            for nic in inst.networks ?? [] {
                if nic.vzNAT == true {
                    vzNAT = true
                    vzNATMAC = nic.macAddress.flatMap(DHCPReservation.normalizedMAC)
                    continue
                }
                var mac = nic.macAddress.flatMap(DHCPReservation.normalizedMAC)
                // On HanaLima's driver the first user-v2 network takes NIC 0's place, with NIC 0's MAC.
                if inst.usesHanaLimaDriver, !replacedNIC0, let lima = nic.lima,
                   limaNetworks.first(where: { $0.name == lima })?.mode == "user-v2" {
                    replacedNIC0 = true
                    mac = nil
                }
                var addresses: [Address] = []
                let busID: String
                if let socket = nic.socket, !socket.isEmpty {
                    busID = socket
                    if let net = networks.first(where: { $0.socketPath == socket }) {
                        // A bridge's addresses come from the LAN; reservations left from another mode don't apply.
                        if !net.isBridged, let mac,
                           let r = net.reservations.first(where: { DHCPReservation.normalizedMAC($0.mac) == mac }) {
                            addresses.append(Address(ip: r.ip, source: .reservation))
                        }
                        if inst.isRunning, !net.isBridged, let subnet = net.subnet,
                           let lease = DHCPLeases.address(mac: mac, instance: inst.name, in: subnet, leases: live),
                           !addresses.contains(where: { $0.ip == lease.ip }) {
                            addresses.append(Address(ip: lease.ip, source: lease.byMAC ? .lease : .leaseByName))
                        }
                    } else if buses[socket] == nil {
                        let name = URL(filePath: socket).deletingPathExtension().lastPathComponent
                        let ours = socket.hasPrefix(NetworkPaths.socketDirectory.path + "/")
                        buses[socket] = Bus(id: socket, name: name, kind: ours ? .deleted : .socket,
                                            subnet: nil, gateway: nil, macOnSegment: false)
                    }
                } else if let lima = nic.lima, !lima.isEmpty {
                    busID = "lima:\(lima)"
                    if buses[busID] == nil {
                        let mode = limaNetworks.first { $0.name == lima }?.mode ?? lima
                        buses[busID] = Bus(id: busID, name: busID, kind: .lima(mode: mode), subnet: nil, gateway: nil,
                                           macOnSegment: ["shared", "host", "bridged"].contains(mode))
                    }
                } else {
                    continue
                }
                // Two NICs on one network share a dot.
                if let i = ports.firstIndex(where: { $0.bus == busID }) {
                    ports[i].nics.append(NIC(mac: mac, addresses: addresses))
                } else {
                    ports.append(Port(bus: busID, nics: [NIC(mac: mac, addresses: addresses)]))
                }
            }
            rows.append(Row(kind: .vm, name: inst.name, running: inst.isRunning, vmType: inst.vmType,
                            group: groups[inst.name], ports: ports, usernet: inst.usesUsernet, vzNAT: vzNAT,
                            vzNATMAC: vzNATMAC, routerOf: []))
        }
        // Routers: the VM whose address (reserved or leased) on a guest-only network is its router.
        for (id, bus) in buses {
            guard case .guestOnly(let router?, _) = bus.kind else { continue }
            if let i = rows.firstIndex(where: { $0.ports.contains { $0.bus == id && $0.addresses.contains { $0.ip == router } } }) {
                rows[i].routerOf.append(id)
                buses[id]?.kind = .guestOnly(router: router, routerVM: rows[i].name)
            }
        }
        let macPorts = buses.values.filter(\.macOnSegment).map { bus in
            Port(bus: bus.id, nics: [NIC(mac: nil, addresses: bus.gateway.map { [Address(ip: $0, source: .host)] } ?? [])])
        }
        let mac = Row(kind: .mac, name: "Mac", running: true, vmType: nil, group: nil, ports: macPorts,
                      usernet: false, vzNAT: false, vzNATMAC: nil, routerOf: [])
        let ordered = order(Array(buses.values), rows: [mac] + rows)
        return NetworkMap(buses: ordered, mac: mac, rows: rows)
    }

    /// The lease of the NIC with `mac` in `subnet`; without a match by MAC (a client that
    /// identifies itself otherwise), the instance's newest lease there, as elsewhere in the app.
    // MARK: - Ordering

    /// How many buses `row`'s wire crosses without a dot, with the buses in `order` (ids).
    static func crossings(_ row: Row, order: [String]) -> Int {
        let attached = Set(row.ports.map(\.bus))
        guard let last = order.lastIndex(where: attached.contains) else { return 0 }
        return last + 1 - order.prefix(last + 1).filter(attached.contains).count
    }

    /// The buses in the order with the fewest crossings over all rows: every order for up to
    /// seven buses, otherwise the most used first. Ties keep the most-used-first, then name, order.
    static func order(_ buses: [Bus], rows: [Row]) -> [Bus] {
        // The search depends only on which row is on which bus; views rebuild the map on every
        // selection change, so remember the answer.
        let key = buses.map(\.id).sorted().joined(separator: "\u{1}") + "\u{2}"
            + rows.map { $0.ports.map(\.bus).sorted().joined(separator: "\u{1}") }.joined(separator: "\u{3}")
        if let ids = orderCache.withLock({ $0[key] }) {
            return ids.compactMap { id in buses.first { $0.id == id } }
        }
        let result = search(buses, rows: rows)
        orderCache.withLock { cache in
            if cache.count > 64 { cache.removeAll() }
            cache[key] = result.map(\.id)
        }
        return result
    }

    private static let orderCache = Mutex<[String: [String]]>([:])

    private static func search(_ buses: [Bus], rows: [Row]) -> [Bus] {
        let usage = Dictionary(grouping: rows.flatMap { $0.ports.map(\.bus) }, by: { $0 }).mapValues(\.count)
        let start = buses.sorted { (usage[$0.id] ?? 0, $1.name) > (usage[$1.id] ?? 0, $0.name) }
        guard buses.count > 1, buses.count <= 7 else { return start }
        func cost(_ order: [Bus]) -> Int {
            let ids = order.map(\.id)
            return rows.reduce(0) { $0 + crossings($1, order: ids) }
        }
        var best = start, bestCost = cost(start)
        var current = start
        // Heap's algorithm visits every permutation; strict improvement keeps the earliest best.
        func permute(_ k: Int) {
            if k == 1 {
                let c = cost(current)
                if c < bestCost { best = current; bestCost = c }
                return
            }
            permute(k - 1)
            for i in 0..<(k - 1) {
                current.swapAt(k % 2 == 0 ? i : 0, k - 1)
                permute(k - 1)
            }
        }
        permute(current.count)
        return best
    }
}
