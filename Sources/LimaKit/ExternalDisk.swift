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
/// Copies use `rsync --sparse`: across volumes, `cp`, `ditto` and `mv` fill in the holes of the
/// sparse image, so a 230 MB disk with a 10 GB size would take 10 GB.
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

    /// `<folder>/HanaLima Disks/<name>/disk`
    public static func target(in folder: URL, name: String) -> URL {
        folder.appending(path: folderName, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
            .appending(path: "disk")
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
            if placement(instanceDir: instanceDir) == .local { try? fm.removeItem(at: folder) }
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
        return (try? FileManager.default.removeItem(at: folder)) != nil
    }

    /// rsync writes into `.<name>.XXXXXX` next to the destination; a stopped copy leaves it behind.
    private static func removeRsyncTemporaries(of destination: URL) {
        let folder = destination.deletingLastPathComponent()
        let prefix = "." + destination.lastPathComponent + "."
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where file.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder.appending(path: file))
        }
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

    /// `rsync --sparse`, reporting progress from the space the copy has taken so far (rsync
    /// writes a temporary file next to the destination, so the whole folder is measured).
    static func copySparse(from source: URL, to destination: URL,
                           progress: @escaping @Sendable (Double) -> Void) async throws {
        let total = Double(max(1, StorageReport.allocatedSize(of: source)))
        let folder = destination.deletingLastPathComponent()
        let base = StorageReport.allocatedSize(of: folder)
        let monitor = Task.detached {
            while !Task.isCancelled {
                progress(min(0.99, Double(StorageReport.allocatedSize(of: folder) - base) / total))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { monitor.cancel() }
        let rsync = ProcessRunner(executableURL: URL(filePath: "/usr/bin/rsync"), environment: [:])
        do {
            _ = try await rsync.run(["--sparse", source.path, destination.path])
        } catch {
            try? FileManager.default.removeItem(at: destination)
            removeRsyncTemporaries(of: destination)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw Failure(message: String(localized: "コピーに失敗しました: \(error.localizedDescription)"))
        }
        let size = { (url: URL) in (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }
        guard size(source) == size(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure(message: String(localized: "コピーしたディスクのサイズが元と一致しません。"))
        }
        progress(1)
    }
}
