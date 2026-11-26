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
            var answers: [String: DriverControl.Response] = [:]
            for await (name, response) in group { if let response { answers[name] = response } }
            return answers
        }
        if answers != usbReports { usbReports = answers }
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

    /// Saves the routes with `change` applied.
    func changeUSBRoutes(_ change: (inout USBRoutes) -> Void) {
        let failed = String(localized: "USB 機器の振り分けを保存できませんでした")
        if let blocker = usbRoutesBlocker {
            alert = AlertMessage(title: failed, message: blocker)
            return
        }
        guard case .success(var routes) = usbRoutes else { return }
        change(&routes)
        do {
            usbRoutes = .success(try routes.save(support: Self.usbSupport))
        } catch {
            alert = AlertMessage(title: failed, message: "\(error)")
        }
    }

    /// Sends `device` to `destination` (nil: by the default route) by the rule `bySerial`
    /// picks, replacing the device's rules.
    func setUSBRoute(for device: USBDeviceIdentity, to destination: USBTarget?, bySerial: Bool) {
        changeUSBRoutes { routes in
            let mine = [device.serialMatch, device.portMatch].compactMap { $0 }
            routes.rules.removeAll { mine.contains($0.match) }
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

    /// Rules for devices no driver reports now.
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

/// One accessory on the USB page.
struct USBDeviceRow: Identifiable {
    var device: USBRoutingStatus.Device
    /// The VM whose driver has it attached, is attaching or detaching it, or waits to attach it.
    var holder: String?
    var errors: [String] = []

    init(device: USBRoutingStatus.Device) { self.device = device }

    var id: String { device.registryID }
}
