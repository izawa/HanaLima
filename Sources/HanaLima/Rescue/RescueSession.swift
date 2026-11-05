import Foundation
import LimaKit

/// One VM's rescue boot, shown in the rescue window: HanaLima boots the instance's disk itself
/// (`HostedVM`) with a screen and keyboard, for when Lima can't reach the guest over SSH (a
/// broken sshd, a firewall, a bad network config). Lima's VZ driver gives the guest no input
/// path (its serial port is a write-only log), so this is the only way into such a VM.
///
/// What the guest gets: the disk, `vz-efi`, `vz-identifier` and `cidata.iso` as under Lima, and
/// one NIC with Lima's MAC address behind VZ's NAT. Not: additional disks, shared folders,
/// HanaLima networks, port forwarding, the guest agent's host.
@MainActor
@Observable
final class RescueSession {
    let name: String
    let instanceDir: URL
    let cpus: Int
    let memoryBytes: UInt64
    private(set) var vm: HostedVM?
    private(set) var error: String?

    init(name: String, instanceDir: URL, cpus: Int, memoryBytes: UInt64) {
        self.name = name
        self.instanceDir = instanceDir
        self.cpus = cpus
        self.memoryBytes = memoryBytes
    }

    var state: HostedVM.State? { vm?.state }
    var isRunning: Bool { state == .starting || state == .running }

    static let serialLog = "hanalima-rescue-serial.log"

    static func options(instanceDir: URL, headless: Bool = false) -> HostedVM.Options {
        let cidata = instanceDir.appending(path: "cidata.iso")
        return .init(cidata: FileManager.default.fileExists(atPath: cidata.path) ? cidata : nil,
                     macAddress: LimaMACAddress.address(instanceDir: instanceDir),
                     serialLog: serialLog, headless: headless)
    }

    func boot() {
        guard !isRunning else { return }
        error = nil
        do {
            let vm = try HostedVM(instanceDir: instanceDir, options: Self.options(instanceDir: instanceDir),
                                  cpus: cpus, memoryBytes: memoryBytes)
            self.vm = vm
            vm.start()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop(force: Bool = false) { vm?.stop(force: force) }
}

struct RescueRequest: Identifiable, Equatable {
    let name: String
    var id: String { name }
}
