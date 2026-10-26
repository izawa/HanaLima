import Foundation
import LimaKit
import NetworkKit

/// One VM's installer run, shown in the installer window: boots the installer ISO (or, after
/// the install, the disk) with `InstallerVM`, and ends by handing the VM back to Lima.
@MainActor
@Observable
final class InstallSession {
    enum Phase: Equatable {
        /// Booting the installer ISO.
        case installer
        /// Booting the installed OS from the disk, for the fix-up or to check it boots.
        case disk
    }

    let name: String
    let instanceDir: URL
    let iso: URL
    let cpus: Int
    let memoryBytes: UInt64
    private(set) var phase: Phase = .installer
    private(set) var vm: InstallerVM?
    private(set) var error: String?


    init(name: String, instanceDir: URL, iso: URL, cpus: Int, memoryBytes: UInt64) {
        self.name = name
        self.instanceDir = instanceDir
        self.iso = iso
        self.cpus = cpus
        self.memoryBytes = memoryBytes
    }

    var state: InstallerVM.State? { vm?.state }
    var isRunning: Bool { state == .starting || state == .running }

    /// Boots: with the ISO, or from the disk. A running VM is stopped first.
    func boot(_ phase: Phase) {
        guard !isRunning else { return }
        self.phase = phase
        error = nil
        do {
            let helper = try Self.helperISO()
            let vm = try InstallerVM(instanceDir: instanceDir, iso: phase == .installer ? iso : nil, helper: helper,
                                     cpus: cpus, memoryBytes: memoryBytes)
            self.vm = vm
            vm.start()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop(force: Bool = false) { vm?.stop(force: force) }

    /// The helper ISO (fix-up script, Lima's key, user name), rebuilt for each session: the key
    /// may change. Kept under Application Support.
    private static func helperISO() throws -> URL {
        let url = NetworkPaths.supportDirectory.appending(path: "installer/helper.iso")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InstallerFixup.makeISO(at: url, limaHome: LimaNetworks.limaHome, userName: NSUserName())
        return url
    }
}

extension AppModel {
    /// Opens (or reuses) the installer session for `name`; the window shows it.
    func beginInstall(_ name: String) -> InstallSession? {
        if let session = installSession, session.name == name { return session }
        guard installSession?.isRunning != true,
              let inst = instance(named: name), let pending = pendingInstall(name) else { return nil }
        let session = InstallSession(name: name, instanceDir: URL(filePath: inst.dir, directoryHint: .isDirectory),
                                     iso: pending.isoURL, cpus: inst.cpus ?? 2,
                                     memoryBytes: UInt64(inst.memory ?? 4 << 30))
        installSession = session
        return session
    }

    /// While the installer VM runs, the VM counts as busy (no start, copy, delete).
    func installSessionChanged() {
        guard let session = installSession else { return }
        if session.isRunning {
            if operations[session.name]?.kind != .install { operations[session.name] = Operation(kind: .install) }
        } else if operations[session.name]?.kind == .install {
            operations[session.name] = nil
        }
    }

    /// The install is done: clears the marker and starts the VM under Lima.
    func finishInstall(_ session: InstallSession) {
        guard !session.isRunning, var meta = metadata[session.name] else { return }
        meta.pendingInstall = nil
        do {
            try meta.save()
            metadata[session.name] = meta
        } catch {
            alert = AlertMessage(title: String(localized: "記録を保存できませんでした"), message: error.localizedDescription)
            return
        }
        installSession = nil
        start(session.name)
    }

    func closeInstallSession() {
        installSession?.stop(force: true)
        if let name = installSession?.name, operations[name]?.kind == .install { operations[name] = nil }
        installSession = nil
    }
}
