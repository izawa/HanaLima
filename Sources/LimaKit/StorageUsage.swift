import Foundation

/// A file Lima downloaded into its cache: an OS image, or an archive such as nerdctl-full.
///
/// Layout (Lima's `pkg/downloader`): `<cache>/download/by-url-sha256/<sha256(url)>/` with `url`,
/// `data`, digests, and for images `imgconv/raw` (the image converted for VZ, often larger than
/// the download itself).
public struct CachedDownload: Identifiable, Hashable, Sendable {
    public var id: String { directory.lastPathComponent }
    public var directory: URL
    public var url: String
    /// Space used on disk by the whole entry (download plus converted copy).
    public var size: Int64
    public var downloaded: Date?

    public var fileName: String {
        URL(string: url)?.lastPathComponent ?? url
    }
}

/// Where Lima keeps its data and how much space it uses.
public struct StorageReport: Sendable {
    public struct Item: Identifiable, Hashable, Sendable {
        public var id: String { url.path }
        /// Instance name, or `_disks` and the like for Lima's own directories.
        public var name: String
        public var url: URL
        public var size: Int64
    }

    /// `LIMA_HOME` (`~/.lima` unless overridden).
    public var limaHome: URL
    /// Each directory directly under `LIMA_HOME`: instances, `_disks`, `_config`, `_networks`.
    public var limaItems: [Item]
    public var cacheRoot: URL
    public var downloads: [CachedDownload]

    public var limaTotal: Int64 { limaItems.reduce(0) { $0 + $1.size } }
    public var cacheTotal: Int64 { downloads.reduce(0) { $0 + $1.size } }

    /// Measures both locations. Reads every file's allocated size, so call it off the main actor.
    public static func measure(limaHome: URL, cacheRoot: URL = DownloadMonitor.cacheRoot) -> StorageReport {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: limaHome, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        let items = children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { Item(name: $0.lastPathComponent, url: $0, size: allocatedSize(of: $0)) }
            .sorted { $0.size > $1.size }
        return StorageReport(limaHome: limaHome, limaItems: items, cacheRoot: cacheRoot,
                             downloads: cachedDownloads(cacheRoot: cacheRoot))
    }

    public static func cachedDownloads(cacheRoot: URL = DownloadMonitor.cacheRoot) -> [CachedDownload] {
        let root = cacheRoot.appending(path: "download/by-url-sha256", directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { dir -> CachedDownload? in
            guard let url = try? String(contentsOf: dir.appending(path: "url"), encoding: .utf8) else { return nil }
            let data = dir.appending(path: "data")
            let date = (try? data.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return CachedDownload(directory: dir, url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                                  size: allocatedSize(of: dir), downloaded: date)
        }
        .sorted { $0.size > $1.size }
    }

    /// Space actually used, like `du`: VM disks are sparse, so their nominal size means little.
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        func size(_ file: URL) -> Int64 {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return size(url)
        }
        var total: Int64 = 0
        for case let file as URL in enumerator { total += size(file) }
        return total
    }
}
