import Foundation
import LimaKit

/// Which OS a VM's guest runs (docs/20): read when the VM becomes ready, or on request, and
/// kept in its record with the time.
extension AppModel {
    /// Reads the guest's OS and records it. Silent: a failure keeps the last value. Not while
    /// paused (the guest wouldn't answer) or renaming. A request that comes while a read runs
    /// (a ready signal during a check started at launch, say) is run once more if that read fails.
    func observeOS(_ name: String) async {
        guard !observingOS.contains(name) else {
            osCheckAgain.insert(name)
            return
        }
        observingOS.insert(name)
        let saved = await readOS(name)
        observingOS.remove(name)
        if osCheckAgain.remove(name) != nil, !saved, isReady(name) { await observeOS(name) }
    }

    /// One read; true when it was saved.
    private func readOS(_ name: String) async -> Bool {
        // A watch event can come before the listing shows the VM running.
        if instance(named: name)?.isRunning != true { await refresh() }
        guard !isRenaming(name), !isPaused(name), let inst = instance(named: name), inst.isRunning else { return false }
        let id = metadata[name]?.id
        // Right after launch the app doesn't know yet whether the driver has the guest paused;
        // without an answer, don't risk a read that hangs.
        if inst.usesHanaLimaDriver {
            let dir = inst.instanceDir
            guard await Task.detached(operation: { Self.driverPaused(instanceDir: dir) }).value == false else { return false }
        }
        let result = await runGuestScript(name, script: GuestOS.script, timeout: .seconds(15),
                                          keepBytes: 16 * 1024, holdsVM: false)
        guard result.exit == 0,
              let os = GuestOS.name(fromStdout: result.output.components(separatedBy: "\n")) else { return false }
        // The record of now (a note or group may have changed meanwhile), by id: renamed
        // meanwhile, it has another name; deleted, another VM may have its name.
        let current = id.map { id in metadata.first { $0.value.id == id }?.key } ?? name
        guard let current, !isRenaming(current), var meta = metadata[current] else { return false }
        meta.lastObservedOS = .init(name: os)
        do { try meta.save() } catch { return false }
        metadata[current] = meta
        if readyInstances.contains(current) { osTriedSinceReady.insert(current) }
        return true
    }

    /// After a snapshot is restored: the guest's OS is whatever the old disk has.
    func forgetObservedOS(_ name: String) {
        guard var meta = metadata[name], meta.lastObservedOS != nil else { return }
        meta.lastObservedOS = nil
        guard (try? meta.save()) != nil else { return }
        metadata[name] = meta
    }
}
