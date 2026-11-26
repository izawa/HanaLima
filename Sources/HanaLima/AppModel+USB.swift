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

    /// Running VMs whose driver is from before routing (v0.19, which answers `usbTarget`):
    /// not receiving by the routes until they start again.
    var usbOldDrivers: [String] {
        usbReports.filter { $0.value.usbTarget != nil && $0.value.usbRouting == nil }.keys.sorted()
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
    /// `since`: the revision the caller saw when the user chose (a caller that waited before
    /// this); another edit saved meanwhile stops this one.
    func changeUSBRoutes(since: String? = nil, _ change: (inout USBRoutes) -> Void) async {
        guard case .success(var routes) = usbRoutes else { return }
        let base = routes.revision
        if let since, since != base {
            alert = AlertMessage(title: String(localized: "USB 機器の振り分けを保存できませんでした"),
                                 message: String(localized: "ほかの変更と重なりました。もう一度選んでください。"))
            return
        }
        change(&routes)
        guard routes != (try? usbRoutes.get()) else { return }
        await refreshUSBReports()
        let pending = PendingUSBRoutes(routes: routes, base: base, taken: usbTaken(by: routes))
        if pending.taken.isEmpty {
            await saveUSBRoutes(routes, base: base)
        } else {
            pendingUSBRoutes = pending
        }
    }

    /// What `routes` would take away now: attached devices (by connection and VM) and the VMs
    /// whose drivers don't answer.
    private func usbTaken(by routes: USBRoutes) -> PendingUSBRoutes.Taken {
        PendingUSBRoutes.Taken(
            devices: USBRoutingBoard.takenAway(by: routes, rows: usbDevices, name: usbName(of:)),
            silent: usbUnreachable)
    }

    /// The user confirmed taking `pending.moving` away: asks the drivers again, and asks the
    /// user again if more would be taken away now (another device attached meanwhile).
    func confirmUSBRoutes(_ pending: PendingUSBRoutes) async {
        await refreshUSBReports()
        // A device connected meanwhile may share the serial number the new rule names.
        let rows = usbDevices
        let all = rows.map(\.device.identity)
        if rows.contains(where: { pending.routes.decision(for: $0.device.identity, among: all) == .hold(.duplicate) }) {
            alert = AlertMessage(title: String(localized: "USB 機器の振り分けを保存できませんでした"),
                                 message: String(localized: "同じシリアル番号の機器がほかにもつながっています。見分け方を「挿したポート」にしてください。"))
            return
        }
        let taken = usbTaken(by: pending.routes)
        if taken.isWithin(pending.taken) {
            await saveUSBRoutes(pending.routes, base: pending.base)
        } else {
            pendingUSBRoutes = PendingUSBRoutes(routes: pending.routes, base: pending.base, taken: taken)
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
            guard DriverControl.driverPID(instanceDir: dir) != nil else { return nil }
            return String(localized: "「\(name)」のドライバーが応答しないので、前の版の HanaLima で起動したものか確かめられません。しばらくしてからもう一度選んでください。")
        }
        guard response.usbTarget == true, response.usbRouting == nil else { return nil }
        return String(localized: "「\(name)」が前の版の HanaLima で起動したまま動いています。その仮想マシンを停止するまで、振り分けは変えられません。")
    }

    /// Sends `device` to `destination` (nil: by the default route) by the rule `bySerial`
    /// picks, replacing the device's rules. Turning a serial rule that matches several
    /// connected devices into port rules turns it for all of them at once, to the same VM, so
    /// none falls to the default route before the user chooses.
    func setUSBRoute(for chosen: USBDeviceRow, to destination: USBTarget?, bySerial: Bool) async {
        let failed = String(localized: "USB 機器の振り分けを保存できませんでした")
        let since = (try? usbRoutes.get())?.revision
        // The devices of now, not of the last poll: one that came since must not lose its rule.
        await refreshUSBReports()
        guard let row = USBRoutingBoard.find(chosen, in: usbDevices) else {
            alert = AlertMessage(title: failed, message: String(localized: "機器がつなぎ直されました。もう一度選んでください。"))
            return
        }
        // Replacing a shared serial rule needs every device it matches, so no driver may be silent.
        let device = row.device.identity
        let shared = device.serialMatch.flatMap { match in (try? usbRoutes.get())?.rules.contains { $0.match == match } } ?? false
        if !bySerial, shared, !usbUnreachable.isEmpty {
            alert = AlertMessage(title: failed, message: String(localized: "応答しないドライバーがあり、同じシリアル番号の機器をすべて確かめられません。しばらくしてからもう一度選んでください。"))
            return
        }
        let rows = usbDevices
        if let routes = try? usbRoutes.get() {
            do throws(USBRoutingBoard.Refusal) {
                _ = try USBRoutingBoard.route(routes, device: row, among: rows, to: destination, bySerial: bySerial)
            } catch {
                let message = switch error {
                case .twinsWithoutPorts: String(localized: "同じシリアル番号の機器のなかに、挿したポートで見分けられないものがあります。")
                case .serialShared: String(localized: "同じシリアル番号の機器がほかにもつながっています。見分け方を「挿したポート」にしてください。")
                case .noKey: String(localized: "この機器は、選んだ見分け方では見分けられません。")
                }
                alert = AlertMessage(title: failed, message: message)
                return
            }
        }
        await changeUSBRoutes(since: since) { routes in
            routes = (try? USBRoutingBoard.route(routes, device: row, among: rows, to: destination, bySerial: bySerial)) ?? routes
        }
    }

    /// The accessories the drivers know, one row each (every driver is told of every one).
    var usbDevices: [USBDeviceRow] {
        USBRoutingBoard.rows(usbReports.compactMapValues(\.usbRouting))
    }

    /// Rules for devices no driver reports now (or no driver that answered).
    var usbAbsentRules: [USBRoutes.Rule] {
        guard case .success(let routes) = usbRoutes else { return [] }
        return USBRoutingBoard.absentRules(routes, rows: usbDevices)
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
    var taken: Taken

    struct Taken {
        var devices: [USBDeviceRow]
        /// VMs whose drivers don't answer: they may have devices the change takes away.
        var silent: [String]

        var isEmpty: Bool { devices.isEmpty && silent.isEmpty }

        /// Nothing more than `confirmed` (the same connections on the same VMs).
        func isWithin(_ confirmed: Taken) -> Bool {
            Set(devices.map { "\($0.id) \($0.holder ?? "")" }).isSubset(of: confirmed.devices.map { "\($0.id) \($0.holder ?? "")" })
                && Set(silent).isSubset(of: confirmed.silent)
        }

        /// "device (VM)" for the confirmation.
        var labels: [String] {
            devices.map { String(localized: "\($0.device.identity.name ?? $0.device.identity.ids)（\($0.holder ?? "")）") }
                + silent.map { String(localized: "「\($0)」の機器（応答しないので確かめられません）") }
        }
    }
}
