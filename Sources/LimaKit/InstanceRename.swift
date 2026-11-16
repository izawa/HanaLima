import Foundation

/// Renaming a stopped VM (docs/15): `limactl rename`, plus what Lima leaves to HanaLima.
///
/// Lima moves the folder's files one by one into the new folder, empties `vz-identifier`, drops
/// the `protected` mark, and fails halfway on a subfolder. NICs without a MAC in lima.yaml get
/// one derived from the lima.yaml path, so they change too, and HanaLima's DHCP reservations
/// (by MAC) stop matching; the start-at-login registration names the VM. So before the rename
/// HanaLima writes the current MACs into lima.yaml and removes the registration, and after it
/// registers the new name.
public enum InstanceRename {
    /// Why a stopped VM can't be renamed, from its folder and configuration.
    public enum Blocker: Equatable, Sendable {
        /// `limactl protect`: Lima would drop the mark.
        case protected
        /// Lima stops halfway on a subfolder (QEMU's TPM state is one).
        case subfolder(String)
        /// Untested: Lima empties `vz-identifier`, the guest's machine identity.
        case macOSGuest
        /// Hibernated: the saved state is tied to `vz-identifier` and the MACs, which change.
        case hibernated
        /// `networks:` comes from outside lima.yaml (a template's `base`, Lima's defaults), so
        /// the MACs can't be written by position.
        case networksOutsideConfig
    }

    public enum NameProblem: Equatable, Sendable {
        case invalid
        /// Only the case differs: the folder is the same on a case-insensitive volume.
        case caseOnly
        case taken(String)
        /// Lima's limit on the SSH control socket's path.
        case tooLong
    }

    public static func blocker(of instance: LimaInstance) -> Blocker? {
        if instance.protected == true { return .protected }
        if SavedState.exists(instanceDir: instance.instanceDir) { return .hibernated }
        if instance.config?["os"]?.stringValue == "Darwin" { return .macOSGuest }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: instance.instanceDir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true { return .subfolder(entry.lastPathComponent) }
        }
        if pinExpressions(instance: instance) == nil { return .networksOutsideConfig }
        return nil
    }

    /// Checks `newName` for `instance`; `limaHome` is the folder of the instance folders.
    public static func nameProblem(_ newName: String, for instance: LimaInstance) -> NameProblem? {
        guard CreateOptions.isValidName(newName) else { return .invalid }
        if newName != instance.name, newName.lowercased() == instance.name.lowercased() { return .caseOnly }
        let limaHome = instance.instanceDir.deletingLastPathComponent()
        let folder = limaHome.appending(path: newName, directoryHint: .isDirectory)
        if newName == instance.name || FileManager.default.fileExists(atPath: folder.path) { return .taken(newName) }
        // pkg/limatype/filenames: the socket ssh makes is "ssh.sock" plus 17 characters, and
        // its whole path must be shorter than UNIX_PATH_MAX (104 on macOS).
        if folder.appending(path: "ssh.sock.1234567890123456").path(percentEncoded: false).utf8.count >= 104 { return .tooLong }
        return nil
    }

    /// `limactl edit --set` expressions that write each NIC's current MAC into lima.yaml where it
    /// has none; nil if the NICs in lima.yaml don't line up with the ones Lima uses.
    static func pinExpressions(instance: LimaInstance) -> [String]? {
        let text = (try? String(contentsOf: instance.configURL, encoding: .utf8)) ?? ""
        guard let raw = try? JSONValue.parseYAML(text) else { return nil }
        return pinExpressions(raw: raw["networks"]?.arrayValue ?? [], effective: instance.networks ?? [])
    }

    static func pinExpressions(raw: [JSONValue], effective: [NetworkAttachment]) -> [String]? {
        guard raw.count == effective.count else { return nil }
        var expressions: [String] = []
        for (i, (written, used)) in zip(raw, effective).enumerated() {
            guard written["socket"]?.stringValue == used.socket, written["lima"]?.stringValue == used.lima,
                  (written["vzNAT"]?.boolValue ?? false) == (used.vzNAT ?? false) else { return nil }
            if let mac = written["macAddress"]?.stringValue, !mac.isEmpty { continue }
            guard let mac = used.macAddress, !mac.isEmpty else { return nil }
            expressions.append(".networks[\(i)].macAddress = \(JSONValue.string(mac).jsonText)")
        }
        return expressions
    }

    /// `limactl rename` succeeded but the work after it (`finish`) didn't: the VM has its new
    /// name, and the record's flag lets the next refresh try the rest again.
    public struct FinishError: Error, LocalizedError {
        public var underlying: Error
        public var errorDescription: String? { underlying.localizedDescription }
    }

    /// Renames the stopped `instance` to `newName`. `log` gets limactl's output. Callers check
    /// `blocker` and `nameProblem` first (and that nothing else is using the VM).
    public static func run(_ instance: LimaInstance, to newName: String, client: LimaClient,
                           log: @escaping @Sendable (LogEntry) async -> Void = { _ in }) async throws {
        let name = instance.name
        guard let pins = pinExpressions(instance: instance) else { throw failure(String(localized: "lima.yaml の外で定義したネットワークがあるため、名前を変更できません。")) }
        if !pins.isEmpty {
            for try await entry in client.edit(name, set: pins) { await log(entry) }
        }
        let newDir = instance.instanceDir.deletingLastPathComponent().appending(path: newName, directoryHint: .isDirectory)
        // Also a registration a failed earlier rename still owes (the flag in the record).
        let autostart = client.isAutostartEnabled(name)
            || InstanceMetadata.load(instanceDir: instance.instanceDir)?.autostartAfterRename == true
        if autostart {
            try setAutostartFlag(true, instanceDir: instance.instanceDir)
            try await client.setAutostart(name, enabled: false)
        }
        do {
            for try await entry in client.rename(name, to: newName) { await log(entry) }
        } catch {
            // Lima checks before it moves anything. If it failed while moving, the VM is split
            // between two folders: register neither (and drop the flag wherever the record is,
            // so a refresh doesn't either) until someone puts it back together by hand.
            if FileManager.default.fileExists(atPath: newDir.path) {
                for dir in [instance.instanceDir, newDir] where InstanceMetadata.load(instanceDir: dir) != nil {
                    try? setAutostartFlag(false, instanceDir: dir)
                }
            } else if autostart, (try? await client.setAutostart(name, enabled: true)) != nil {
                // The flag stays if registering fails, so the next refresh tries again.
                try? setAutostartFlag(false, instanceDir: instance.instanceDir)
            }
            throw error
        }
        do {
            try await finish(instanceDir: newDir, name: newName, client: client, registerAutostart: autostart)
        } catch {
            throw FinishError(underlying: error)
        }
    }

    /// The work after `limactl rename`, for `name` in `instanceDir`: claims a moved disk's marker,
    /// registers start at login again (`registerAutostart`, or the record's flag when nil: a
    /// rename a quit cut short), and points the record at the new folder without the flag.
    public static func finish(instanceDir: URL, name: String, client: LimaClient, registerAutostart: Bool? = nil) async throws {
        // First, and whatever fails later: until then a CLI copy sharing the disk could take it.
        ExternalDisk.claimIfOrphaned(instanceDir: instanceDir, name: name)
        // Point the record here at once (not at the next listing), before anything can fail:
        // a CLI copy of the old folder could otherwise take its id.
        if var record = InstanceMetadata.load(instanceDir: instanceDir),
           !ExternalDisk.samePath(URL(filePath: record.instanceDir, directoryHint: .isDirectory), instanceDir) {
            record.instanceDir = instanceDir.path(percentEncoded: false)
            try record.save()
        }
        guard registerAutostart ?? (InstanceMetadata.load(instanceDir: instanceDir)?.autostartAfterRename == true) else { return }
        try await client.setAutostart(name, enabled: true)
        // Read after the await, so an edit made meanwhile isn't written over.
        if var record = InstanceMetadata.load(instanceDir: instanceDir), record.autostartAfterRename != nil {
            record.autostartAfterRename = nil
            try record.save()
        }
    }

    private static func setAutostartFlag(_ on: Bool, instanceDir: URL) throws {
        var record = InstanceMetadata.load(instanceDir: instanceDir) ?? InstanceMetadata(instanceDir: instanceDir, createdAt: nil)
        record.instanceDir = instanceDir.path(percentEncoded: false)
        record.autostartAfterRename = on ? true : nil
        try record.save()
    }

    private static func failure(_ message: String) -> ExternalDisk.Failure { ExternalDisk.Failure(message: message) }
}
