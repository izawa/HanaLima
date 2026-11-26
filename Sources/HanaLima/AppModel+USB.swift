import Foundation
import LimaKit
import NetworkKit

/// USB passthrough (docs/19): every running `hanalima` VM's driver is told of the USB
/// accessories the user assigns in macOS's "Virtual Machine Accessories" menu, and attaches
/// those the routes (`usb-routes.json`) send to its VM. The app writes the routes and shows
/// what the drivers report; the drivers watch the file.
extension AppModel {
    static var usbSupport: URL { NetworkPaths.supportDirectory }

    /// macOS 27 and a driver signed to claim USB accessories (a Developer ID build with the
    /// driver's provisioning profile; never an ad hoc build).
    static let offersUSBPassthrough: Bool = {
        guard #available(macOS 27, *), let dir = driverDirectory else { return false }
        return USBTarget.isEntitled(executable: dir.appending(path: DriverInstaller.driverName))
    }()

    /// Reads the routes and names the VMs they can send to.
    func updateUSBRoutes() {
        guard Self.offersUSBPassthrough else { return }
        let routes = USBRoutes.load(support: Self.usbSupport)
        if routes != usbRoutes { usbRoutes = routes }
        var targets: [String: USBTarget] = [:]
        for instance in instances where instance.usesHanaLimaDriver {
            targets[instance.name] = USBTarget(instanceDir: URL(fileURLWithPath: instance.dir))
        }
        if targets != usbTargets { usbTargets = targets }
        usbReports = usbReports.filter { name, _ in instance(named: name)?.isRunning == true }
    }

    /// The VM the routes name by `target`; nil if none is (renamed, copied, made again).
    func usbName(of target: USBTarget) -> String? {
        usbTargets.first { $0.value == target }?.key
    }

    /// Asks every running `hanalima` VM's driver, together.
    func refreshUSBReports() async {
        let running = instances.filter { $0.isRunning && $0.usesHanaLimaDriver }
        let answers = await withTaskGroup(of: (String, DriverControl.Response?).self) { group in
            for instance in running {
                let dir = URL(fileURLWithPath: instance.dir)
                group.addTask {
                    (instance.name, try? DriverControl.send(DriverControl.Request(op: .status), instanceDir: dir, timeout: 2))
                }
            }
            var answers: [String: DriverControl.Response?] = [:]
            for await (name, response) in group { answers[name] = response }
            return answers
        }
        let reports = answers.compactMapValues { $0 }
        if reports != usbReports { usbReports = reports }
        let unreachable = answers.filter { $0.value == nil }.keys.sorted()
        if unreachable != usbUnreachable { usbUnreachable = unreachable }
    }

    /// A running VM whose driver is v0.19's: it read the single USB target at its start and
    /// receives every accessory, so routes that send one elsewhere would make two VMs compete.
    var usbLegacyReceiver: String? {
        usbReports.first { $0.value.usbTarget == true && $0.value.usbRouting == nil }?.key
    }

    /// Why the routes can't be changed now, or nil.
    var usbRoutesBlocker: String? {
        if let name = usbLegacyReceiver {
            return String(localized: "「\(name)」が前の版の HanaLima で起動したまま動いています。その仮想マシンを停止するまで、振り分けは変えられません。")
        }
        if case .failure(let error) = usbRoutes {
            return String(localized: "振り分けの設定を読めません（\(error.description)）。")
        }
        return nil
    }

    /// Saves the routes with `change` applied; first asks if that takes a device away from
    /// the VM using it (storage there should be unmounted first).
    /// Ownership is asked of every driver now, not taken from the last poll; a driver that
    /// doesn't answer may have one attached, so it is asked about too.
    func changeUSBRoutes(_ change: (inout USBRoutes) -> Void) async {
        guard case .success(var routes) = usbRoutes else { return }
        let base = routes.revision
        change(&routes)
        guard routes != (try? usbRoutes.get()) else { return }
        await refreshUSBReports()
        var moving = usbDevicesTakenAway(by: routes)
        moving += usbUnreachable.map { String(localized: "「\($0)」の機器（応答しないので確かめられません）") }
        if moving.isEmpty {
            await saveUSBRoutes(routes, base: base)
        } else {
            pendingUSBRoutes = PendingUSBRoutes(routes: routes, base: base, moving: moving)
        }
    }

    /// Saves routes the user has confirmed (or that move nothing), unless the routes saved
    /// are no longer the ones `base` names (another edit came first: it would be undone).
    func saveUSBRoutes(_ routes: USBRoutes, base: String) async {
        let failed = String(localized: "USB 機器の振り分けを保存できませんでした")
        if let blocker = await usbLegacyBlocker() ?? usbRoutesBlocker {
            alert = AlertMessage(title: failed, message: blocker)
            return
        }
        guard (try? USBRoutes.load(support: Self.usbSupport).get())?.revision == base else {
            updateUSBRoutes()
            alert = AlertMessage(title: failed, message: String(localized: "ほかの変更と重なりました。もう一度選んでください。"))
            return
        }
        do {
            usbRoutes = .success(try routes.save(support: Self.usbSupport))
        } catch {
            alert = AlertMessage(title: failed, message: "\(error)")
        }
    }

    /// v0.19's target, asked directly (not the last poll: it may not have answered yet, or
    /// may run under another Lima home): while its driver runs it receives every accessory.
    private func usbLegacyBlocker() async -> String? {
        guard let target = USBTarget.load(from: Self.usbSupport.appending(path: USBTarget.fileName)) else { return nil }
        let dir = URL(fileURLWithPath: target.instanceDir)
        let response = await Task.detached {
            try? DriverControl.send(DriverControl.Request(op: .status), instanceDir: dir, timeout: 2)
        }.value
        let name = usbName(of: target) ?? dir.lastPathComponent
        guard let response else {
            // No answer: stopped is fine, but a driver that runs and doesn't answer may be one.
            guard Self.driverRuns(instanceDir: dir) else { return nil }
            return String(localized: "「\(name)」のドライバーが応答しないので、前の版の HanaLima で起動したものか確かめられません。しばらくしてからもう一度選んでください。")
        }
        guard response.usbTarget == true, response.usbRouting == nil else { return nil }
        return String(localized: "「\(name)」が前の版の HanaLima で起動したまま動いています。その仮想マシンを停止するまで、振り分けは変えられません。")
    }

    /// The driver's process in `instanceDir` (`hanalima.pid`) is alive.
    private nonisolated static func driverRuns(instanceDir: URL) -> Bool {
        guard let text = try? String(contentsOf: instanceDir.appending(path: "hanalima.pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// "device on VM" for each attached device `routes` would send elsewhere.
    private func usbDevicesTakenAway(by routes: USBRoutes) -> [String] {
        let devices = usbDevices
        let all = devices.map(\.device.identity)
        return devices.compactMap { row in
            guard let vm = row.holder, row.device.state == .attached else { return nil }
            if case .send(let target, _) = routes.decision(for: row.device.identity, among: all), usbName(of: target) == vm { return nil }
            return String(localized: "\(row.device.identity.name ?? row.device.identity.ids)（\(vm)）")
        }
    }

    /// Sends `device` to `destination` (nil: by the default route) by the rule `bySerial`
    /// picks, replacing the device's rules. Turning a serial rule that matches several
    /// connected devices into port rules turns it for all of them at once, to the same VM, so
    /// none falls to the default route before the user chooses.
    func setUSBRoute(for device: USBDeviceIdentity, to destination: USBTarget?, bySerial: Bool) async {
        let twins = bySerial ? [] : usbDevices.map(\.device.identity).filter { $0 != device && $0.serialMatch != nil && $0.serialMatch == device.serialMatch }
        // Each twin needs a port of its own, or the shared rule stays (one would fall to the
        // default route).
        let ports = ([device] + twins).map(\.portMatch)
        if !twins.isEmpty, ports.contains(nil) || Set(ports).count != ports.count {
            alert = AlertMessage(title: String(localized: "USB 機器の振り分けを保存できませんでした"),
                                 message: String(localized: "同じシリアル番号の機器のなかに、挿したポートで見分けられないものがあります。"))
            return
        }
        await changeUSBRoutes { routes in
            let shared = device.serialMatch.flatMap { match in routes.rules.first { $0.match == match } }
            let mine = [device.serialMatch, device.portMatch].compactMap { $0 }
            routes.rules.removeAll { mine.contains($0.match) }
            if let shared {
                for twin in twins {
                    guard let port = twin.portMatch else { continue }
                    routes.rules.removeAll { $0.match == port }
                    routes.rules.append(.init(match: port, destination: shared.destination))
                }
            }
            guard let destination, let match = bySerial ? device.serialMatch : device.portMatch else { return }
            routes.rules.append(.init(match: match, destination: destination))
        }
    }

    /// The accessories the drivers know, one row each (every driver is told of every one).
    var usbDevices: [USBDeviceRow] {
        var rows: [String: USBDeviceRow] = [:]
        for (vm, response) in usbReports.sorted(by: { $0.key < $1.key }) {
            for device in response.usbRouting?.devices ?? [] {
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

    /// Rules for devices no driver reports now (or no driver that answered).
    var usbAbsentRules: [USBRoutes.Rule] {
        guard case .success(let routes) = usbRoutes else { return [] }
        let present = usbDevices.flatMap { [$0.device.identity.serialMatch, $0.device.identity.portMatch] }
        return routes.rules.filter { rule in !present.contains(rule.match) }
    }

    /// A driver works by other routes than the saved ones (it hasn't read them yet).
    var usbApplying: Bool {
        guard case .success(let routes) = usbRoutes else { return false }
        return usbReports.values.contains { $0.usbRouting.map { $0.revision != routes.revision } ?? false }
    }

    /// What the driver of `instance` reports; nil if it doesn't answer.
    func usbStatus(of instance: LimaInstance) async -> DriverControl.Response? {
        guard instance.isRunning, instance.usesHanaLimaDriver else { return nil }
        let dir = URL(fileURLWithPath: instance.dir)
        let response = try? await Task.detached { try DriverControl.send(DriverControl.Request(op: .status), instanceDir: dir, timeout: 2) }.value
        usbReports[instance.name] = response
        return response
    }
}

/// Routes waiting for the user to confirm taking devices away from the VMs using them.
struct PendingUSBRoutes {
    var routes: USBRoutes
    /// The revision the edit started from.
    var base: String
    var moving: [String]
}

/// One accessory on the USB page.
struct USBDeviceRow: Identifiable {
    var device: USBRoutingStatus.Device
    /// The VM whose driver has it attached, is attaching or detaching it, or waits to attach it.
    var holder: String?
    var errors: [String] = []

    init(device: USBRoutingStatus.Device) { self.device = device }

    var id: String { device.registryID }
}
