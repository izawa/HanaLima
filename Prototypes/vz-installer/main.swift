// vz-installer: boots an installer ISO with Virtualization.framework into a Lima instance's own
// disk, so an OS installed by hand ends up where Lima expects it. Spike for "create from ISO".
//
// Uses the instance's files in place: ~/.lima/<name>/disk (made by `limactl create` from a
// placeholder image), vz-efi (created here if missing; Lima keeps an existing one, so the boot
// entry the installer writes survives) and vz-identifier (Lima's machine identifier, read as is).
//
// Build:
//   swiftc -O -o vz-installer main.swift -framework Virtualization -framework AppKit
//   codesign -s - -f --entitlements entitlements.plist vz-installer
// Run:
//   ./vz-installer --name <instance> [--iso <installer.iso>] [--helper <helper.iso>] [--cpus 2] [--memory 4]
// Without --iso the VM boots from its disk (for the post-install fix-up, or to check EFI boot).

import AppKit
import Virtualization

var name = "", iso: URL?, helper: URL?, seed: URL?, kernel: URL?, initrd: URL?, cmdline = "", serialIn: URL?, bootImage: URL?, cpus = 2, memoryGiB: UInt64 = 4, headless = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--name": name = args.next() ?? ""
    case "--iso": iso = URL(filePath: args.next() ?? "")
    case "--helper": helper = URL(filePath: args.next() ?? "")
    case "--seed": seed = URL(filePath: args.next() ?? "")
    case "--boot": bootImage = URL(filePath: args.next() ?? "")  // a FAT image with EFI/boot/*.efi and our grub.cfg, attached before the ISO
    case "--kernel": kernel = URL(filePath: args.next() ?? "")
    case "--initrd": initrd = URL(filePath: args.next() ?? "")
    case "--cmdline": cmdline = args.next() ?? ""
    case "--headless": headless = true
    case "--serial-in": serialIn = URL(filePath: args.next() ?? "")  // a FIFO: what is written to it is typed into the guest's serial console
    case "--cpus": cpus = Int(args.next() ?? "2") ?? 2
    case "--memory": memoryGiB = UInt64(args.next() ?? "4") ?? 4
    default: FileHandle.standardError.write("unknown argument \(a)\n".data(using: .utf8)!); exit(2)
    }
}
guard !name.isEmpty else { print("usage: vz-installer --name <instance> [--iso x.iso] [--helper h.iso]"); exit(2) }

let dir = URL(filePath: NSHomeDirectory()).appending(path: ".lima/\(name)", directoryHint: .isDirectory)
let disk = dir.appending(path: "disk")
let efi = dir.appending(path: "vz-efi")
let ident = dir.appending(path: "vz-identifier")
guard FileManager.default.fileExists(atPath: disk.path) else { print("no disk at \(disk.path)"); exit(1) }

func fail(_ msg: String) -> Never { FileHandle.standardError.write("\(msg)\n".data(using: .utf8)!); exit(1) }

let config = VZVirtualMachineConfiguration()
config.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
config.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, min(memoryGiB << 30, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

// Direct kernel boot (--kernel/--initrd/--cmdline: an uncompressed arm64 Image, e.g. for the
// installer's autoinstall which needs "autoinstall" on the command line), else EFI with the
// instance's variable store.
if let kernel {
    let linux = VZLinuxBootLoader(kernelURL: kernel)
    linux.initialRamdiskURL = initrd
    linux.commandLine = cmdline
    config.bootLoader = linux
    print("direct kernel boot: \(cmdline)")
} else {
    let loader = VZEFIBootLoader()
    if FileManager.default.fileExists(atPath: efi.path) {
        loader.variableStore = VZEFIVariableStore(url: efi)
        print("using existing vz-efi")
    } else {
        do { loader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: efi) } catch { fail("vz-efi: \(error)") }
        print("created vz-efi")
    }
    config.bootLoader = loader
}

// Lima's machine identifier, so the installed OS sees the same machine under Lima.
let platform = VZGenericPlatformConfiguration()
if let data = try? Data(contentsOf: ident), let id = VZGenericMachineIdentifier(dataRepresentation: data) {
    platform.machineIdentifier = id
    print("using Lima's vz-identifier")
} else {
    let id = VZGenericMachineIdentifier()
    do { try id.dataRepresentation.write(to: ident) } catch { fail("vz-identifier: \(error)") }
    platform.machineIdentifier = id
    print("created vz-identifier")
}
config.platform = platform

do {
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false))]
    // The cloud-init seed as a virtio block device: it is there before cloud-init's ds-identify
    // runs, whereas a USB device may enumerate too late to be found (seen on Ubuntu 26.04).
    if let seed {
        config.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true)))
    }
    // ISOs as USB mass storage: what EFI boots from, and what the guest sees as removable media.
    config.usbControllers = []
    var usbDevices: [VZUSBDeviceConfiguration] = []
    for cd in [bootImage, iso, helper].compactMap({ $0 }) {
        usbDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: cd, readOnly: true)))
    }
    if !usbDevices.isEmpty {
        let usb = VZXHCIControllerConfiguration()
        usb.usbDevices = usbDevices
        config.usbControllers = [usb]
    }
} catch { fail("storage: \(error)") }

let net = VZVirtioNetworkDeviceConfiguration()
net.attachment = VZNATNetworkDeviceAttachment()
config.networkDevices = [net]
config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

if !headless {
    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)]
    config.graphicsDevices = [graphics]
    config.keyboards = [VZUSBKeyboardConfiguration()]
    config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
}

// Serial console to a log next to the instance, for diagnosis.
let serialLog = dir.appending(path: "vz-installer-serial.log")
FileManager.default.createFile(atPath: serialLog.path, contents: nil)
if let h = try? FileHandle(forWritingTo: serialLog) {
    let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
    let input = serialIn.flatMap { try? FileHandle(forReadingFrom: $0) }
    serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: input, fileHandleForWriting: h)
    config.serialPorts = [serial]
}

do { try config.validate() } catch { fail("configuration: \(error)") }

final class Delegate: NSObject, VZVirtualMachineDelegate, NSApplicationDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) { print("guest stopped"); NSApp.terminate(nil) }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) { print("stopped with error: \(error)"); NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let delegate = Delegate()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = delegate

let menu = NSMenu()
let appItem = NSMenuItem(); menu.addItem(appItem)
let appMenu = NSMenu(); appItem.submenu = appMenu
appMenu.addItem(withTitle: "Quit vz-installer (stops the VM)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
app.mainMenu = menu

let vm = VZVirtualMachine(configuration: config)
vm.delegate = delegate
let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
view.virtualMachine = vm
view.capturesSystemKeys = true
let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
window.title = "vz-installer · \(name)" + (iso.map { " · \($0.lastPathComponent)" } ?? " · boot from disk")
window.contentView = view
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

vm.start { result in
    switch result {
    case .success: print("VM started")
    case .failure(let error): fail("start: \(error)")
    }
}
app.run()
