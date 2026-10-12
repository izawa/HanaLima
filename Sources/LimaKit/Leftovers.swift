import Foundation

/// Data HanaLima made for a VM that no longer exists — a VM deleted with `limactl delete`
/// rather than in HanaLima, which also removes these.
public struct Leftover: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `~/.lima/_hanalima-snapshots/<VM id>`: a VZ VM's snapshots.
        case snapshots(count: Int)
        /// `HanaLima Disks/<name>`: a disk moved to another drive, with its snapshots.
        case externalDisk
    }

    public var id: String { url.path }
    public var kind: Kind
    public var url: URL
    /// The VM's name when the data was made, if known.
    public var instance: String?
    public var size: Int64
    /// On another volume (doesn't use this Mac's space).
    public var isExternal: Bool { kind == .externalDisk }
}

public enum Leftovers {
    /// Looks in `limaHome` and in `diskFolders` (the places HanaLima has put disks: each holds
    /// `<name>/disk` folders). Folders on drives that aren't connected are skipped.
    public static func find(limaHome: URL, diskFolders: [URL]) -> [Leftover] {
        let fm = FileManager.default
        let instanceDirs = ((try? fm.contentsOfDirectory(at: limaHome, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix("_") && fm.fileExists(atPath: $0.appending(path: "lima.yaml").path) }
        var found: [Leftover] = []

        let ids = Set(instanceDirs.compactMap { InstanceMetadata.load(instanceDir: $0)?.id })
        let snapshotRoot = limaHome.appending(path: DiskSnapshot.localFolderName, directoryHint: .isDirectory)
        for dir in (try? fm.contentsOfDirectory(at: snapshotRoot, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: dir.lastPathComponent), !ids.contains(id) else { continue }
            let snapshots = DiskSnapshot.list(in: dir)
            found.append(Leftover(kind: .snapshots(count: snapshots.count), url: dir,
                                  instance: snapshots.lazy.compactMap(\.instance).first,
                                  size: StorageReport.allocatedSize(of: dir)))
        }

        // A disk folder is in use while any VM links into it (including a VM renamed outside
        // HanaLima), or while the VM its marker names still exists (e.g. mid-move).
        let linked = Set(instanceDirs.compactMap {
            ExternalDisk.placement(instanceDir: $0).externalURL?.deletingLastPathComponent().standardizedFileURL.path
        })
        var seen = Set<String>()
        for base in diskFolders where seen.insert(base.standardizedFileURL.path).inserted {
            for folder in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                let disk = folder.appending(path: "disk")
                guard let owner = ExternalDisk.markedOwner(of: disk),
                      !linked.contains(folder.standardizedFileURL.path),
                      !fm.fileExists(atPath: owner.appending(path: "lima.yaml").path) else { continue }
                found.append(Leftover(kind: .externalDisk, url: folder, instance: owner.lastPathComponent,
                                      size: StorageReport.allocatedSize(of: folder)))
            }
        }
        return found.sorted { $0.size > $1.size }
    }

    /// Deletes a leftover, then tidies up the folder that held it if that is now empty.
    public static func remove(_ leftover: Leftover) throws {
        try FileManager.default.removeItem(at: leftover.url)
        let parent = leftover.url.deletingLastPathComponent()
        let tidy = switch leftover.kind {
        case .snapshots: parent.lastPathComponent == DiskSnapshot.localFolderName
        case .externalDisk: ExternalDisk.isDisksFolder(parent)
        }
        if tidy, (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.allSatisfy({ $0 == ".DS_Store" }) == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}
