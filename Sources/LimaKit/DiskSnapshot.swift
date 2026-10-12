import Foundation

/// A saved state of a VZ instance's disk, made by HanaLima (Lima 2.2's VZ driver has no
/// snapshots).
///
/// A snapshot is an APFS clone of `disk` (and of `vz-efi`, the EFI variable store) in a folder
/// next to the disk: instant, and it takes space only as the disk changes afterwards. Restoring
/// clones it back over the disk. Clones work only within a volume, so the folder is on the
/// disk's volume: `~/.lima/_hanalima-snapshots/<VM id>/<id>/` (keyed by the id in
/// `InstanceMetadata`, so it follows a rename), or `HanaLima Disks/<name>/snapshots/<id>/` for a
/// disk moved to another drive. Not inside the instance folder: `limactl clone` fails on
/// subfolders there ("permission denied"), and Lima skips `_` folders in `~/.lima`. Only the
/// boot disk and EFI variables are saved; settings (CPUs, memory…) and additional disks are not.
public struct DiskSnapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// The VM's name when the snapshot was made (shown if the VM is deleted outside HanaLima).
    public var instance: String?

    public init(id: UUID = UUID(), name: String, createdAt: Date = .now, instance: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt.wholeSeconds
        self.instance = instance
    }

    static let localFolderName = "_hanalima-snapshots"
    static let externalFolderName = "snapshots"
    static let infoName = "snapshot.json"
    static let efiName = "vz-efi"

    /// Where `instanceDir`'s snapshots are kept; nil while a moved disk's drive is away, or (for
    /// a local disk) when the VM has no record yet and `createRecord` is false.
    public static func folder(instanceDir: URL, createRecord: Bool = false) -> URL? {
        switch ExternalDisk.placement(instanceDir: instanceDir) {
        case .local:
            var record = InstanceMetadata.load(instanceDir: instanceDir)
            if record == nil, createRecord {
                record = InstanceMetadata(instanceDir: instanceDir, createdAt: nil)
                try? record?.save()
            }
            return record.map { localFolder(limaHome: instanceDir.deletingLastPathComponent(), id: $0.id) }
        case .external(let disk):
            return disk.deletingLastPathComponent().appending(path: externalFolderName, directoryHint: .isDirectory)
        case .missing:
            return nil
        }
    }

    static func localFolder(limaHome: URL, id: UUID) -> URL {
        limaHome.appending(path: localFolderName, directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    public static func list(instanceDir: URL) -> [DiskSnapshot] {
        guard let folder = folder(instanceDir: instanceDir) else { return [] }
        return list(in: folder)
    }

    static func list(in folder: URL) -> [DiskSnapshot] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appending(path: infoName)) else { return nil }
            return try? decoder.decode(DiskSnapshot.self, from: data)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    /// Saves the current disk. The instance must be stopped.
    public static func create(instanceDir: URL, name: String) throws -> DiskSnapshot {
        guard let folder = folder(instanceDir: instanceDir, createRecord: true) else { throw failure(String(localized: "ディスクが見つかりません。")) }
        let snapshot = DiskSnapshot(name: name, instance: instanceDir.lastPathComponent)
        let dir = folder.appending(path: snapshot.id.uuidString, directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try cloneFile(ExternalDisk.diskURL(instanceDir: instanceDir).resolvingSymlinksInPath(), to: dir.appending(path: "disk"))
            let efi = instanceDir.appending(path: efiName)
            if fm.fileExists(atPath: efi.path) { try fm.copyItem(at: efi, to: dir.appending(path: efiName)) }
            try encoder.encode(snapshot).write(to: dir.appending(path: infoName))
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        return snapshot
    }

    /// Puts `snapshot` of `sourceDir` in place of `targetDir`'s disk (the same instance, or a
    /// copy of it made with `limactl clone`). The target must be stopped. The snapshot stays.
    public static func restore(_ snapshot: DiskSnapshot, of sourceDir: URL, into targetDir: URL) throws {
        guard let folder = folder(instanceDir: sourceDir) else { throw failure(String(localized: "ディスクが見つかりません。")) }
        let dir = folder.appending(path: snapshot.id.uuidString, directoryHint: .isDirectory)
        let disk = ExternalDisk.diskURL(instanceDir: targetDir).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: disk.path) else { throw failure(String(localized: "ディスクが見つかりません。")) }
        // The disk may have been enlarged since: keep the larger length (the extension is a hole;
        // the guest grows its partition at boot, as after a resize).
        let currentLength = length(disk)
        let restoring = disk.deletingLastPathComponent().appending(path: "disk.hanalima-restoring")
        try? FileManager.default.removeItem(at: restoring)
        try cloneFile(dir.appending(path: "disk"), to: restoring)
        if length(restoring) < currentLength { _ = truncate(restoring.path, off_t(currentLength)) }
        try replace(disk, with: restoring)
        let efi = dir.appending(path: efiName)
        if FileManager.default.fileExists(atPath: efi.path) {
            let target = targetDir.appending(path: efiName)
            let temp = targetDir.appending(path: "vz-efi.hanalima-restoring")
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: efi, to: temp)
            try replace(target, with: temp)
        }
    }

    public static func delete(_ snapshot: DiskSnapshot, instanceDir: URL) throws {
        guard let folder = folder(instanceDir: instanceDir) else { throw failure(String(localized: "ディスクが見つかりません。")) }
        try FileManager.default.removeItem(at: folder.appending(path: snapshot.id.uuidString, directoryHint: .isDirectory))
        removeIfEmpty(folder)
        let parent = folder.deletingLastPathComponent()
        if parent.lastPathComponent == localFolderName { removeIfEmpty(parent) }
    }

    /// After deleting a VM whose disk was local: its snapshots (`limactl delete` doesn't know
    /// them). A moved disk's snapshots go with its external folder.
    public static func removeLocalSnapshots(limaHome: URL, id: UUID) {
        try? FileManager.default.removeItem(at: localFolder(limaHome: limaHome, id: id))
        removeIfEmpty(limaHome.appending(path: localFolderName, directoryHint: .isDirectory))
    }

    private static func removeIfEmpty(_ folder: URL) {
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.allSatisfy({ $0 == ".DS_Store" }) == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// "2026-10-12 11:35" as a default name.
    public static func suggestedName(_ date: Date = .now) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    // MARK: -

    /// An APFS clone: only within a volume, and only on APFS (a byte copy would defeat the point).
    static func cloneFile(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            let reason = String(cString: strerror(errno))
            throw failure(String(localized: "APFS のクローンを作れませんでした（\(reason)）。ディスクのあるボリュームが APFS でない可能性があります。"))
        }
    }

    private static func replace(_ target: URL, with replacement: URL) throws {
        guard rename(replacement.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: replacement)
            throw failure(String(localized: "ファイルを置き換えられませんでした: \(reason)"))
        }
    }

    private static func length(_ url: URL) -> Int {
        var info = stat()
        return stat(url.path, &info) == 0 ? Int(info.st_size) : 0
    }

    private static func failure(_ message: String) -> ExternalDisk.Failure { ExternalDisk.Failure(message: message) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
