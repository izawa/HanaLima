import Foundation
import Virtualization

// Minimal VZ save test: EFI only (no disk), optional devices by argv flags.
let args = Set(CommandLine.arguments.dropFirst())
let dir = URL(fileURLWithPath: CommandLine.arguments.last!.hasPrefix("/") ? CommandLine.arguments.last! : FileManager.default.currentDirectoryPath)
let q = DispatchQueue(label: "vz")
let c = VZVirtualMachineConfiguration()
c.cpuCount = 1; c.memorySize = 512 << 20
let efi = VZEFIBootLoader()
let store = dir.appendingPathComponent("efi")
let restore = ProcessInfo.processInfo.environment["RESTORE"] != nil
if restore { efi.variableStore = VZEFIVariableStore(url: store) } else {
  try? FileManager.default.removeItem(at: store)
  efi.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: store)
}
let idURL = dir.appendingPathComponent("machine-id")
c.bootLoader = efi
c.platform = { let p = VZGenericPlatformConfiguration(); if restore, let d = try? Data(contentsOf: idURL), let m = VZGenericMachineIdentifier(dataRepresentation: d) { p.machineIdentifier = m } else { let m = VZGenericMachineIdentifier(); try? m.dataRepresentation.write(to: idURL); p.machineIdentifier = m }; return p }()
if args.contains("vsock") { c.socketDevices = [VZVirtioSocketDeviceConfiguration()] }
if args.contains("entropy") { c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()] }
if args.contains("balloon") { c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()] }
if args.contains("serial") {
  let s = VZVirtioConsoleDeviceSerialPortConfiguration()
  s.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: FileHandle(forReadingAtPath: "/dev/null"), fileHandleForWriting: { FileManager.default.createFile(atPath: dir.appendingPathComponent("serial.log").path, contents: nil); return FileHandle(forWritingAtPath: dir.appendingPathComponent("serial.log").path)! }())
  c.serialPorts = [s]
}
if args.contains("net") {
  var fds: [Int32] = [0, 0]; socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds)
  let n = VZVirtioNetworkDeviceConfiguration(); n.macAddress = VZMACAddress(string: "52:55:55:12:34:56")!; n.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: FileHandle(fileDescriptor: fds[0]))
  c.networkDevices = [n]
}
if args.contains("disk") {
  let a = try VZDiskImageStorageDeviceAttachment(url: dir.appendingPathComponent("disk"), readOnly: false)
  c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: a)]
}
do { try c.validate(); try c.validateSaveRestoreSupport() } catch { print("validate: \(error)"); exit(1) }
let vm = VZVirtualMachine(configuration: c, queue: q)
final class D: NSObject, VZVirtualMachineDelegate {
  func guestDidStop(_ vm: VZVirtualMachine) { print("delegate: guestDidStop") }
  func virtualMachine(_ vm: VZVirtualMachine, didStopWithError e: Error) { print("delegate: didStopWithError \(e)") }
}
let d = D(); vm.delegate = d
let save = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAVE"] ?? dir.appendingPathComponent("state.vzsave").path)
if restore {
  q.async {
    vm.restoreMachineStateFrom(url: save) { e in
      print("restore: \(e.map { "\($0)" } ?? "ok") state=\(vm.state.rawValue)")
      guard e == nil else { exit(1) }
      vm.resume { r in
        print("resume: \(r)")
        q.asyncAfter(deadline: .now() + 10) { print("after 10s state=\(vm.state.rawValue) (1=running)"); exit(0) }
      }
    }
  }
  dispatchMain()
}
try? FileManager.default.removeItem(at: save)
q.async {
  vm.start { r in
    print("start: \(r)")
    q.asyncAfter(deadline: .now() + 15) {
      vm.pause { r in
        print("pause: \(r)")
        vm.saveMachineStateTo(url: save) { e in
          print("save: \(e.map { e -> String in let n = e as NSError; return "\(n) underlying=\(String(describing: n.userInfo[NSUnderlyingErrorKey])) all=\(n.userInfo)" } ?? "ok"), size=\((try? FileManager.default.attributesOfItem(atPath: save.path)[.size]) ?? "-")")
          exit(0)
        }
      }
    }
  }
}
dispatchMain()
