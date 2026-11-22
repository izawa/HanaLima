import Foundation
import NetworkKit

/// The network map, the people's last reachability checks, and the guest-only networks'
/// observation, as tab-separated rows for MCP's `inspect` (docs/14 §4). Reads only: nothing here
/// runs a check or talks to a helper. Values are raw and in English, like the rest of `inspect`.
public enum MapInspection {
    /// A VM's last check results; `stale` once its boot, pauses, NICs or networks changed.
    public typealias Checks = [String: (record: MapCheckRecord, stale: Bool)]

    // MARK: - map

    public static let busHeader = "bus\tkind\tsubnet\tgateway\trouter\trouterVM\tmacOnBus"
    public static let linkHeader = "vm\trunning\tvia\tnics\taddresses\tcheck"

    /// The buses the selected VMs (all with none selected) are on.
    public static func buses(_ map: NetworkMap, vms: [String] = []) -> [String] {
        let used = Set(rows(map, vms).flatMap { $0.ports.map(\.bus) })
        return map.buses.filter { vms.isEmpty || used.contains($0.id) }.map { bus in
            var router = "-", routerVM = "-"
            if case .guestOnly(let r, let vm) = bus.kind { router = r ?? "-"; routerVM = vm ?? "-" }
            return [bus.name, kind(bus.kind), bus.subnet ?? "-", bus.gateway ?? "-", router, routerVM, "\(bus.macOnSegment)"]
                .joined(separator: "\t")
        }
    }

    /// One row per VM and bus it is on, plus NIC 0 and vzNAT; a VM with no NIC gets one row.
    public static func links(_ map: NetworkMap, checks: Checks, vms: [String] = []) -> [String] {
        var out: [String] = []
        for row in rows(map, vms) {
            let entry = checks[row.name]
            func line(_ via: String, nics: Int, addresses: String, _ state: MapChecks.State) -> String {
                [row.name, "\(row.running)", via, "\(nics)", addresses, check(state, entry)].joined(separator: "\t")
            }
            // A NIC without a MAC on a user-v2 bus is that shared network standing in for NIC 0: its
            // row carries NIC 0's results, and there is no separate exit.
            func standsInForNIC0(_ port: NetworkMap.Port) -> Bool {
                port.nics.contains { $0.mac == nil } && map.buses.first { $0.id == port.bus }?.kind == .lima(mode: "user-v2")
            }
            for port in row.ports {
                // What the guest reported at the last check, for a NIC with no reservation or lease of
                // its own (a bridge, or a lease found only by the VM's host name).
                let observed = entry?.stale == true ? "observed-stale" : "observed"
                let addresses = port.nics.flatMap { nic -> [String] in
                    let known = nic.addresses.map { "\($0.ip)/\($0.source)" }
                    guard nic.addresses.allSatisfy({ $0.source == .leaseByName }) else { return known }
                    return known + (nic.mac.flatMap { entry?.record.observed[$0] }?.map { "\($0)/\(observed)" } ?? [])
                }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ",")
                var state = MapChecks.state(bus: port.bus, in: entry?.record)
                if state == .configOnly, standsInForNIC0(port) { state = MapChecks.state(exit: .nic0, in: entry?.record) }
                out.append(line(busName(port.bus, map), nics: port.nics.count, addresses: addresses.isEmpty ? "-" : addresses, state))
            }
            let nic0Replaced = row.ports.contains(where: standsInForNIC0)
            if row.usernet && !nic0Replaced { out.append(line("exit:nic0", nics: 1, addresses: "-", MapChecks.state(exit: .nic0, in: entry?.record))) }
            if row.vzNAT { out.append(line("exit:vzNAT", nics: 1, addresses: "-", MapChecks.state(exit: .vzNAT, in: entry?.record))) }
            if row.ports.isEmpty && !row.usernet && !row.vzNAT { out.append(line("-", nics: 0, addresses: "-", .configOnly)) }
        }
        return out
    }

    // MARK: - checks

    public static let checkHeader = "vm\tvia\tnic\ttarget\tip\tresult\tat\tstale\treason"

    /// One row per probe of the last checks (every checked VM with `vms` nil). A selected VM never
    /// checked gets `notChecked`; a check that had nothing to ping (only reads addresses) `noTargets`.
    public static func checks(_ map: NetworkMap, checks: Checks, vms: [String]? = nil) -> [String] {
        let names = vms ?? map.rows.map(\.name).filter { checks[$0] != nil }
        var out: [String] = []
        for name in names {
            guard let (record, stale) = checks[name] else {
                out.append([name, "-", "-", "-", "-", "notChecked", "-", "-", "-"].joined(separator: "\t"))
                continue
            }
            if record.probes.isEmpty {
                out.append([name, "-", "-", "-", "-", "noTargets", timestamp(record.at), "\(stale)", "-"].joined(separator: "\t"))
                continue
            }
            for probe in record.probes {
                let outcome = record.outcomes[probe.id]
                let via = probe.bus.map { busName($0, map) } ?? probe.exit.map { "exit:\($0.rawValue)" } ?? "-"
                // A stale result keeps the MAC it was sent from: the NIC's name now may be another's.
                let nic = stale ? probe.mac : probe.bus.flatMap { map.endpoint(on: $0, macs: [probe.mac])?.nic } ?? probe.mac
                let reason = outcome?.reached == true ? "-" : oneLine(outcome?.reason ?? "no result")
                out.append([name, via, nic, target(probe.target), probe.target.ip,
                            outcome?.reached == true ? "reached" : "unverified",
                            timestamp(outcome?.at ?? record.at), "\(stale)", reason].joined(separator: "\t"))
            }
        }
        return out
    }

    // MARK: - observation

    public static let observationHeader = "network\tstate\tsampledAt\trun\tuptime\tconnected\tanswered\tflooded\tundelivered\tcapture\tfaults"
    public static let faultHeader = "fault\tnetwork\tid\ttarget\tblock\tdelayMs\tlossPct\texpiresAt"
    public static let portHeader = "port\tnetwork\tendpoint\tid\tconnected\tfromGuest\ttoGuest\tdroppedFull\tdroppedClosed\tdroppedLoss\tdroppedBlocked\tdroppedOverflow\tdelayed\tmalformed"

    /// A guest-only network's summary row, its faults' rows, and with `ports` its connections'
    /// rows. Counters are frames/bytes, cumulative since the helper's run started (`run`).
    public static func observation(network: String, bus: String?, reading: NetworkObservation.Reading,
                                   map: NetworkMap, now: Date, ports: Bool) -> (summary: String, faults: [String], ports: [String]) {
        guard case .sample(let o) = reading else {
            let state = reading == .olderHelper ? "olderHelper" : "notRunning"
            return ([network, state, "-", "-", "-", "-", "-", "-", "-", "-", "-"].joined(separator: "\t"), [], [])
        }
        let faults = o.supportsFaults ? (o.faults ?? []) : []
        let recording = o.capture.map { $0.endedAt == nil } == true
        let summary = [network, o.isStale(at: now) ? "stale" : "fresh", timestamp(o.sampledAt), o.runID, String(format: "%.1f", o.uptime),
                       "\(o.ports.filter(\.connected).count)", counter(o.answered), "\(o.flooded)", "\(o.undelivered)",
                       recording ? "recording" : "-", o.supportsFaults ? "\(faults.count)" : "unsupported"].joined(separator: "\t")
        func name(_ macs: [String]) -> String? {
            bus.flatMap { map.endpoint(on: $0, macs: macs) }.map { e in e.nic.map { "\(e.vm)/\($0)" } ?? e.vm }
        }
        let faultRows = faults.map { f in
            ["fault", network, f.id, f.spec.isSegment ? "*" : name([f.spec.target]) ?? f.spec.target, "\(f.spec.block)",
             "\(f.spec.delayMs)", num(f.spec.lossPercent), timestamp(f.expiresAt)].joined(separator: "\t")
        }
        let portRows = !ports ? [] : o.ports.map { p in
            ["port", network, name(p.macs) ?? (p.macs.isEmpty ? "-" : p.macs.joined(separator: ",")), "\(p.id)", "\(p.connected)",
             counter(p.fromGuest), counter(p.toGuest), counter(p.droppedFull), counter(p.droppedClosed),
             o.supportsFaults ? counter(p.droppedLoss) : "-", o.supportsFaults ? counter(p.droppedBlocked) : "-",
             o.supportsFaults ? counter(p.droppedOverflow) : "-", o.supportsFaults ? counter(p.delayed) : "-",
             "\(p.malformed)"].joined(separator: "\t")
        }
        return (summary, faultRows, portRows)
    }

    // MARK: - formatting

    private static func rows(_ map: NetworkMap, _ vms: [String]) -> [NetworkMap.Row] {
        vms.isEmpty ? map.rows : vms.compactMap { name in map.rows.first { $0.name == name } }
    }

    static func kind(_ kind: NetworkMap.Bus.Kind) -> String {
        switch kind {
        case .nat: "shared"
        case .hostOnly: "host"
        case .bridged(let interface): "bridged(\(interface))"
        case .guestOnly: "guestOnly"
        case .lima(let mode): "lima(\(mode))"
        case .deleted: "deleted"
        case .socket: "socket"
        }
    }

    private static func busName(_ id: String, _ map: NetworkMap) -> String {
        map.buses.first { $0.id == id }?.name ?? id
    }

    private static func check(_ state: MapChecks.State, _ entry: (record: MapCheckRecord, stale: Bool)?) -> String {
        let text: String = switch state {
        case .configOnly: "-"
        case .reached: "reached"
        case .unverified: "unverified"
        case .partial(let reached, let of): "partial(\(reached)/\(of))"
        }
        return entry?.stale == true && text != "-" ? "stale/" + text : text
    }

    private static func target(_ target: MapProbe.Target) -> String {
        switch target {
        case .gateway: "gateway"
        case .router: "router"
        case .peer(let vm, _): "peer:\(vm)"
        case .outside: "outside"
        }
    }

    private static func counter(_ c: NetworkObservation.Counter) -> String { "\(c.frames)/\(c.bytes)" }

    private static func num(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)  // 2026-11-22T09:15:00Z
    }
}
