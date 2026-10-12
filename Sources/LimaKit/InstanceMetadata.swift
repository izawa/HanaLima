import Foundation

/// What HanaLima remembers about a VM, in `~/.lima/<name>/hanalima-vm.json`.
///
/// It lives in the instance folder so it follows `limactl rename` and goes away with
/// `limactl delete`. A copy records only its parent (an id plus the name at the time), never its
/// children: copies are independent of each other (APFS clones, not backing chains), so the
/// lineage is information, and any depth costs one small file per VM. Children and ancestors are
/// worked out from all the VMs' records when needed.
public struct InstanceMetadata: Codable, Equatable, Sendable {
    public struct Parent: Codable, Equatable, Sendable {
        public var id: UUID
        /// The parent's name when the copy was made (shown if the parent is gone or renamed).
        public var name: String
        public var copiedAt: Date

        public init(id: UUID, name: String, copiedAt: Date) {
            self.id = id
            self.name = name
            self.copiedAt = copiedAt.wholeSeconds
        }
    }

    public var id: UUID
    /// The folder this record was written for. A different folder means the VM was renamed, or
    /// copied by `limactl clone` (which copies every file), outside HanaLima.
    public var instanceDir: String
    public var createdAt: Date?
    public var parent: Parent?
    /// The Lima template it was created from, when HanaLima created it.
    public var template: String?
    public var note: String

    public init(id: UUID = UUID(), instanceDir: URL, createdAt: Date? = .now, parent: Parent? = nil, note: String = "") {
        self.id = id
        self.instanceDir = instanceDir.path(percentEncoded: false)
        self.createdAt = createdAt?.wholeSeconds
        self.parent = parent
        self.note = note
    }

    public static let fileName = "hanalima-vm.json"

    public static func url(instanceDir: URL) -> URL { instanceDir.appending(path: fileName) }

    public static func load(instanceDir: URL) -> InstanceMetadata? {
        guard let data = try? Data(contentsOf: url(instanceDir: instanceDir)) else { return nil }
        return try? decoder.decode(InstanceMetadata.self, from: data)
    }

    public func save() throws {
        let dir = URL(filePath: instanceDir, directoryHint: .isDirectory)
        try Self.encoder.encode(self).write(to: Self.url(instanceDir: dir), options: .atomic)
    }

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

    /// Reads every VM's record and repairs what changed outside HanaLima, writing the fixes:
    /// - no record (made before HanaLima kept one, or by `limactl create`): a new id, no parent;
    /// - a record written for another folder whose VM still has it there: a `limactl clone` copy,
    ///   which gets a new id with that VM as its parent;
    /// - a record written for another folder that no VM has any more: a rename; the folder is
    ///   updated and the id kept.
    /// Returns the records by instance name.
    public static func reconcile(_ instances: [(name: String, dir: URL)]) -> [String: InstanceMetadata] {
        let loaded = instances.map { (name: $0.name, dir: $0.dir, meta: load(instanceDir: $0.dir)) }
        func isHome(_ meta: InstanceMetadata, _ dir: URL) -> Bool {
            ExternalDisk.samePath(URL(filePath: meta.instanceDir, directoryHint: .isDirectory), dir)
        }
        var result: [String: InstanceMetadata] = [:]
        // Records sitting in the folder they were written for are authoritative.
        var holder: [UUID: String] = [:]
        for entry in loaded {
            if let meta = entry.meta, isHome(meta, entry.dir), holder[meta.id] == nil {
                holder[meta.id] = entry.name
                result[entry.name] = meta
            }
        }
        for entry in loaded where result[entry.name] == nil {
            var meta: InstanceMetadata
            if let old = entry.meta, let original = holder[old.id] {
                // Copied by limactl clone (the original still holds the id), or another stray
                // copy of a renamed VM: a copy of the VM that holds the id.
                meta = InstanceMetadata(instanceDir: entry.dir, createdAt: .now,
                                        parent: Parent(id: old.id, name: original, copiedAt: .now))
            } else if var old = entry.meta {
                // Renamed (or its original is gone): keep the id.
                old.instanceDir = entry.dir.path(percentEncoded: false)
                meta = old
            } else {
                meta = InstanceMetadata(instanceDir: entry.dir, createdAt: nil)
            }
            holder[meta.id] = entry.name
            try? meta.save()
            result[entry.name] = meta
        }
        return result
    }
}

/// The lineage among VMs, from their records.
public struct InstanceLineage: Sendable {
    public let records: [String: InstanceMetadata]

    public init(_ records: [String: InstanceMetadata]) { self.records = records }

    /// The parent's current name, or nil when it has been deleted (show `parent.name` then).
    public func parentName(of name: String) -> String? {
        guard let parent = records[name]?.parent else { return nil }
        return records.first { $0.value.id == parent.id }?.key
    }

    /// The direct copies of `name`, by name.
    public func children(of name: String) -> [String] {
        guard let id = records[name]?.id else { return [] }
        return records.filter { $0.value.parent?.id == id }.keys.sorted()
    }
}

extension Date {
    /// The record stores ISO 8601 without fractions; round so a saved record equals the one in memory.
    var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
