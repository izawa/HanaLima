import AppKit
import Virtualization

/// A VM HanaLima runs itself with Virtualization.framework, to install an OS from an installer
/// ISO into a Lima instance's own disk (see docs/07). Lima can't boot installers, but it keeps
/// its files in `~/.lima/<name>/` and reuses `disk`, `vz-efi` and `vz-identifier` as they are,
/// so an OS installed here boots under `limactl start` afterwards.
///
/// Runs in the app's process (the view needs that), so quitting the app stops the install.
/// The app must be signed with `com.apple.security.virtualization`.
@MainActor
@Observable
final class InstallerVM {
    enum State: Equatable {
        case starting, running, stopped
        case failed(String)
    }

    let instanceDir: URL
    let iso: URL?
    private(set) var state: State = .starting
    let machine: VZVirtualMachine
    private let delegate = Delegate()

    /// `iso` nil boots from the disk (after the install, to run the fix-up or to check it boots).
    /// `helper` is the small ISO with limaify.sh. CPUs and memory come from lima.yaml.
    init(instanceDir: URL, iso: URL?, helper: URL?, cpus: Int, memoryBytes: UInt64) throws {
        self.instanceDir = instanceDir
        self.iso = iso
        let config = try Self.configuration(instanceDir: instanceDir, iso: iso, helper: helper,
                                            cpus: cpus, memoryBytes: memoryBytes)
        machine = VZVirtualMachine(configuration: config)
        machine.delegate = delegate
        delegate.owner = self
    }

    func start() {
        state = .starting
        machine.start { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success: self?.state = .running
                case .failure(let error): self?.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Asks the guest to shut down (ACPI power button); `force` pulls the plug.
    func stop(force: Bool = false) {
        guard state == .running else { return }
        if !force, machine.canRequestStop, (try? machine.requestStop()) != nil { return }
        guard machine.canStop else { return }
        machine.stop { [weak self] error in
            Task { @MainActor in
                if let error { self?.state = .failed(error.localizedDescription) } else { self?.state = .stopped }
            }
        }
    }

    /// The VM is created on the main queue, so VZ calls back on it.
    @MainActor
    private final class Delegate: NSObject, VZVirtualMachineDelegate {
        weak var owner: InstallerVM?
        nonisolated func guestDidStop(_ vm: VZVirtualMachine) {
            MainActor.assumeIsolated { owner?.state = .stopped }
        }
        nonisolated func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
            let message = error.localizedDescription
            MainActor.assumeIsolated { owner?.state = .failed(message) }
        }
    }

    // MARK: - Configuration (what the prototype did, see Prototypes/vz-installer)

    static func configuration(instanceDir: URL, iso: URL?, helper: URL?, cpus: Int,
                              memoryBytes: UInt64) throws -> VZVirtualMachineConfiguration {
        let fm = FileManager.default
        let disk = instanceDir.appending(path: "disk")
        let efi = instanceDir.appending(path: "vz-efi")
        let ident = instanceDir.appending(path: "vz-identifier")

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                              min(cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        config.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                                min(memoryBytes, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

        // EFI with the instance's variable store: Lima keeps an existing one, so the boot entry
        // the installer writes is what Lima boots later.
        let loader = VZEFIBootLoader()
        loader.variableStore = fm.fileExists(atPath: efi.path)
            ? VZEFIVariableStore(url: efi)
            : try VZEFIVariableStore(creatingVariableStoreAt: efi)
        config.bootLoader = loader

        // Lima's machine identifier (written by limactl create), so the OS sees one machine.
        let platform = VZGenericPlatformConfiguration()
        if let data = try? Data(contentsOf: ident), let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = id
        } else {
            let id = VZGenericMachineIdentifier()
            try id.dataRepresentation.write(to: ident)
            platform.machineIdentifier = id
        }
        config.platform = platform

        config.storageDevices = [VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false))]
        // ISOs as USB mass storage: EFI boots the installer from there, and the guest sees them
        // as removable media (the helper ISO is mounted by its label).
        let cds = try [iso, helper].compactMap { $0 }.map {
            VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: $0, readOnly: true))
        }
        if !cds.isEmpty {
            let usb = VZXHCIControllerConfiguration()
            usb.usbDevices = cds
            config.usbControllers = [usb]
        }

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [net]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // The guest's serial console, kept next to the instance for diagnosis.
        let log = instanceDir.appending(path: "hanalima-installer-serial.log")
        fm.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: handle)
            config.serialPorts = [serial]
        }

        try config.validate()
        return config
    }
}
