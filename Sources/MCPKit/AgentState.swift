import Foundation

/// What the MCP server keeps across launches (docs/14 §6.3, §7.1): the jobs and the ledger of
/// what MCP made, in one file (`~/.hanalima/agent-state.json`, 0600) so no two files can
/// disagree. Written whole on every change, by rename.
@MainActor
public final class AgentState {
    public struct LedgerVM: Codable, Equatable, Sendable {
        public var name: String
        public var job: String
    }
    public struct LedgerNetwork: Codable, Equatable, Sendable {
        public var job: String
    }
    struct File: Codable {
        var version = 1
        var nextJobID: Int
        var jobs: [Job]
        /// Record id (InstanceMetadata.id) -> entry: a CLI clone gets a new id, so it is the user's.
        var vms: [UUID: LedgerVM]
        var networks: [String: LedgerNetwork]
    }

    public let jobs: JobStore
    private var vms: [UUID: LedgerVM]
    private var networks: [String: LedgerNetwork]
    private let url: URL?
    private var observers: [@MainActor () -> Void] = []
    /// The last error writing the file; the tools refuse to change anything while it is set.
    public private(set) var saveError: String?

    /// `url` nil keeps everything in memory (tests).
    public init(url: URL?) {
        self.url = url
        let file = url.flatMap { try? JSONDecoder.iso.decode(File.self, from: Data(contentsOf: $0)) }
        jobs = JobStore(restoring: file?.jobs ?? [], nextID: file?.nextJobID ?? 1)
        vms = file?.vms ?? [:]
        networks = file?.networks ?? [:]
        jobs.onChange = { [weak self] in self?.changed() }
    }

    /// Called after every change of a job or the ledger.
    public func observe(_ action: @escaping @MainActor () -> Void) { observers.append(action) }

    public func ownsVM(_ id: UUID) -> Bool { vms[id] != nil }
    public func ownsNetwork(_ name: String) -> Bool { networks[name] != nil }
    public var ownedVMs: [UUID: LedgerVM] { vms }

    public func recordVM(_ id: UUID, name: String, job: String) { vms[id] = LedgerVM(name: name, job: job); changed() }
    public func forgetVM(_ id: UUID) { vms[id] = nil; changed() }
    public func recordNetwork(_ name: String, job: String) { networks[name] = LedgerNetwork(job: job); changed() }
    public func forgetNetwork(_ name: String) { networks[name] = nil; changed() }

    private func changed() {
        save()
        for observer in observers { observer() }
    }

    private func save() {
        guard let url else { return }
        let file = File(nextJobID: jobs.nextID, jobs: jobs.jobs, vms: vms, networks: networks)
        do {
            let data = try JSONEncoder.iso.encode(file)
            let temp = url.appendingPathExtension("tmp")
            try data.write(to: temp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            guard rename(temp.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            saveError = nil
        } catch {
            saveError = "\(error)"
        }
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

private extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }()
}
