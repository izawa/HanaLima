import AccessoryAccess
import Foundation
import Virtualization

/// Spike (docs/19): hands every USB accessory the user assigns to this app, in the system's
/// "Virtual Machine Accessories" menu, to the VM's first USB controller, and logs each step.
@available(macOS 27, *)
final class USBPassthrough: NSObject, AAUSBAccessoryListener, VZUSBController.Delegate, @unchecked Sendable {
    private let machine: VZVirtualMachine
    private let queue: DispatchQueue
    /// Attached devices by the accessory's IORegistry ID; touched on `queue` only.
    private var attached: [UInt64: VZUSBPassthroughDevice] = [:]

    init(machine: VZVirtualMachine, queue: DispatchQueue) {
        self.machine = machine
        self.queue = queue
        super.init()
        queue.sync { machine.usbControllers.first?.delegate = self }
        log("usb: registering a listener (no criteria); parent \(getppid()), executable \(Bundle.main.executablePath ?? "?"), bundle \(Bundle.main.bundleIdentifier ?? "-")")
        AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: []) { [self] present, error in
            if let error { log("usb: register failed: \(error)"); return }
            log("usb: listener registered, \(present.count) assigned accessory(ies) present")
            for accessory in present { attach(accessory) }
        }
    }

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        log("usb: connected \(Self.describe(usbAccessory))")
        attach(usbAccessory)
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        log("usb: disconnected \(Self.describe(usbAccessory))")
        queue.async { [self] in attached[usbAccessory.registryID] = nil }
    }

    func usbController(_ usbController: VZUSBController, usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice) {
        log("usb: controller reports the passthrough device disconnected")
    }

    private func attach(_ accessory: AAUSBAccessory) {
        let id = accessory.registryID
        // Can the accessory cross a process boundary as bytes (option A without a Mach service)?
        // Not on AccessoryAccess's queue: decoding syncs onto it.
        DispatchQueue.global().async {
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: accessory, requiringSecureCoding: true)
                let back = try NSKeyedUnarchiver.unarchivedObject(ofClass: AAUSBAccessory.self, from: data)
                log("usb: archived to \(data.count) bytes, round trip \(back?.registryID == id ? "same registry ID" : "differs")")
            } catch {
                log("usb: archiving failed: \(error)")
            }
        }
        let device: VZUSBPassthroughDevice
        do {
            device = try VZUSBPassthroughDevice(configuration: VZUSBPassthroughDeviceConfiguration(device: accessory))
        } catch {
            log("usb: creating the passthrough device failed: \(error)")
            return
        }
        queue.async { [self] in
            guard attached[id] == nil else { return }
            guard let controller = machine.usbControllers.first else { log("usb: no USB controller"); return }
            controller.attach(device: device) { [self] error in
                if let error { log("usb: attach failed: \(error)"); return }
                attached[id] = device
                log("usb: attached \(Self.describe(accessory))")
            }
        }
    }

    /// Vendor and product IDs from the device descriptor (bytes 8–11, little endian).
    private static func describe(_ accessory: AAUSBAccessory) -> String {
        let d = [UInt8](accessory.deviceDescriptorData)
        guard d.count >= 12 else { return "registry \(accessory.registryID)" }
        return String(format: "%04x:%04x (registry %llu)", Int(d[8]) | Int(d[9]) << 8, Int(d[10]) | Int(d[11]) << 8, accessory.registryID)
    }
}
