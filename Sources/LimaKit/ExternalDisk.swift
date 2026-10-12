import Foundation

/// Where an instance's main disk lives.
public enum DiskPlacement: Equatable, Sendable {
    /// `~/.lima/<name>/disk` is the file itself.
    case local
    /// `disk` is a symbolic link to a file elsewhere (e.g. an external drive), which is there.
    case external(URL)
    /// `disk` is a link whose target can't be found: the drive is probably not connected.
    case missing(URL)

    /// The external file, whether or not it's reachable.
    public var externalURL: URL? {
        switch self {
        case .local: nil
        case .external(let url), .missing(let url): url
        }
    }
}

/// Moves an instance's disk to another volume and back.
///
/// Lima keeps everything in `~/.lima/<name>`, and listing only counts real directories there, so
/// the folder must stay. The disk image is the only large file; it moves out and a symbolic link
/// takes its place. Lima follows the link for start, edit (including resizing) and QEMU
/// snapshots; `limactl delete` removes only the link (see docs/05).
///
/// Copies keep the image sparse (see `copySparse`): across volumes, `cp`, `ditto` and `mv` fill
/// in the holes, so a 230 MB disk with a 10 GB size would take 10 GB.
public enum ExternalDisk {
    public static let folderName = "HanaLima Disks"
    static let markerName = "hanalima.json"
    static let partialName = "disk.partial"

    public static func diskURL(instanceDir: URL) -> URL { instanceDir.appending(path: "disk") }

    public static func placement(instanceDir: URL) -> DiskPlacement {
        let disk = diskURL(instanceDir: instanceDir)
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: disk.path) else {
            return .local
        }
        let url = URL(filePath: destination, relativeTo: instanceDir).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? .external(url) : .missing(url)
    }

    /// `<folder>/HanaLima Disks/<name>/disk`, or `<folder>/<name>/disk` when the chosen folder is
    /// already such a folder ("HanaLima Disks", "HanaLimaDisks", "hanalima-disks"…).
    public static func target(in folder: URL, name: String) -> URL {
        let base = isDisksFolder(folder) ? folder : folder.appending(path: folderName, directoryHint: .isDirectory)
        return base.appending(path: name, directoryHint: .isDirectory).appending(path: "disk")
    }

    static func isDisksFolder(_ folder: URL) -> Bool {
        let letters = folder.lastPathComponent.lowercased().filter { $0.isLetter }
        return letters == "hanalimadisks"
    }

    // MARK: Checking a destination

    public struct DestinationCheck: Sendable, Equatable {
        public enum Problem: Sendable, Equatable {
            /// Same volume as the instance: moving frees nothing.
            case sameVolume
            /// Not APFS: a sparse image would take its full size (exFAT and the like).
            case notAPFS(String)
            case notEnoughSpace
            /// `HanaLima Disks/<name>` already exists there.
            case alreadyExists
            case notWritable
        }

        public var target: URL
        public var volumeName: String
        public var fileSystem: String
        public var available: Int64
        public var required: Int64
        public var problems: [Problem]

        public var isOK: Bool { problems.isEmpty }
    }

    /// Checks `folder` as a destination for an instance's disk. `required` is the space the copy
    /// needs (the disk's allocated size); pass 0 before the disk exists (at creation).
    public static func check(folder: URL, instanceDir: URL, name: String, required: Int64) -> DestinationCheck {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTypeNameKey, .volumeIdentifierKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
                                         .volumeIsReadOnlyKey]
        let volume = try? folder.resourceValues(forKeys: keys)
        let home = try? instanceDir.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey])
        let target = target(in: folder, name: name)
        let fileSystem = volume?.volumeTypeName ?? ""
        let available = availableSpace(volume)
        var problems: [DestinationCheck.Problem] = []
        if let a = volume?.volumeIdentifier as? NSObject, let b = home?.volumeIdentifier as? NSObject, a.isEqual(b) {
            problems.append(.sameVolume)
        }
        if fileSystem.lowercased() != "apfs" { problems.append(.notAPFS(fileSystem)) }
        if volume?.volumeIsReadOnly == true || !FileManager.default.isWritableFile(atPath: folder.path) {
            problems.append(.notWritable)
        }
        // A little headroom: the disk keeps growing as the VM writes.
        if available < required + 1 << 30 { problems.append(.notEnoughSpace) }
        if FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) { problems.append(.alreadyExists) }
        return DestinationCheck(target: target, volumeName: volume?.volumeName ?? folder.lastPathComponent,
                                fileSystem: fileSystem, available: available, required: required, problems: problems)
    }

    /// "Important usage" capacity is what the Finder offers, but volumes other than the startup
    /// disk (external drives, disk images) may not report it; fall back to the plain capacity.
    public static func availableSpace(_ volume: URLResourceValues?) -> Int64 {
        if let important = volume?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(volume?.volumeAvailableCapacity ?? 0)
    }

    // MARK: Moving

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Copies the disk to `target`, then swaps the original for a link in one rename. On failure
    /// or cancellation the original stays as it was and the partial copy is removed.
    public static func moveOut(instanceDir: URL, name: String, to target: URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let disk = diskURL(instanceDir: instanceDir)
        guard placement(instanceDir: instanceDir) == .local, fm.fileExists(atPath: disk.path) else {
            throw Failure(message: String(localized: "移動できるディスクがありません。"))
        }
        let folder = target.deletingLastPathComponent()
        guard !fm.fileExists(atPath: folder.path) else {
            throw Failure(message: String(localized: "移動先に「\(folder.path)」が既にあります。"))
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try writeMarker(in: folder, name: name, instanceDir: instanceDir)
            let partial = folder.appending(path: partialName)
            try await copySparse(from: disk, to: partial, progress: progress)
            try fm.moveItem(at: partial, to: target)
            // Swap the file for the link atomically: no moment without a disk at the path.
            let link = instanceDir.appending(path: "disk.hanalima-link")
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
            guard rename(link.path, disk.path) == 0 else {
                try? fm.removeItem(at: link)
                throw Failure(message: String(localized: "ディスクをリンクに置き換えられませんでした: \(String(cString: strerror(errno)))"))
            }
        } catch {
            if placement(instanceDir: instanceDir) == .local, !removeExternalFolder(of: target) {
                try? fm.removeItem(at: folder)
            }
            throw error
        }
    }

    /// Copies the external disk back into the instance folder, replaces the link with it, then
    /// removes the external folder. The external copy stays until the local one is in place.
    public static func moveBack(instanceDir: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        guard case .external(let source) = placement(instanceDir: instanceDir) else {
            throw Failure(message: String(localized: "外部のディスクが見つかりません。"))
        }
        let partial = instanceDir.appending(path: partialName)
        do {
            try await copySparse(from: source, to: partial, progress: progress)
            guard rename(partial.path, diskURL(instanceDir: instanceDir).path) == 0 else {
                throw Failure(message: String(localized: "ディスクを戻せませんでした: \(String(cString: strerror(errno)))"))
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        removeExternalFolder(of: source)
    }

    /// Deletes `HanaLima Disks/<name>` holding `disk`, but only a folder HanaLima created.
    @discardableResult
    public static func removeExternalFolder(of disk: URL) -> Bool {
        let folder = disk.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.appending(path: markerName).path) else { return false }
        guard (try? FileManager.default.removeItem(at: folder)) != nil else { return false }
        // Tidy up the "HanaLima Disks" folder HanaLima made, once nothing is left in it.
        let parent = folder.deletingLastPathComponent()
        if isDisksFolder(parent),
           let rest = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
           rest.allSatisfy({ $0 == ".DS_Store" }) {
            try? FileManager.default.removeItem(at: parent)
        }
        return true
    }

    private static func writeMarker(in folder: URL, name: String, instanceDir: URL) throws {
        let info: [String: String] = [
            "instance": name,
            "instanceDir": instanceDir.path,
            "movedAt": ISO8601DateFormatter().string(from: .now),
            "note": "Disk of the Lima instance above, moved here by HanaLima. ~/.lima/\(name)/disk links to it.",
        ]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appending(path: markerName))
    }

    /// Copies only the data extents (`copyfile` with `COPYFILE_DATA_SPARSE`, which walks the file
    /// with SEEK_DATA/SEEK_HOLE), so the copy takes exactly the space the original does.
    /// `rsync --sparse` checks whole blocks for zeros and wrote a VM disk back almost twice as
    /// large; `cp`, `ditto` and `mv` across volumes fill every hole. Progress comes from the space
    /// the copy has taken so far.
    static func copySparse(from source: URL, to destination: URL,
                           progress: @escaping @Sendable (Double) -> Void) async throws {
        let total = Double(max(1, StorageReport.allocatedSize(of: source)))
        let monitor = Task.detached {
            while !Task.isCancelled {
                progress(min(0.99, Double(StorageReport.allocatedSize(of: destination)) / total))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { monitor.cancel() }
        let control = CopyControl()
        let status: Int32 = await withTaskCancellationHandler {
            await Task.detached { control.copy(source.path, destination.path) }.value
        } onCancel: {
            control.cancel()
        }
        if control.isCancelled || Task.isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        guard status == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: destination)
            throw Failure(message: String(localized: "コピーに失敗しました: \(reason)"))
        }
        // stat, not URL resource values: those are cached per URL and would miss the truncate.
        let size = { (url: URL) -> Int in
            var info = stat()
            return stat(url.path, &info) == 0 ? Int(info.st_size) : -1
        }
        // copyfile stops at the last data extent, so a trailing hole is missing: extend the copy
        // to the original length (the extension is a hole and takes no space).
        if size(destination) >= 0, size(destination) < size(source) {
            _ = truncate(destination.path, off_t(size(source)))
        }
        guard size(source) == size(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure(message: String(localized: "コピーしたディスクのサイズが元と一致しません。"))
        }
        progress(1)
    }
}

/// Lets a cancellation stop `copyfile` between chunks (its status callback answers QUIT).
final class CopyControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    func copy(_ source: String, _ destination: String) -> Int32 {
        guard let state = copyfile_state_alloc() else { return -1 }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { _, _, _, _, _, context in
            guard let context else { return COPYFILE_CONTINUE }
            return Unmanaged<CopyControl>.fromOpaque(context).takeUnretainedValue().isCancelled
                ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())
        return copyfile(source, destination, state, copyfile_flags_t(COPYFILE_DATA | COPYFILE_DATA_SPARSE))
    }
}
