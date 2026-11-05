import Foundation
import LimaKit

extension AppModel {
    /// Why `name` can't be rescue-booted now, or nil. The VM must be a stopped Linux VZ instance
    /// whose disk is its own and present (the rescue writes it).
    func rescueBlocker(_ name: String) -> String? {
        // A session that exists (running or not) can always be shown again.
        if rescueSession?.name == name { return nil }
        guard let inst = instance(named: name) else { return String(localized: "まだ作成中です。") }
        if !inst.usesVirtualization { return String(localized: "救出起動は VZ の仮想マシンだけで使えます。") }
        if inst.config?["os"]?.stringValue == "Darwin" { return String(localized: "macOS のゲストは救出起動できません。") }
        if inst.isRunning { return String(localized: "停止してから救出起動してください。") }
        if isBusy(name) { return String(localized: "操作中です。") }
        if pendingInstall(name) != nil { return String(localized: "OS のインストールが終わると使えます。") }
        if let owner = sharedDiskOwners[name] { return String(localized: "「\(owner)」とディスクを共有しているため起動できません。") }
        if case .missing = diskPlacement(of: inst) { return String(localized: "ディスクの保存先が見つかりません。") }
        if let session = rescueSession, session.isRunning, session.name != name {
            return String(localized: "「\(session.name)」を救出起動中です。")
        }
        return nil
    }

    /// Opens (or reuses) the rescue session for `name`; the window shows it.
    func beginRescue(_ name: String) -> RescueSession? {
        if let session = rescueSession, session.name == name { return session }
        if let blocker = rescueBlocker(name) {
            alert = AlertMessage(title: String(localized: "「\(name)」を救出起動できません"), message: blocker)
            return nil
        }
        guard let inst = instance(named: name) else { return nil }
        let session = RescueSession(name: name, instanceDir: URL(filePath: inst.dir, directoryHint: .isDirectory),
                                    cpus: inst.cpus ?? 2, memoryBytes: UInt64(inst.memory ?? 4 << 30))
        rescueSession = session
        watchHosted(session.vm, name: name) { [weak self] in self?.rescueSessionChanged() }
        return session
    }

    /// Keeps the VM's busy mark in step with the hosted boot even while no window shows it
    /// (the panel can be closed and the app relaunched while the VM runs).
    func watchHosted(_ vm: HostedProcess?, name: String, changed: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            var last: HostedProcess.State? = nil
            while true {
                let current = (rescueSession?.name == name ? rescueSession?.vm : installSession?.vm)?.state
                if current != last { last = current; changed() }
                if current == nil || current == .stopped { break }
                if case .failed = current ?? .stopped { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// While the rescue VM runs, the VM counts as busy (no start, copy, delete, disk moves).
    func rescueSessionChanged() {
        guard let session = rescueSession else { return }
        if session.isRunning {
            if operations[session.name]?.kind != .rescue { operations[session.name] = Operation(kind: .rescue) }
        } else if operations[session.name]?.kind == .rescue {
            operations[session.name] = nil
        }
    }

    /// The rescue window was closed. The VM, if running, goes on (it lives in the driver's
    /// process); the session is dropped only once it has stopped.
    func closeRescueSession() {
        guard let session = rescueSession, !session.isRunning else { return }
        rescueSession = nil
        if operations[session.name]?.kind == .rescue { operations[session.name] = nil }
    }

}
