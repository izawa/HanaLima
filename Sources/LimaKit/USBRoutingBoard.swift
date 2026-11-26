import Foundation

/// One USB accessory on the app's USB page, from what the drivers report (docs/19).
public struct USBDeviceRow: Identifiable, Equatable, Sendable {
    public var device: USBRoutingStatus.Device
    /// The VM whose driver has it attached, is attaching or detaching it, or waits to attach it.
    public var holder: String?
    public var errors: [String] = []

    public init(device: USBRoutingStatus.Device, holder: String? = nil) {
        self.device = device
        self.holder = holder
    }

    public var id: String { device.registryID }
}

/// What the USB page shows and saves, from the drivers' reports and the routes; no state of
/// its own, so the app's model only asks the drivers and keeps the answers.
public enum USBRoutingBoard {
    /// One row per accessory (every driver is told of every one), by VM name of the reports.
    /// The row's device is the report of the VM that holds it, if one does.
    public static func rows(_ reports: [String: USBRoutingStatus]) -> [USBDeviceRow] {
        var rows: [String: USBDeviceRow] = [:]
        for (vm, status) in reports.sorted(by: { $0.key < $1.key }) {
            for device in status.devices {
                var row = rows[device.registryID] ?? USBDeviceRow(device: device)
                if [.attached, .attaching, .detaching].contains(device.state) || (device.state == .waiting && row.holder == nil) {
                    row.holder = vm
                    row.device = device
                }
                if let error = device.error { row.errors.append("\(vm): \(error)") }
                rows[device.registryID] = row
            }
        }
        return rows.values.sorted { ($0.device.identity.name ?? "", $0.id) < ($1.device.identity.name ?? "", $1.id) }
    }

    /// Rules for devices no row is about.
    public static func absentRules(_ routes: USBRoutes, rows: [USBDeviceRow]) -> [USBRoutes.Rule] {
        let present = rows.flatMap { [$0.device.identity.serialMatch, $0.device.identity.portMatch] }
        return routes.rules.filter { !present.contains($0.match) }
    }

    /// The attached devices `routes` would send away from the VM that has them; `name` gives
    /// the VM a route names.
    public static func takenAway(by routes: USBRoutes, rows: [USBDeviceRow], name: (USBTarget) -> String?) -> [USBDeviceRow] {
        let all = rows.map(\.device.identity)
        return rows.filter { row in
            guard let vm = row.holder, row.device.state == .attached else { return false }
            if case .send(let target, _) = routes.decision(for: row.device.identity, among: all) { return name(target) != vm }
            return true
        }
    }

    /// The row of now for `chosen`: the same connection, or the device enumerated again
    /// (moving it between VMs gives it a new registry ID) if exactly one row has its key.
    public static func find(_ chosen: USBDeviceRow, in rows: [USBDeviceRow]) -> USBDeviceRow? {
        if let row = rows.first(where: { $0.id == chosen.id }) { return row }
        let same = rows.filter { $0.device.identity.matches(chosen.device.identity) }
        return same.count == 1 ? same[0] : nil
    }

    public enum Refusal: Error, Equatable {
        /// A serial rule several devices share would become port rules, but not every one of
        /// them has a port of its own.
        case twinsWithoutPorts
    }

    /// `routes` with `device` sent to `destination` (nil: by the default route) by the rule
    /// `bySerial` picks, its own rules replaced. Turning a serial rule that matches several
    /// connected devices into port rules turns it for all of them at once, to the rule's VM,
    /// so none falls to the default route before the user chooses.
    public static func route(_ routes: USBRoutes, device row: USBDeviceRow, among rows: [USBDeviceRow],
                             to destination: USBTarget?, bySerial: Bool) throws(Refusal) -> USBRoutes {
        let device = row.device.identity
        let shared = device.serialMatch.flatMap { match in routes.rules.first { $0.match == match } }
        let twins = bySerial || shared == nil ? [] : rows
            .filter { $0.id != row.id && $0.device.identity.serialMatch == device.serialMatch }.map(\.device.identity)
        let ports = ([device] + twins).map(\.portMatch)
        if !twins.isEmpty, ports.contains(nil) || Set(ports).count != ports.count { throw .twinsWithoutPorts }
        var routes = routes
        let mine = [device.serialMatch, device.portMatch].compactMap { $0 }
        routes.rules.removeAll { mine.contains($0.match) }
        if let shared {
            for case let port? in twins.map(\.portMatch) {
                routes.rules.removeAll { $0.match == port }
                routes.rules.append(.init(match: port, destination: shared.destination))
            }
        }
        if let destination, let match = bySerial ? device.serialMatch : device.portMatch {
            routes.rules.append(.init(match: match, destination: destination))
        }
        return routes
    }
}
