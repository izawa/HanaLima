import Foundation
import Virtualization

/// A Lima instance's VM on Virtualization.framework, driven from its own serial queue (there is
/// no main run loop in the driver). Mirrors what Lima's vz driver attaches: EFI with the
/// instance's variable store, the machine identifier, the disk and cidata, virtiofs shares, a
/// serial console logged to serialv.log, entropy and a balloon, and the usernet NIC as a file
/// handle with Lima's MAC address. No display, no vsock (the guest agent is forwarded over SSH).
final class VZMachine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.izawa.HanaLima.driver.vz")
    private let machine: VZVirtualMachine
    private let delegate: Delegate

    /// `onStop` is called once, when the guest stops on its own or crashes (not after `stop()`).
    init(spec: InstanceSpec, networkHandle: FileHandle, onStop: @escaping @Sendable (Error?) -> Void) throws {
        let config = try Self.configuration(spec: spec, networkHandle: networkHandle)
        let vm = VZVirtualMachine(configuration: config, queue: queue)
        let delegate = Delegate(onStop: onStop)
        // VZVirtualMachine's properties are confined to its queue.
        queue.sync { vm.delegate = delegate }
        machine = vm
        self.delegate = delegate
    }

    var state: VZVirtualMachine.State { queue.sync { machine.state } }

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

    private final class Delegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
        let onStop: @Sendable (Error?) -> Void
        init(onStop: @escaping @Sendable (Error?) -> Void) { self.onStop = onStop }
        func guestDidStop(_ vm: VZVirtualMachine) { onStop(nil) }
        func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) { onStop(error) }
    }

    // MARK: - Configuration

    static func configuration(spec: InstanceSpec, networkHandle: FileHandle) throws -> VZVirtualMachineConfiguration {
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
        if fm.fileExists(atPath: spec.cidataURL.path) {
            storage.append(VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: spec.cidataURL, readOnly: true)))
        }
        config.storageDevices = storage

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: networkHandle)
        if let mac = VZMACAddress(string: spec.macAddress) { net.macAddress = mac }
        config.networkDevices = [net]

        config.directorySharingDevices = spec.mounts.map { mount in
            let share = VZSingleDirectoryShare(directory: VZSharedDirectory(
                url: URL(fileURLWithPath: mount.location, isDirectory: true), readOnly: !mount.writable))
            let device = VZVirtioFileSystemDeviceConfiguration(tag: mount.tag)
            device.share = share
            return device
        }

        // Lima recreates serialv.log on every boot; the app's log tab follows it.
        fm.createFile(atPath: spec.serialLogURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: spec.serialLogURL) {
            try? handle.truncate(atOffset: 0)
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: handle)
            config.serialPorts = [serial]
        }

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        try config.validate()
        return config
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
