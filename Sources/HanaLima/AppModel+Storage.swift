import Foundation
import LimaKit

/// Disk space used by Lima: `LIMA_HOME` (instances, disks) and the download cache.
extension AppModel {
    /// Measures in the background; the sizes come from every file's allocated size, like `du`.
    func measureStorage() async {
        guard let client, !isMeasuringStorage else { return }
        isMeasuringStorage = true
        defer { isMeasuringStorage = false }
        let home = (try? await client.limaHome())
            ?? URL(filePath: NSHomeDirectory()).appending(path: ".lima", directoryHint: .isDirectory)
        // Homebrew links each template; the real files (with _images/) sit next to the target.
        // The list loads at the end of bootstrap; the Storage view may already be open by then.
        let list = templates.isEmpty ? ((try? await client.templates()) ?? []) : templates
        let templates = list.lazy.compactMap(\.location).first?
            .resolvingSymlinksInPath().deletingLastPathComponent()
        storage = await Task.detached(priority: .utility) {
            StorageReport.measure(limaHome: home, templatesDirectory: templates)
        }.value
    }

    /// A VM being created or started may be downloading into the cache right now.
    var isAnyOperationRunning: Bool { operations.values.contains { $0.isRunning } }

    /// Deletes the images no VM uses. Lima's own `prune --keep-referred` keeps anything a template
    /// mentions, which is nearly all of them; the cache is plain files, so remove those entries.
    func deleteUnusedDownloads() async {
        guard let unused = storage?.unusedDownloads, !unused.isEmpty else { return }
        isPruningCache = true
        defer { isPruningCache = false }
        let failures = await Task.detached(priority: .utility) {
            unused.compactMap { item -> String? in
                do { try FileManager.default.removeItem(at: item.directory); return nil }
                catch { return "\(item.fileName): \(error.localizedDescription)" }
            }
        }.value
        if !failures.isEmpty {
            alert = AlertMessage(title: String(localized: "キャッシュを削除できませんでした"),
                                 message: failures.joined(separator: "\n"))
        }
        await measureStorage()
    }

    /// `limactl prune`: the whole download cache, then measures again.
    func pruneCache() async {
        guard let client else { return }
        isPruningCache = true
        defer { isPruningCache = false }
        do {
            for try await _ in client.prune(keepReferred: false) {}
        } catch {
            alert = AlertMessage(title: String(localized: "キャッシュを削除できませんでした"),
                                 message: error.localizedDescription)
        }
        await measureStorage()
    }
}
