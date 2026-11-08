import Foundation

/// A hibernated VM's saved state (docs/11, stage 2): the RAM and devices of a hanalima VM,
/// written by VZ's `saveMachineStateTo`, in the instance directory next to a record of what the
/// VM looked like when it was saved. The driver restores it at the next Start instead of
/// booting, and only if the record still matches: memory saved against a disk that has since
/// changed (a snapshot restored, a resize, another boot) would corrupt the file systems.
///
/// The files live in the instance directory so `limactl delete` removes them. `limactl clone`
/// copies them, and `limactl rename` moves them; both give the VM a new `vz-identifier` (and a
/// rename a new MAC), so the driver discards the state there instead of restoring it.
public enum SavedState {
    public static let stateName = "hanalima-state.vzsave"
    public static let recordName = "hanalima-state.json"
    /// The state while the driver restores it (renamed back if the restore fails).
    public static let restoringName = "hanalima-state.vzsave.restoring"
    /// The state while the driver writes it.
    public static let partialName = "hanalima-state.vzsave.partial"

    /// What has to be the same at the restore as at the save.
    public struct Record: Codable, Equatable, Sendable {
        /// `vz-identifier`'s bytes, base64: a clone gets a new one.
        public var machineIdentifier: String
        /// The VM's configuration as far as VZ sees it (CPUs, memory, devices).
        public var configuration: String
        /// NIC 0's MAC. Lima derives it from the instance directory, so `limactl rename` changes
        /// it, and VZ restores only into the same configuration.
        public var macAddress: String?
        /// `disk`, `vz-efi` and the additional disks, as found after the save.
        public var files: [FileStamp]
        public var savedAt: Date
        /// Bytes of the state file.
        public var size: Int64

        public init(machineIdentifier: String, configuration: String, macAddress: String?, files: [FileStamp], savedAt: Date, size: Int64) {
            self.machineIdentifier = machineIdentifier
            self.configuration = configuration
            self.macAddress = macAddress
            self.files = files
            self.savedAt = savedAt
            self.size = size
        }
    }

    /// A file by inode, size and modification time (following a symbolic link, such as a disk
    /// moved to another drive). A replaced file (a snapshot restored by rename) gets a new inode.
    public struct FileStamp: Codable, Equatable, Sendable {
        /// Relative to the instance directory for a file in it (`disk`, `vz-efi`): a rename moves
        /// the directory. Absolute otherwise (an additional disk).
        public var path: String
        public var inode: UInt64
        public var size: Int64
        public var modified: Double

        public init?(url: URL, instanceDir: URL) {
            var st = stat()
            guard stat(url.path, &st) == 0 else { return nil }
            let prefix = instanceDir.standardizedFileURL.path.hasSuffix("/")
                ? instanceDir.standardizedFileURL.path : instanceDir.standardizedFileURL.path + "/"
            let full = url.standardizedFileURL.path
            path = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
            inode = UInt64(st.st_ino)
            size = Int64(st.st_size)
            modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        }
    }

    public static func stateURL(instanceDir: URL) -> URL { instanceDir.appending(path: stateName) }
    public static func recordURL(instanceDir: URL) -> URL { instanceDir.appending(path: recordName) }

    /// Whether the VM is hibernated: a state file and its record are there. A state left mid-
    /// restore (the driver died) counts: the next start puts it back and checks it again.
    public static func exists(instanceDir: URL) -> Bool {
        let fm = FileManager.default
        return (fm.fileExists(atPath: stateURL(instanceDir: instanceDir).path)
                || fm.fileExists(atPath: instanceDir.appending(path: restoringName).path))
            && fm.fileExists(atPath: recordURL(instanceDir: instanceDir).path)
    }

    public static func record(instanceDir: URL) -> Record? {
        guard let data = try? Data(contentsOf: recordURL(instanceDir: instanceDir)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    public static func write(_ record: Record, instanceDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: recordURL(instanceDir: instanceDir), options: .atomic)
    }

    /// Throws the saved state away (the next start boots afresh). The state goes first, so an
    /// interruption never leaves a state without its record looking valid.
    public static func discard(instanceDir: URL) throws {
        let fm = FileManager.default
        for name in [stateName, restoringName, partialName, recordName] {
            let url = instanceDir.appending(path: name)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }

    /// Why `saved` can't be restored given `current`, or nil if it can.
    public static func mismatch(saved: Record, current: Record) -> String? {
        if let mac = saved.macAddress, mac != current.macAddress {
            return "the VM was renamed or moved since it was hibernated (its MAC address changed)"
        }
        if saved.configuration != current.configuration {
            return "the VM's settings changed since it was hibernated"
        }
        let now = Dictionary(current.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for file in saved.files {
            let name = (file.path as NSString).lastPathComponent
            guard let other = now[file.path] else { return "\(name) is gone" }
            if other.inode != file.inode { return "\(name) was replaced" }
            if other.size != file.size { return "\(name) changed size" }
            if other.modified != file.modified { return "\(name) was written to" }
        }
        if current.files.count != saved.files.count { return "the VM's disks changed" }
        return nil
    }
}
