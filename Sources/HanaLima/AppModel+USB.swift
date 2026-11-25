import Foundation
import LimaKit
import NetworkKit

/// USB passthrough (docs/19): one `hanalima` VM, chosen here, receives the USB accessories the
/// user assigns in macOS's "Virtual Machine Accessories" menu. The driver reads the choice at
/// each start; the app only writes it.
extension AppModel {
    static var usbTargetFile: URL { NetworkPaths.supportDirectory.appending(path: USBTarget.fileName) }

    /// macOS 27 and a driver signed to claim USB accessories (a Developer ID build with the
    /// driver's provisioning profile; never an ad hoc build).
    static let offersUSBPassthrough: Bool = {
        guard #available(macOS 27, *), let dir = driverDirectory else { return false }
        return USBTarget.isEntitled(executable: dir.appending(path: DriverInstaller.driverName))
    }()

    func updateUSBTarget() {
        guard Self.offersUSBPassthrough else { return }
        let target = USBTarget.load(from: Self.usbTargetFile)
        // Only a VM still on HanaLima's driver (one moved to Lima's vz keeps its identity).
        let name = target.flatMap { target in
            instances.first { $0.usesHanaLimaDriver && target.matches(instanceDir: URL(fileURLWithPath: $0.dir)) }?.name
        }
        if name != usbTargetName { usbTargetName = name }
        Task {
            let active = await Self.isReceiving(target)
            if active != usbTargetActive { usbTargetActive = active }
        }
    }

    /// Asks the target's driver itself: it decided at its start, which may still be under way
    /// (not Running in the list yet) or under another Lima home.
    static func isReceiving(_ target: USBTarget?) async -> Bool {
        guard let target else { return false }
        let dir = URL(fileURLWithPath: target.instanceDir)
        return await Task.detached {
            (try? DriverControl.send(DriverControl.Request(op: .status), instanceDir: dir, timeout: 1))?.usbTarget == true
        }.value
    }

    /// Why `instance` can't be made (or stop being) the USB target now, or nil. Not while the
    /// target runs or starts, itself included: its driver read the choice at start and keeps
    /// receiving, so a second VM started meanwhile would compete for the same accessories.
    func usbTargetBlocker(_ instance: LimaInstance) -> String? {
        if let current = usbTargetName, usbTargetActive || isBusy(current) || self.instance(named: current)?.isRunning == true {
            return String(localized: "受け取り先の「\(current)」が動いている間は変えられません。")
        }
        if usbTargetActive {
            return String(localized: "USB 機器の受け取り先が動いている間は変えられません。")
        }
        if USBTarget(instanceDir: URL(fileURLWithPath: instance.dir)) == nil {
            return String(localized: "一度起動すると選べます。")
        }
        return nil
    }

    func setUSBTarget(_ instance: LimaInstance, _ on: Bool) async {
        let failed = String(localized: "USB 機器の受け取り先を保存できませんでした")
        usbTargetActive = await Self.isReceiving(USBTarget.load(from: Self.usbTargetFile))
        if let blocker = usbTargetBlocker(instance) {
            alert = AlertMessage(title: failed, message: blocker)
            return
        }
        do {
            if on {
                guard let target = USBTarget(instanceDir: URL(fileURLWithPath: instance.dir)) else {
                    alert = AlertMessage(title: failed, message: String(localized: "一度起動すると選べます。"))
                    return
                }
                try USBTarget.save(target, to: Self.usbTargetFile)
            } else {
                try USBTarget.save(nil, to: Self.usbTargetFile)
            }
        } catch {
            alert = AlertMessage(title: failed, message: error.localizedDescription)
        }
        updateUSBTarget()
    }

    /// What the driver reports for a running VM: whether it receives, how many are attached.
    func usbStatus(of instance: LimaInstance) async -> DriverControl.Response? {
        guard instance.isRunning, instance.usesHanaLimaDriver else { return nil }
        let dir = URL(fileURLWithPath: instance.dir)
        return try? await Task.detached { try DriverControl.send(DriverControl.Request(op: .status), instanceDir: dir, timeout: 2) }.value
    }
}
