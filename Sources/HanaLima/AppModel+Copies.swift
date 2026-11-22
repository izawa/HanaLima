import Foundation
import LimaKit

/// Copying VMs (`limactl clone` plus `InstanceCopy`), and the records that keep their lineage.
extension AppModel {
    var lineage: InstanceLineage { InstanceLineage(metadata) }

    /// Reads (and repairs) the records of VMs that no command is working on; a VM mid-copy is
    /// left to `copy`, which writes its record when done. Busy VMs are still passed in, read
    /// only: one being started holds its id against a CLI clone made meanwhile.
    func updateMetadata(_ list: [LimaInstance]) {
        let busy = Set(list.map(\.name).filter { isBusy($0) })
        var records = InstanceMetadata.reconcile(list.map { ($0.name, URL(filePath: $0.dir, directoryHint: .isDirectory)) },
                                                 busy: busy)
        for inst in list where isBusy(inst.name) {
            records[inst.name] = metadata[inst.name]
        }
        if records != metadata { metadata = records }
    }

    /// Records how HanaLima created `name` (the listing has already given it a bare record).
    func recordCreation(of name: String, template: String, pendingISO: URL? = nil, pendingIsolation: Bool = false) {
        guard let inst = instance(named: name) else { return }
        var meta = metadata[name] ?? InstanceMetadata(instanceDir: URL(filePath: inst.dir, directoryHint: .isDirectory))
        meta.createdAt = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
        meta.template = template
        meta.pendingInstall = pendingISO.map { InstanceMetadata.PendingInstall(iso: $0) }
        meta.pendingIsolation = pendingIsolation ? true : nil
        if let group = pendingGroups.removeValue(forKey: name) { meta.group = group }
        try? meta.save()
        metadata[name] = meta
    }

    func setNote(_ note: String, of name: String) {
        guard var meta = metadata[name], meta.note != note, !isRenaming(name) else { return }
        meta.note = note
        do {
            try meta.save()
            metadata[name] = meta
        } catch {
            alert = AlertMessage(title: String(localized: "メモを保存できませんでした"), message: error.localizedDescription)
        }
    }

    /// Why `name` can't be copied now (the person's words), or nil.
    func copyBlocker(_ name: String) -> String? { copyBlock(name)?.text }

    enum CopyBlock {
        case missing, running, busy, installing, hibernated, diskMissing
        var text: String {
            switch self {
            case .missing: ""
            case .running: String(localized: "停止すると複製できます。")
            case .busy: String(localized: "処理中は複製できません。")
            case .installing: String(localized: "OS のインストールが終わると複製できます。")
            case .hibernated: String(localized: "休止中は複製できません。起動して再開するか、保存した状態を捨ててください。")
            case .diskMissing: String(localized: "ディスクのある外付けドライブを接続すると複製できます。")
            }
        }
        /// For MCP, in English.
        var reason: String {
            switch self {
            case .missing: "not found"
            case .running: "stop the VM first"
            case .busy: "busy with another operation"
            case .installing: "its OS install isn't finished"
            case .hibernated: "hibernated; start it or discard the saved state first"
            case .diskMissing: "the external drive with its disk isn't connected"
            }
        }
    }

    func copyBlock(_ name: String) -> CopyBlock? {
        guard let inst = instance(named: name) else { return .missing }
        if inst.isRunning { return .running }
        if isBusy(name) { return .busy }
        if pendingInstall(name) != nil { return .installing }
        if isHibernated(name) { return .hibernated }
        if case .missing = diskPlacement(of: inst) { return .diskMissing }
        return nil
    }

    /// Copies the stopped VM `source` as `name`: an APFS clone, so it is instant and takes no
    /// space until either VM writes. A moved disk gets its own clone on the same drive.
    func copy(_ source: String, as name: String, note: String, thenStart: Bool, snapshot: SnapshotRef? = nil) {
        guard copyBlocker(source) == nil else { return }
        selection = .instance(name)
        Task {
            do {
                _ = try await copyNow(source, as: name, note: note, snapshot: snapshot)
                if thenStart { start(name) }
            } catch {
                alert = AlertMessage(title: String(localized: "\(name) の複製に失敗しました"), message: error.localizedDescription)
            }
        }
    }

    struct CopyFailure: LocalizedError {
        var errorDescription: String?
    }

    /// `copy`, waited for: the copy's record. The copy stays busy until it is finished, so
    /// nothing starts it or reads its record halfway. A failure leaves what was made in place
    /// (the operation shows the error), as the app always has.
    func copyNow(_ source: String, as name: String, note: String, snapshot: SnapshotRef? = nil) async throws -> InstanceMetadata {
        guard let client, let src = instance(named: source) else { throw CopyFailure(errorDescription: CopyBlock.missing.reason) }
        if let block = copyBlock(source) { throw CopyFailure(errorDescription: block.text) }
        let sourceDir = URL(filePath: src.dir, directoryHint: .isDirectory)
        let config = (try? String(contentsOf: sourceDir.appending(path: "lima.yaml"), encoding: .utf8)) ?? ""
        let sourceRecord = metadata[source]
        let copyDir = sourceDir.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
        // Another operation on the name: leave its state alone.
        guard !isBusy(name) else { throw CopyFailure(errorDescription: CopyBlock.busy.text) }
        pendingGroups[name] = sourceRecord?.group  // shown in the source's group while it copies
        if let error = await perform(.clone, on: name, client.clone(source, as: name, set: InstanceCopy.cloneExpressions(sourceConfig: config)),
                                     keepBusy: true) {
            pendingGroups[name] = nil
            throw CopyFailure(errorDescription: error)
        }
        do {
            var record = try await InstanceCopy.finish(copyDir: copyDir, name: name, source: sourceRecord,
                                                       sourceName: source, snapshot: snapshot?.label,
                                                       note: note) { fraction in
                Task { @MainActor in self.operations[name]?.fraction = fraction }
            }
            // The source's group as it is now: it may have moved while the disk was copied.
            if let group = metadata[source]?.group {
                record.group = group
                try record.save()
            }
            metadata[name] = record
            switch snapshot {
            case .disk(let s):
                try DiskSnapshot.restore(s, of: sourceDir, into: copyDir)
            case .lima(let tag):
                for try await entry in client.applySnapshot(name, tag: tag) { _ = entry }
            case nil:
                break
            }
            operations[name] = nil
            pendingGroups[name] = nil  // before the refresh, which lays out the groups from the record
            await refresh()
            return record
        } catch {
            operations[name]?.isRunning = false
            operations[name]?.error = error.localizedDescription
            pendingGroups[name] = nil
            await refresh()
            throw error
        }
    }

    /// "<source>-copy", then "-copy-2"… not taken by any VM.
    func suggestedCopyName(of source: String) -> String {
        let taken = Set(sidebarNames)
        let base = "\(source)-copy"
        if !taken.contains(base) { return base }
        var i = 2
        while taken.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }
}

struct CopyRequest: Identifiable, Equatable {
    let source: String
    /// Copy the VM as it was in this snapshot instead of as it is now.
    var snapshot: SnapshotRef? = nil
    var id: String { source + (snapshot?.label ?? "") }
}

/// A snapshot of either kind: HanaLima's (VZ) or Lima's (QEMU).
enum SnapshotRef: Equatable {
    case disk(DiskSnapshot)
    case lima(tag: String)

    var label: String {
        switch self {
        case .disk(let s): s.name
        case .lima(let tag): tag
        }
    }
}

/// VZ snapshots (HanaLima's own; QEMU ones are Lima's, see the snapshot tab).
extension AppModel {
    func loadDiskSnapshots(_ name: String) {
        guard let inst = instance(named: name) else { return }
        let list = DiskSnapshot.list(instanceDir: URL(filePath: inst.dir, directoryHint: .isDirectory))
        if diskSnapshots[name] != list { diskSnapshots[name] = list }
    }

    /// Whether a VZ VM has snapshots: they sit next to the disk, so its disk can't move then.
    func hasDiskSnapshots(_ instance: LimaInstance) -> Bool {
        !DiskSnapshot.list(instanceDir: URL(filePath: instance.dir, directoryHint: .isDirectory)).isEmpty
    }

    private func diskSnapshotOperation(_ kind: Operation.Kind, _ name: String,
                                       _ work: @escaping @Sendable (URL) throws -> Void) {
        Task {
            if let error = await performDiskSnapshot(kind, name, work) {
                alert = AlertMessage(title: String(localized: "\(name) の\(kind.label)に失敗しました"), message: error)
            }
        }
    }

    /// A VZ snapshot operation on a stopped VM; returns the error, or nil.
    func performDiskSnapshot(_ kind: Operation.Kind, _ name: String,
                             _ work: @escaping @Sendable (URL) throws -> Void) async -> String? {
        guard let inst = instance(named: name), !inst.isRunning, !isBusy(name), !isHibernated(name) else {
            return String(localized: "停止していて、ほかの処理をしていない仮想マシンだけです。")
        }
        // A copy that still shares its disk would snapshot or roll back the owner's disk too.
        if let owner = sharedDiskOwners[name] {
            return String(localized: "「\(owner)」とディスクを共有しています。先にディスクを独立させてください。")
        }
        let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)
        operations[name] = Operation(kind: kind)
        let failure = await Task.detached { () -> String? in
            do { try work(dir); return nil } catch { return error.localizedDescription }
        }.value
        if let failure {
            operations[name]?.error = failure
            operations[name]?.isRunning = false
        } else {
            operations[name] = nil
        }
        loadDiskSnapshots(name)
        await refresh()
        return failure
    }

    func createDiskSnapshot(_ name: String, title: String) {
        diskSnapshotOperation(.snapshotCreate, name) { dir in _ = try DiskSnapshot.create(instanceDir: dir, name: title) }
    }

    func restoreDiskSnapshot(_ name: String, _ snapshot: DiskSnapshot) {
        diskSnapshotOperation(.snapshotApply, name) { dir in try DiskSnapshot.restore(snapshot, of: dir, into: dir) }
    }

    func deleteDiskSnapshot(_ name: String, _ snapshot: DiskSnapshot) {
        diskSnapshotOperation(.snapshotDelete, name) { dir in try DiskSnapshot.delete(snapshot, instanceDir: dir) }
    }
}
