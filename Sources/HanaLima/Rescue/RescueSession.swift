import Foundation
import LimaKit

/// One VM's rescue boot, shown in the rescue window: HanaLima's driver boots the instance's
/// disk outside Lima (`HostedProcess`) with a screen and keyboard, for when Lima can't reach
/// the guest over SSH (a broken sshd, a firewall, a bad network config). Lima's VZ driver gives
/// the guest no input path (its serial port is a write-only log), so this is one of the two
/// ways into such a VM (the other is the serial console of a VM on HanaLima's driver).
///
/// What the guest gets: the disk, `vz-efi`, `vz-identifier` and `cidata.iso` as under Lima, and
/// NIC 0 on Lima's user-mode network with Lima's MAC address (so DNS and the internet work as
/// under Lima). Not: additional disks, shared folders, HanaLima networks, port forwarding, the
/// guest agent's host.
@MainActor
@Observable
final class RescueSession {
    let name: String
    let instanceDir: URL
    let cpus: Int
    let memoryBytes: UInt64
    private(set) var vm: HostedProcess?
    private(set) var error: String?

    init(name: String, instanceDir: URL, cpus: Int, memoryBytes: UInt64, attached: HostedProcess? = nil) {
        self.name = name
        self.instanceDir = instanceDir
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        vm = attached
    }

    var state: HostedProcess.State? { vm?.state }
    var isRunning: Bool { state == .starting || state == .running }

    static let serialLog = "hanalima-rescue-serial.log"

    func boot() {
        guard !isRunning else { return }
        error = nil
        do {
            vm = try HostedProcess.start(instanceDir: instanceDir, options: .init(cidata: true, serialLog: Self.serialLog),
                                         cpus: cpus, memoryBytes: memoryBytes)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop(force: Bool = false) { vm?.stop(force: force) }
    func openScreen() { vm?.openScreen() }
}

struct RescueRequest: Identifiable, Equatable {
    let name: String
    var id: String { name }
}
