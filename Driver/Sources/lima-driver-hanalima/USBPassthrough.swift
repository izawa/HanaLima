import AccessoryAccess
import Foundation
import LimaKit
import Virtualization

/// The USB accessories the user assigns to HanaLima's driver in macOS's "Virtual Machine
/// Accessories" menu (docs/19). Every driver of a running VM is told of every such accessory;
/// it attaches to its VM's xHCI controller only those the routes (`usb-routes.json`) send to
/// this VM, and detaches one the routes send elsewhere, which then reaches the other VM's
/// driver as a new connection. The routes are read at the start and whenever their folder
/// changes. A stop, a hibernate or a pause holds it (nothing attached or detached; what is
/// attached stays recorded) and a release goes on by the routes of then; the VM's end closes
/// it. All state lives on the VM's queue.
@available(macOS 27, *)
final class USBPassthrough: NSObject, AAUSBAccessoryListener, VZUSBController.Delegate, @unchecked Sendable {
    /// A device that the routes newly send here while it is connected may still be attached to
    /// the VM it went to before: wait this long for that VM to let it go (it then comes back
    /// as a new connection) before attaching it (docs/19, moving between VMs).
    static let letGoGrace: TimeInterval = 2

    private let machine: VZVirtualMachine
    private let queue: DispatchQueue
    private let me: USBTarget
    private let support: URL
    private var accepting = true
    /// Nil while there are none that can be read: nothing is attached or detached then.
    private var routes: USBRoutes?
    private var routesError: String?
    private var receiveError: String?
    /// Rules found to match two connected devices this session: those devices stay held even
    /// while one of them is away being enumerated again (or the other would be attached in
    /// the gap). Forgotten when the routes change.
    private var duplicates = Set<USBRoutes.Match>()
    /// When a device of a duplicate rule last left: the rule stops holding only a grace after.
    private var duplicateLeft: [USBRoutes.Match: Date] = [:]
    /// By the accessory's IORegistry ID (one connection).
    private var entries: [UInt64: Entry] = [:]
    private var watcher: DispatchSourceFileSystemObject?

    private struct Entry {
        var accessory: AAUSBAccessory
        var identity: USBDeviceIdentity
        var state: USBRoutingStatus.State = .observed
        var device: VZUSBPassthroughDevice?
        /// The attach or detach in flight: a disconnect drops the entry, so a late completion
        /// for a device that has gone changes nothing.
        var token: UUID?
        /// Not attached before this (`letGoGrace`).
        var notBefore = Date.distantPast
        var error: String?
        /// VZ can't pass this device through (an Apple device, isochronous endpoints): never
        /// tried again, even with new routes.
        var unsupported = false
        /// AccessoryAccess says it has gone while VZ still has it attached (accessoryaccessd
        /// restarted): kept until VZ lets it go.
        var gone = false
    }

    init(machine: VZVirtualMachine, queue: DispatchQueue, me: USBTarget, support: URL) {
        self.machine = machine
        self.queue = queue
        self.me = me
        self.support = support
        super.init()
        queue.sync {
            machine.usbControllers.first?.delegate = self
            watch()
            reload()
        }
        // No criteria: every assigned accessory (criteria are mostly ignored anyway, FB24018643).
        AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: []) { [self] present, error in
            if let error {
                log("usb: receiving accessories failed: \(error)")
                queue.async { self.receiveError = error.localizedDescription }
                return
            }
            log("usb: receiving accessories, \(present.count) assigned now")
            arrived(present)
        }
    }

    var status: USBRoutingStatus {
        queue.sync {
            let all = entries.values.map(\.identity)
            let devices = entries.sorted { $0.key < $1.key }.map { id, entry in
                var destination: USBTarget?, rule: USBRouteDecision.Rule?, hold: USBRouteDecision.Hold?
                switch decide(entry.identity, among: all) {
                case .send(let target, let by): (destination, rule) = (target, by)
                case .hold(let why): hold = why
                case nil: break
                }
                return USBRoutingStatus.Device(registryID: String(id, radix: 16), identity: entry.identity,
                                               destination: destination, rule: rule, hold: hold,
                                               state: entry.state, error: entry.error)
            }
            return USBRoutingStatus(me: me, revision: routes?.revision, error: routesError ?? receiveError, devices: devices)
        }
    }

    func close() {
        queue.sync {
            accepting = false
            entries.removeAll()
            watcher?.cancel()
            watcher = nil
            machine.usbControllers.first?.delegate = nil
        }
        // Wait for AccessoryAccess to finish before the process may end: a driver that exited
        // with the unregistration still in flight was followed by accessoryaccessd crashing
        // (docs/19).
        let done = DispatchSemaphore(value: 0)
        AAUSBAccessoryManager.shared.unregisterListener(self) { done.signal() }
        if done.wait(timeout: .now() + 2) == .timedOut { log("usb: unregistering didn't finish in 2 s") }
    }

    /// Nothing attached or detached (a stop, a hibernate or a pause has begun).
    func hold() {
        queue.sync { accepting = false }
    }

    /// Goes on by the routes of now (after a resume, or a stop or hibernate that failed).
    func release() {
        queue.async { [self] in
            accepting = true
            reload()
            reconcile()
        }
    }

    // MARK: AAUSBAccessoryListener (on AccessoryAccess's queue)

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        arrived([usbAccessory])
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        let id = usbAccessory.registryID
        queue.async { [self] in
            guard let entry = entries[id] else { return }
            if entry.device != nil {
                // Not by VZ: AccessoryAccess dropped it (its daemon restarted), the guest still
                // has it. VZ's delegate ends the entry.
                entries[id]?.gone = true
                log("usb: AccessoryAccess dropped \(entry.identity.ids), still attached")
                return
            }
            remove(id)
        }
    }

    // MARK: VZUSBController.Delegate (on the VM's queue)

    func usbController(_ usbController: VZUSBController, usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice) {
        // VZ has detached it already; AccessoryAccess's disconnect drops the entry.
        for (id, entry) in entries where entry.device === device {
            if entry.gone {
                remove(id)
                continue
            }
            entries[id]?.device = nil
            entries[id]?.state = .observed
            entries[id]?.token = nil
        }
    }

    /// On the VM's queue: the device has gone (AccessoryAccess said so, and VZ no longer has
    /// it). Every way a device ends comes here, so duplicates are let go the same way.
    private func remove(_ id: UInt64) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if entry.device != nil || entry.gone { log("usb: \(entry.identity.ids) left the VM") }
        reconcile()
        // A device enumerated again comes back within the grace: only after it, a rule that
        // no longer matches two connected devices stops holding (each rule by its own last
        // departure).
        let left = [entry.identity.serialMatch, entry.identity.portMatch].compactMap { $0 }.filter(duplicates.contains)
        guard !left.isEmpty else { return }
        let now = Date()
        for match in left { duplicateLeft[match] = now }
        queue.asyncAfter(deadline: .now() + Self.letGoGrace) { [self] in
            let all = entries.values.map(\.identity)
            for match in left where duplicateLeft[match] == now
                && all.filter({ $0.serialMatch == match || $0.portMatch == match }).count < 2 {
                duplicates.remove(match)
                duplicateLeft[match] = nil
            }
            reconcile()
        }
    }

    // MARK: - Routes

    /// The routes' folder: a save replaces the file (atomically), so the file itself can't be
    /// watched.
    private func watch() {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let fd = open(support.path, O_EVTONLY)
        guard fd >= 0 else {
            log("usb: can't watch \(support.path) for changes to the routes")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            reload()
            reconcile()
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    /// On the VM's queue. Devices the new routes send here that weren't ours before wait
    /// `letGoGrace` before they are attached.
    private func reload() {
        switch USBRoutes.load(support: support) {
        case .success(let new):
            routesError = nil
            guard new != routes else { return }
            let wasOurs = Set(entries.filter { isOurs($0.value.identity) }.keys)
            routes = new
            duplicates = []
            duplicateLeft = [:]
            log("usb: routes \(new.revision.isEmpty ? "(none saved)" : new.revision)")
            let until = Date().addingTimeInterval(Self.letGoGrace)
            for (id, entry) in entries {
                if !entry.unsupported { entries[id]?.error = nil }
                if entry.state == .observed, !wasOurs.contains(id), isOurs(entry.identity) { entries[id]?.notBefore = until }
            }
        case .failure(let error):
            if routesError != error.description { log("usb: \(error)") }
            routes = nil
            routesError = error.description
        }
    }

    /// Where the routes send `identity`; nil without routes.
    private func decide(_ identity: USBDeviceIdentity, among all: [USBDeviceIdentity]) -> USBRouteDecision? {
        guard let routes else { return nil }
        if [identity.serialMatch, identity.portMatch].contains(where: { $0.map(duplicates.contains) == true }) {
            return .hold(.duplicate)
        }
        return routes.decision(for: identity, among: all)
    }

    private func isOurs(_ identity: USBDeviceIdentity) -> Bool {
        if case .send(let target, _) = decide(identity, among: entries.values.map(\.identity)) { return target == me }
        return false
    }

    // MARK: - Attaching and detaching

    /// Records them all before deciding, so two devices one rule can't tell apart (both in the
    /// list at registration) are both held, never one attached first.
    private func arrived(_ accessories: [AAUSBAccessory]) {
        // Off AccessoryAccess's queue: unarchiving or calling back into it there traps (docs/19).
        queue.async { [self] in
            for accessory in accessories {
                let id = accessory.registryID
                guard entries[id] == nil else { continue }  // in the present list and a connect both
                let ids = USBDeviceIdentity.ids(descriptor: [UInt8](accessory.deviceDescriptorData)) ?? (0, 0)
                let identity = USBDeviceIdentity.read(registryID: id, vendor: ids.vendor, product: ids.product)
                entries[id] = Entry(accessory: accessory, identity: identity)
                log("usb: \(identity.ids) connected\(identity.readable ? "" : " (IORegistry not readable)")")
            }
            reconcile()
        }
    }

    /// On the VM's queue: attaches what the routes send here, detaches what they send elsewhere.
    private func reconcile() {
        guard routes != nil else { return }
        let all = entries.values.map(\.identity)
        for id in Array(entries.keys) {
            // The routes of now: an attach in this pass may have read new ones.
            guard let routes else { return }
            // The live entry: an attach in this pass may have read new routes.
            guard let entry = entries[id], let decision = decide(entry.identity, among: all) else { continue }
            // Only the rule that collided: the first the routes try (serial, then port).
            if case .hold(.duplicate) = routes.decision(for: entry.identity, among: all),
               let match = [entry.identity.serialMatch, entry.identity.portMatch].compactMap({ $0 })
                .first(where: { match in routes.rules.contains { $0.match == match } }) {
                duplicates.insert(match)
            }
            var ours = false
            if case .send(let target, _) = decision { ours = target == me }
            switch entry.state {
            case .attached where !ours: detach(id)
            // One that failed waits for its next connection, or new routes.
            case .observed where ours && entry.error == nil && !entry.unsupported, .waiting where ours: attach(id)
            case .waiting where !ours: entries[id]?.state = .observed
            default: break
            }
        }
    }

    private func attach(_ id: UInt64) {
        guard let entry = entries[id] else { return }
        guard accepting, machine.state == .running, let controller = machine.usbControllers.first else {
            entries[id]?.state = .waiting
            return
        }
        let wait = entry.notBefore.timeIntervalSinceNow
        guard wait <= 0 else {
            entries[id]?.state = .waiting
            queue.asyncAfter(deadline: .now() + wait) { [self] in reconcile() }
            return
        }
        // The folder's change notice may not have come yet: attach only by the routes of now.
        reload()
        guard let current = entries[id], isOurs(current.identity), current.notBefore.timeIntervalSinceNow <= 0 else {
            queue.async { [self] in reconcile() }  // a new pass, not one inside the caller's
            return
        }
        let device: VZUSBPassthroughDevice
        do {
            device = try VZUSBPassthroughDevice(configuration: VZUSBPassthroughDeviceConfiguration(device: entry.accessory))
        } catch {
            failed(id, "attaching", error)
            return
        }
        let token = UUID()
        entries[id]?.state = .attaching
        entries[id]?.token = token
        controller.attach(device: device) { [self] error in
            guard entries[id]?.token == token else { return }  // gone meanwhile
            entries[id]?.token = nil
            if let error {
                failed(id, "attaching", error)
            } else {
                entries[id]?.state = .attached
                entries[id]?.device = device
                entries[id]?.error = nil
                log("usb: attached \(entry.identity.ids)")
                reconcile()  // the routes may have changed meanwhile
            }
        }
    }

    /// The device then goes back to AccessoryAccess, which tells every driver of it as a new
    /// connection; the routes, already new here, keep this VM from taking it again.
    private func detach(_ id: UInt64) {
        guard let entry = entries[id], let device = entry.device else { return }
        guard accepting, machine.state == .running, let controller = machine.usbControllers.first else { return }
        let token = UUID()
        entries[id]?.state = .detaching
        entries[id]?.token = token
        controller.detach(device: device) { [self] error in
            guard entries[id]?.token == token else { return }
            entries[id]?.token = nil
            if let error {
                entries[id]?.state = .attached
                entries[id]?.error = "detaching: \(error.localizedDescription)"
                log("usb: detaching \(entry.identity.ids) failed: \(error)")
            } else if entries[id]?.gone == true {
                remove(id)  // AccessoryAccess has already let it go
            } else {
                entries[id]?.state = .observed
                entries[id]?.device = nil
                log("usb: detached \(entry.identity.ids) for another VM")
            }
        }
    }

    private func failed(_ id: UInt64, _ what: String, _ error: Error) {
        guard let entry = entries[id] else { return }
        // A stop or hibernate began meanwhile: tried again on release.
        entries[id]?.state = accepting ? .observed : .waiting
        guard accepting else { return }
        entries[id]?.error = "\(what): \(error.localizedDescription)"
        // VZErrorDomain -6: VZ doesn't pass this kind of device through at all.
        if (error as NSError).domain == VZErrorDomain, (error as NSError).code == -6 { entries[id]?.unsupported = true }
        log("usb: \(what) \(entry.identity.ids) failed: \(error)")
    }
}
