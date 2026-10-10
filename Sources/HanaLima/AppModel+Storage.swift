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
        storage = await Task.detached(priority: .utility) { StorageReport.measure(limaHome: home) }.value
    }

    /// A VM being created or started may be downloading into the cache right now.
    var isAnyOperationRunning: Bool { operations.values.contains { $0.isRunning } }

    /// `limactl prune`, then measures again.
    func pruneCache(keepReferred: Bool) async {
        guard let client else { return }
        isPruningCache = true
        defer { isPruningCache = false }
        do {
            for try await _ in client.prune(keepReferred: keepReferred) {}
        } catch {
            alert = AlertMessage(title: String(localized: "キャッシュを削除できませんでした"),
                                 message: error.localizedDescription)
        }
        await measureStorage()
    }
}
