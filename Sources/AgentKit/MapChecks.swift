import Foundation

/// Reachability checks for the network map (docs/16 §5): pings from inside each guest, bound to
/// the NIC (found by its MAC) and sent to numeric addresses, so a reply can't come back through
/// another NIC. A result records one exchange; a failure doesn't prove the target unreachable.
public struct MapProbe: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// The Mac's address on a NAT or host-only network.
        case gateway(String)
        /// A guest-only network's router.
        case router(String)
        /// Another VM on the same network.
        case peer(vm: String, ip: String)
        /// The outside address the user typed.
        case outside(String)

        public var ip: String {
            switch self {
            case .gateway(let ip), .router(let ip), .outside(let ip): ip
            case .peer(_, let ip): ip
            }
        }
    }

    /// The way out an `outside` probe tests when it isn't a bus's (NIC 0, vzNAT).
    public enum Exit: String, Equatable, Sendable { case nic0, vzNAT }

    /// Unique within one VM's script ("p1", "p2"…).
    public var id: String
    public var vm: String
    /// The bus whose dot this probe belongs to; nil for an `exit`.
    public var bus: String?
    public var exit: Exit?
    /// The NIC it is sent from.
    public var mac: String
    public var target: Target
}

/// The outcome of one run in one VM.
public struct MapCheckRecord: Equatable, Sendable {
    public struct Outcome: Equatable, Sendable {
        public var reached: Bool
        public var reason: String?
        /// When this probe ran (a network-scoped run keeps the other networks' older outcomes).
        public var at: Date?

        public init(reached: Bool, reason: String?, at: Date? = nil) { self.reached = reached; self.reason = reason; self.at = at }
    }

    public var probes: [MapProbe]
    /// By probe id.
    public var outcomes: [String: Outcome]
    /// The IPv4 addresses each NIC (by MAC) had in the guest. Not evidence of reachability.
    public var observed: [String: [String]]
    public var at: Date

    public init(probes: [MapProbe], outcomes: [String: Outcome], observed: [String: [String]], at: Date) {
        self.probes = probes; self.outcomes = outcomes; self.observed = observed; self.at = at
    }
}

public enum MapChecks {
    public enum State: Equatable, Sendable {
        /// Nothing was tried.
        case configOnly
        case reached
        /// Tried without getting every reply (or any result).
        case unverified
        /// Some of the dot's NICs got every reply.
        case partial(reached: Int, of: Int)
    }

    // MARK: - Planning

    /// The probes for each VM in `vms`, limited to `bus` when given.
    /// - Parameters:
    ///   - outside: an IPv4 address the user typed; exits are tested only with one.
    ///   - nic0MAC: NIC 0's MAC for a VM (Lima derives it from the instance folder).
    public static func plan(_ map: NetworkMap, vms: [String], bus onlyBus: String? = nil, outside: String?,
                            nic0MAC: (String) -> String?) -> [String: [MapProbe]] {
        var plans: [String: [MapProbe]] = [:]
        for name in vms {
            guard let row = map.rows.first(where: { $0.name == name }) else { continue }
            var probes: [MapProbe] = []
            func add(bus: String?, exit: MapProbe.Exit? = nil, mac: String, _ target: MapProbe.Target) {
                probes.append(MapProbe(id: "p\(probes.count + 1)", vm: name, bus: bus, exit: exit, mac: mac, target: target))
            }
            for port in row.ports where onlyBus == nil || port.bus == onlyBus {
                guard let bus = map.buses.first(where: { $0.id == port.bus }) else { continue }
                for nic in port.nics {
                    guard let mac = nic.mac else { continue }
                    let own = Set(nic.addresses.map(\.ip))
                    switch bus.kind {
                    case .nat, .hostOnly:
                        if let gateway = bus.gateway { add(bus: bus.id, mac: mac, .gateway(gateway)) }
                    case .guestOnly(let router, _):
                        if let router, !own.contains(router) {
                            add(bus: bus.id, mac: mac, .router(router))
                            if let outside { add(bus: bus.id, mac: mac, .outside(outside)) }
                        }
                    default:
                        continue
                    }
                    // A peer that is also the gateway or router was just pinged.
                    if let peer = peer(of: name, on: bus.id, in: map),
                       !probes.contains(where: { $0.mac == mac && $0.target.ip == peer.ip }) {
                        add(bus: bus.id, mac: mac, .peer(vm: peer.vm, ip: peer.ip))
                    }
                }
            }
            if onlyBus == nil, let outside {
                if row.usernet, let mac = nic0MAC(name) { add(bus: nil, exit: .nic0, mac: mac, .outside(outside)) }
                if let mac = row.vzNATMAC { add(bus: nil, exit: .vzNAT, mac: mac, .outside(outside)) }
            }
            if !probes.isEmpty { plans[name] = probes }
        }
        return plans
    }

    /// The next VM after `vm` on `bus` (rows in the map's order, wrapping) with one known address
    /// there: a single NIC with a single address, reserved or leased to that NIC's MAC, so the
    /// ping can't go to the wrong one.
    static func peer(of vm: String, on bus: String, in map: NetworkMap) -> (vm: String, ip: String)? {
        let members = map.members(of: bus)
        guard let start = members.firstIndex(where: { $0.name == vm }), members.count > 1 else { return nil }
        for step in 1..<members.count {
            let candidate = members[(start + step) % members.count]
            guard let port = candidate.ports.first(where: { $0.bus == bus }), port.nics.count == 1,
                  let only = port.nics.first, only.addresses.count == 1,
                  [.reservation, .lease].contains(only.addresses[0].source) else { continue }
            return (candidate.name, only.addresses[0].ip)
        }
        return nil
    }

    // MARK: - The guest's script

    /// A POSIX sh script for one VM: reads each NIC's IPv4 addresses (`macs`), then runs `probes`.
    /// (`HLSYS` replaces /sys/class/net in tests.)
    public static func script(probes: [MapProbe], macs: [String]) -> String {
        var lines = [
            #"hlif() { for d in "${HLSYS:-/sys/class/net}"/*; do [ "$(cat "$d/address" 2>/dev/null)" = "$1" ] && { echo "${d##*/}"; return 0; }; done; return 1; }"#,
            #"hladdr() { i=$(hlif "$1") || return 0; ip -4 -o addr show dev "$i" 2>/dev/null | while read -r _ _ _ a _; do printf 'HLADDR %s %s\n' "$1" "${a%/*}"; done; }"#,
            #"hlprobe() { if ! i=$(hlif "$2"); then printf 'HLCHECK %s fail %s\n' "$1" 'no NIC with this MAC'; elif ping -I "$i" -c 2 -W 2 "$3" >/dev/null 2>&1; then printf 'HLCHECK %s ok\n' "$1"; else printf 'HLCHECK %s fail %s\n' "$1" 'no reply'; fi; }"#,
        ]
        for mac in macs { lines.append("hladdr \(TopologyVerification.quote(mac))") }
        for probe in probes {
            lines.append("hlprobe \(probe.id) \(TopologyVerification.quote(probe.mac)) \(TopologyVerification.quote(probe.target.ip))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads a script's output into a record. `runError` (it couldn't run or finish) makes every
    /// probe unverified, including any result printed before it.
    public static func record(probes: [MapProbe], output: String, runError: String?, at: Date) -> MapCheckRecord {
        let checks = probes.map { TrafficCheck(vm: $0.vm, id: $0.id, description: $0.target.ip) }
        let results = TopologyVerification.results(checks: checks, output: output, runError: runError)
        var outcomes: [String: MapCheckRecord.Outcome] = [:]
        for r in results { outcomes[r.check.id] = .init(reached: r.verified, reason: r.reason, at: at) }
        var observed: [String: [String]] = [:]
        if runError == nil {
            for line in output.split(whereSeparator: \.isNewline) {
                let f = line.split(separator: " ")
                guard f.count == 3, f[0] == "HLADDR" else { continue }
                observed[String(f[1]), default: []].append(String(f[2]))
            }
        }
        return MapCheckRecord(probes: probes, outcomes: outcomes, observed: observed, at: at)
    }

    // MARK: - States

    /// The state of `bus`'s dot in a VM's row: per NIC, reached when all its probes got replies.
    public static func state(bus: String, in record: MapCheckRecord?) -> State {
        state(of: record?.probes.filter { $0.bus == bus } ?? [], in: record)
    }

    /// The state of a VM's NIC 0 or vzNAT badge.
    public static func state(exit: MapProbe.Exit, in record: MapCheckRecord?) -> State {
        state(of: record?.probes.filter { $0.exit == exit } ?? [], in: record)
    }

    private static func state(of probes: [MapProbe], in record: MapCheckRecord?) -> State {
        guard let record, !probes.isEmpty else { return .configOnly }
        let byNIC = Dictionary(grouping: probes, by: \.mac)
        let reached = byNIC.values.filter { $0.allSatisfy { record.outcomes[$0.id]?.reached == true } }.count
        if reached == byNIC.count { return .reached }
        if reached == 0 { return .unverified }
        return .partial(reached: reached, of: byNIC.count)
    }
}
