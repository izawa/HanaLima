import AccessoryAccess
import Foundation
import Virtualization

/// The USB accessories the user assigns to HanaLima's driver in macOS's "Virtual Machine
/// Accessories" menu, attached to the VM's xHCI controller (docs/19). Only the USB target VM's
/// driver makes one (USBTarget), once the VM runs. A stop or a hibernate holds it (no new
/// attaches, what is attached stays recorded) and lets it go if it fails; the VM's end closes
/// it. An accessory that arrives while the VM can't take it (paused, held) waits. All state
/// lives on the VM's queue.
@available(macOS 27, *)
final class USBPassthrough: NSObject, AAUSBAccessoryListener, VZUSBController.Delegate, @unchecked Sendable {
    private let machine: VZVirtualMachine
    private let queue: DispatchQueue
    private var accepting = true
    /// By the accessory's IORegistry ID.
    private var attached: [UInt64: VZUSBPassthroughDevice] = [:]
    /// Attaches in flight, each with its own token: a disconnect drops the token, so the late
    /// completion of a device that has gone changes nothing.
    private var attaching: [UInt64: UUID] = [:]
    private var waiting: [UInt64: AAUSBAccessory] = [:]
    private var lastError: String?

    init(machine: VZVirtualMachine, queue: DispatchQueue) {
        self.machine = machine
        self.queue = queue
        super.init()
        queue.sync { machine.usbControllers.first?.delegate = self }
        // No criteria: every assigned accessory (criteria are mostly ignored anyway, FB24018643).
        AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: []) { [self] present, error in
            if let error {
                log("usb: receiving accessories failed: \(error)")
                queue.async { self.lastError = error.localizedDescription }
                return
            }
            log("usb: receiving accessories, \(present.count) assigned now")
            for accessory in present { offer(accessory) }
        }
    }

    var status: (attached: Int, lastError: String?) {
        queue.sync { (attached.count, lastError) }
    }

    func close() {
        queue.sync {
            accepting = false
            waiting.removeAll()
            machine.usbControllers.first?.delegate = nil
        }
        AAUSBAccessoryManager.shared.unregisterListener(self) {}
    }

    /// No new attaches (a stop or a hibernate has begun); arrivals wait.
    func hold() {
        queue.sync { accepting = false }
    }

    /// Attaches again (after a resume, or a stop or hibernate that failed), starting with what
    /// arrived meanwhile.
    func release() {
        queue.async { [self] in
            accepting = true
            let pending = waiting.values
            waiting.removeAll()
            for accessory in pending { attach(accessory) }
        }
    }

    // MARK: AAUSBAccessoryListener (on AccessoryAccess's queue)

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        offer(usbAccessory)
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        let id = usbAccessory.registryID
        queue.async { [self] in
            waiting[id] = nil
            attaching[id] = nil
            if attached.removeValue(forKey: id) != nil { log("usb: \(Self.describe(usbAccessory)) left the VM") }
        }
    }

    // MARK: VZUSBController.Delegate (on the VM's queue)

    func usbController(_ usbController: VZUSBController, usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice) {
        // VZ has detached it already; AccessoryAccess's disconnect says which one, so either
        // order leaves the same state.
        attached = attached.filter { $0.value !== device }
    }

    // MARK: -

    private func offer(_ accessory: AAUSBAccessory) {
        queue.async { [self] in attach(accessory) }
    }

    /// On the VM's queue.
    private func attach(_ accessory: AAUSBAccessory) {
        let id = accessory.registryID
        guard attached[id] == nil, attaching[id] == nil else { return }
        guard accepting, machine.state == .running else {
            waiting[id] = accessory
            return
        }
        guard let controller = machine.usbControllers.first else { return }
        let device: VZUSBPassthroughDevice
        do {
            device = try VZUSBPassthroughDevice(configuration: VZUSBPassthroughDeviceConfiguration(device: accessory))
        } catch {
            fail(accessory, error)
            return
        }
        let token = UUID()
        attaching[id] = token
        controller.attach(device: device) { [self] error in
            guard attaching[id] == token else { return }  // disconnected meanwhile
            attaching[id] = nil
            if let error {
                fail(accessory, error)
            } else {
                attached[id] = device
                log("usb: attached \(Self.describe(accessory))")
            }
        }
    }

    private func fail(_ accessory: AAUSBAccessory, _ error: Error) {
        // A stop or hibernate began meanwhile: tried again if that fails (`release()`), dropped
        // with the rest at the VM's end.
        guard accepting else {
            waiting[accessory.registryID] = accessory
            return
        }
        lastError = "\(Self.describe(accessory)): \(error.localizedDescription)"
        log("usb: attaching \(Self.describe(accessory)) failed: \(error)")
    }

    /// Vendor and product IDs from the device descriptor (bytes 8–11, little endian).
    static func describe(_ accessory: AAUSBAccessory) -> String {
        let d = [UInt8](accessory.deviceDescriptorData)
        guard d.count >= 12 else { return "USB device \(accessory.registryID)" }
        return String(format: "%04x:%04x", Int(d[8]) | Int(d[9]) << 8, Int(d[10]) | Int(d[11]) << 8)
    }
}
