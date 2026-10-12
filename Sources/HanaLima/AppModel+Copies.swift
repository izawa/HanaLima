import Foundation
import LimaKit

/// Copying VMs (`limactl clone` plus `InstanceCopy`), and the records that keep their lineage.
extension AppModel {
    var lineage: InstanceLineage { InstanceLineage(metadata) }

    /// Reads (and repairs) the records of VMs that no command is working on; a VM mid-copy is
    /// left to `copy`, which writes its record when done.
    func updateMetadata(_ list: [LimaInstance]) {
        let idle = list.filter { !isBusy($0.name) }
        var records = InstanceMetadata.reconcile(idle.map { ($0.name, URL(filePath: $0.dir, directoryHint: .isDirectory)) })
        for inst in list where isBusy(inst.name) {
            records[inst.name] = metadata[inst.name]
        }
        if records != metadata { metadata = records }
    }

    /// Records how HanaLima created `name` (the listing has already given it a bare record).
    func recordCreation(of name: String, template: String) {
        guard let inst = instance(named: name) else { return }
        var meta = metadata[name] ?? InstanceMetadata(instanceDir: URL(filePath: inst.dir, directoryHint: .isDirectory))
        meta.createdAt = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
        meta.template = template
        try? meta.save()
        metadata[name] = meta
    }

    func setNote(_ note: String, of name: String) {
        guard var meta = metadata[name], meta.note != note else { return }
        meta.note = note
        do {
            try meta.save()
            metadata[name] = meta
        } catch {
            alert = AlertMessage(title: String(localized: "メモを保存できませんでした"), message: error.localizedDescription)
        }
    }

    /// Why `name` can't be copied now, or nil.
    func copyBlocker(_ name: String) -> String? {
        guard let inst = instance(named: name) else { return "" }
        if inst.isRunning { return String(localized: "停止すると複製できます。") }
        if isBusy(name) { return String(localized: "処理中は複製できません。") }
        if case .missing = diskPlacement(of: inst) {
            return String(localized: "ディスクのある外付けドライブを接続すると複製できます。")
        }
        return nil
    }

    /// Copies the stopped VM `source` as `name`: an APFS clone, so it is instant and takes no
    /// space until either VM writes. A moved disk gets its own clone on the same drive.
    func copy(_ source: String, as name: String, note: String, thenStart: Bool) {
        guard let client, let src = instance(named: source), copyBlocker(source) == nil else { return }
        let sourceDir = URL(filePath: src.dir, directoryHint: .isDirectory)
        let config = (try? String(contentsOf: sourceDir.appending(path: "lima.yaml"), encoding: .utf8)) ?? ""
        let sourceRecord = metadata[source]
        let copyDir = sourceDir.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
        selection = .instance(name)
        run(.clone, on: name, client.clone(source, as: name, set: InstanceCopy.cloneExpressions(sourceConfig: config)),
            keepBusy: true) { [weak self] ok in
            guard let self, ok else { return }
            Task {
                do {
                    let record = try await InstanceCopy.finish(copyDir: copyDir, name: name, source: sourceRecord,
                                                               sourceName: source, note: note) { fraction in
                        Task { @MainActor in self.operations[name]?.fraction = fraction }
                    }
                    self.metadata[name] = record
                    self.operations[name] = nil
                } catch {
                    self.operations[name]?.isRunning = false
                    self.operations[name]?.error = error.localizedDescription
                    self.alert = AlertMessage(title: String(localized: "\(name) の複製に失敗しました"),
                                              message: error.localizedDescription)
                }
                await self.refresh()
                if self.operations[name] == nil, thenStart { self.start(name) }
            }
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
    var id: String { source }
}
