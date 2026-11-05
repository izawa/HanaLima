import Foundation
import Virtualization

/// A Lima instance's VM on Virtualization.framework, driven from its own serial queue (there is
/// no main run loop in the driver). Mirrors what Lima's vz driver attaches: EFI with the
/// instance's variable store, the machine identifier, the disk and cidata, virtiofs shares, a
/// serial console (both ways, see SerialConsole), entropy and a balloon, the vsock device for
/// the guest agent, the usernet NIC as a file handle with Lima's MAC address, and, when
/// `video.display` isn't "none", a screen with keyboard and pointer (shown by DisplayWindow).
final class VZMachine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.izawa.HanaLima.driver.vz")
    private let machine: VZVirtualMachine
    private let delegate: Delegate
    /// For a `VZVirtualMachineView` on the main thread; nil without a display. The view takes
    /// a machine of another queue (Lima's vz does the same); the box just carries it there.
    let displayMachine: Box?

    struct Box: @unchecked Sendable { let machine: VZVirtualMachine }

    static let displayWidth = 1920
    static let displayHeight = 1200

    /// `onStop` is called once, when the guest stops on its own or crashes (not after `stop()`).
    /// `networkHandles`: the usernet NIC first, then one per `spec.nics` (vzNAT entries get nil).
    /// `serial`: the guest's end of the console socket pair.
    init(spec: InstanceSpec, networkHandles: [FileHandle?], serial: FileHandle, onStop: @escaping @Sendable (Error?) -> Void) throws {
        let config = try Self.configuration(spec: spec, networkHandles: networkHandles, serial: serial)
        let vm = VZVirtualMachine(configuration: config, queue: queue)
        let delegate = Delegate(onStop: onStop)
        // VZVirtualMachine's properties are confined to its queue.
        queue.sync { vm.delegate = delegate }
        displayMachine = spec.display ? Box(machine: vm) : nil
        machine = vm
        self.delegate = delegate
    }

    var state: VZVirtualMachine.State { queue.sync { machine.state } }

    var stateName: String {
        switch state {
        case .stopped: "stopped"
        case .running: "running"
        case .paused: "paused"
        case .error: "error"
        case .starting: "starting"
        case .pausing: "pausing"
        case .resuming: "resuming"
        case .stopping: "stopping"
        case .saving: "saving"
        case .restoring: "restoring"
        @unknown default: "unknown"
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                self.machine.start { result in
                    switch result {
                    case .success: c.resume()
                    case .failure(let error): c.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// ACPI power button. Returns false if the guest doesn't accept it (not running yet).
    func requestStop() -> Bool {
        queue.sync {
            guard machine.canRequestStop else { return false }
            return (try? machine.requestStop()) != nil
        }
    }

    /// Pulls the plug. Waits out a start or stop in progress first, and returns only once the
    /// machine is stopped (or in the error state).
    func stop() async throws {
        let started = Date()
        while true {
            switch state {
            case .stopped, .error: return
            case .running, .paused:
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    queue.async {
                        guard self.machine.canStop else { c.resume(); return }
                        self.machine.stop { error in
                            if let error { c.resume(throwing: error) } else { c.resume() }
                        }
                    }
                }
            default:  // starting, stopping, pausing, resuming, saving, restoring
                if Date().timeIntervalSince(started) > 60 { throw DriverError("VM stuck in state \(state.rawValue)") }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// A connection to the guest's vsock port (Lima's guest agent). Returns a dup of the
    /// connection's descriptor for the caller to own. Call from any thread but the VZ queue
    /// (it waits for the completion).
    func connectVsock(port: UInt32, timeout: TimeInterval = 10) throws -> Int32 {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        nonisolated(unsafe) var result: Result<VZVirtioSocketConnection, Error>?
        nonisolated(unsafe) var abandoned = false
        queue.async {
            guard let device = self.machine.socketDevices.first as? VZVirtioSocketDevice else {
                lock.lock(); result = .failure(DriverError("no vsock device")); lock.unlock()
                done.signal()
                return
            }
            device.connect(toPort: port) { r in
                lock.lock()
                if abandoned {
                    // The caller gave up: nobody will take this descriptor.
                    if case .success(let c) = r { c.close() }
                } else {
                    result = r
                }
                lock.unlock()
                done.signal()
            }
        }
        // Bounded: a completion that never comes (the VM is gone) must not hold a probe forever.
        if done.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); abandoned = true; let late = result; lock.unlock()
            guard let late else { throw DriverError("vsock connect to port \(port) timed out after \(Int(timeout)) s") }
            result = late
        }
        lock.lock(); let outcome = result; lock.unlock()
        let connection = try outcome!.get()
        // The dup outlives the connection object: closing the object only drops its descriptor.
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else { connection.close(); throw DriverError("dup of the vsock descriptor failed (errno \(errno))") }
        connection.close()
        return fd
    }

    private final class Delegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
        let onStop: @Sendable (Error?) -> Void
        init(onStop: @escaping @Sendable (Error?) -> Void) { self.onStop = onStop }
        func guestDidStop(_ vm: VZVirtualMachine) { onStop(nil) }
        func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) { onStop(error) }
    }

    // MARK: - Configuration

    static func configuration(spec: InstanceSpec, networkHandles: [FileHandle?], serial: FileHandle) throws -> VZVirtualMachineConfiguration {
        let fm = FileManager.default
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                              min(spec.cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        config.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                                min(spec.memoryBytes, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

        let loader = VZEFIBootLoader()
        loader.variableStore = fm.fileExists(atPath: spec.efiURL.path)
            ? VZEFIVariableStore(url: spec.efiURL)
            : try VZEFIVariableStore(creatingVariableStoreAt: spec.efiURL)
        config.bootLoader = loader

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try machineIdentifier(at: spec.identifierURL)
        config.platform = platform

        var storage: [VZStorageDeviceConfiguration] = [VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(url: spec.diskURL, readOnly: false,
                                                               cachingMode: .automatic, synchronizationMode: .fsync))]
        // Lima's order: disk (vda), additional disks (vdb…, cidata's boot script formats and
        // mounts them by that name), then cidata.
        for disk in spec.disks {
            storage.append(VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: disk.image, readOnly: false,
                                                                   cachingMode: .automatic, synchronizationMode: .fsync)))
        }
        if spec.hosted?.cidata ?? true, fm.fileExists(atPath: spec.cidataURL.path) {
            storage.append(VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: spec.cidataURL, readOnly: true)))
        }
        if let seed = spec.hosted?.seed {
            storage.append(VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true)))
        }
        config.storageDevices = storage

        // A hosted boot's ISOs as USB mass storage: EFI boots the installer from there, and the
        // guest sees them as removable media (the fix-up ISO is mounted by its label).
        if let hosted = spec.hosted {
            let media = try [hosted.bootImage, hosted.iso, hosted.helper].compactMap { $0 }.map {
                VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: $0, readOnly: true))
            }
            if !media.isEmpty {
                let usb = VZXHCIControllerConfiguration()
                usb.usbDevices = media
                config.usbControllers = [usb]
            }
        }

        // NIC 0 is usernet (absent in the isolation profile); the rest follow lima.yaml's `networks:`.
        var nics: [VZVirtioNetworkDeviceConfiguration] = []
        if let usernetHandle = networkHandles.first ?? nil {
            nics.append(nic(handle: usernetHandle, mac: spec.macAddress))
        } else if spec.usernet {
            throw DriverError("no usernet handle")
        } else {
            // Isolation profile: NIC 0 exists with Lima's MAC but is plugged into nothing. cidata's
            // network-config names eth0 by that MAC; without the device cloud-init drops the whole
            // network config and systemd-networkd-wait-online then waits two minutes at every boot.
            // An unplugged eth0 (no carrier) is configured as optional and nothing waits for it.
            let unplugged = VZVirtioNetworkDeviceConfiguration()
            unplugged.attachment = nil
            if let m = VZMACAddress(string: spec.macAddress) { unplugged.macAddress = m }
            nics.append(unplugged)
        }
        for (i, entry) in spec.nics.enumerated() {
            switch entry {
            case .vzNAT(let mac):
                let net = VZVirtioNetworkDeviceConfiguration()
                net.attachment = VZNATNetworkDeviceAttachment()
                if let m = VZMACAddress(string: mac) { net.macAddress = m }
                nics.append(net)
            case .socket(_, let mac):
                guard let handle = networkHandles[i + 1] else { throw DriverError("no handle for NIC \(i + 1)") }
                nics.append(nic(handle: handle, mac: mac))
            case .lima(let name):
                throw DriverError("network lima:\(name) is not supported by this driver (use a HanaLima network or vzNAT)")
            }
        }
        config.networkDevices = nics

        // The guest agent's vsock (Lima's guest agent listens on port 2222).
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        config.directorySharingDevices = spec.mounts.map { mount in
            let share = VZSingleDirectoryShare(directory: VZSharedDirectory(
                url: URL(fileURLWithPath: mount.location, isDirectory: true), readOnly: !mount.writable))
            let device = VZVirtioFileSystemDeviceConfiguration(tag: mount.tag)
            device.share = share
            return device
        }
        if spec.rosetta, let rosetta = rosettaShare() {
            config.directorySharingDevices.append(rosetta)
        }

        // The console both ways: SerialConsole logs it to serialv.log and serves serialv.sock.
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: serial, fileHandleForWriting: serial)
        config.serialPorts = [console]

        if spec.display {
            // Lima's vz size. The window scales it (DisplayWindow).
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: displayWidth, heightInPixels: displayHeight)]
            config.graphicsDevices = [graphics]
            config.keyboards = [VZUSBKeyboardConfiguration()]
            config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        try config.validate()
        return config
    }

    /// macOS's Rosetta as the `vz-rosetta` share (what Lima's vz attaches), with the AOT cache
    /// socket Lima's boot script sets up. Unlike Lima this never installs Rosetta: when it's
    /// missing the VM boots without the share and the log says what to run.
    private static func rosettaShare() -> VZVirtioFileSystemDeviceConfiguration? {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .notSupported:
            log("Rosetta is not supported on this Mac; starting without it")
            return nil
        case .notInstalled:
            log("Rosetta is not installed on this Mac (softwareupdate --install-rosetta); starting without it")
            return nil
        case .installed:
            break
        @unknown default:
            return nil
        }
        do {
            let share = try VZLinuxRosettaDirectoryShare()
            try share.setCachingOptions(.unixSocket("/run/rosettad/rosetta.sock"))
            let device = VZVirtioFileSystemDeviceConfiguration(tag: "vz-rosetta")
            device.share = share
            return device
        } catch {
            log("Rosetta share failed: \(error); starting without it")
            return nil
        }
    }

    private static func nic(handle: FileHandle, mac: String) -> VZVirtioNetworkDeviceConfiguration {
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: handle)
        if let m = VZMACAddress(string: mac) { net.macAddress = m }
        return net
    }

    /// Lima's `vz-identifier` (written by Create); made here if it's missing.
    static func machineIdentifier(at url: URL) throws -> VZGenericMachineIdentifier {
        if let data = try? Data(contentsOf: url), let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            return id
        }
        let id = VZGenericMachineIdentifier()
        try id.dataRepresentation.write(to: url)
        return id
    }
}
