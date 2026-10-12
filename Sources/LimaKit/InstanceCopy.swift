import Foundation

/// Copying a VM: `limactl clone`, then what Lima leaves to HanaLima.
///
/// `limactl clone` copies the instance folder with APFS clones (instant, and no space until
/// either VM writes) and gives the copy a new hostname, MAC addresses, VZ machine identifier,
/// SSH port and host keys. It also copies things that must not be shared or don't belong to the
/// copy, handled here: a link to a moved disk (see `ExternalDisk.owner(sharingWith:)`),
/// MAC addresses set by hand in `lima.yaml`, the source's logs and HanaLima's record.
public enum InstanceCopy {
    /// `--set` expressions for `limactl clone`: drop hand-set MAC addresses, which would
    /// otherwise put two VMs on a network with the same address.
    public static func cloneExpressions(sourceConfig: String) -> [String] {
        sourceConfig.contains("macAddress:") ? ["del(.networks[].macAddress)"] : []
    }

    /// Host agent and serial logs copied from the source; the copy starts with empty ones.
    static let copiedLogs = ["ha.stdout.log", "ha.stderr.log", "serial.log", "serialp.log", "serialv.log"]

    /// After `limactl clone`: empties the copied logs, gives the copy its own disk if it shares a
    /// moved one, and writes its record with the source as parent.
    public static func finish(copyDir: URL, name: String, source: InstanceMetadata?, sourceName: String,
                              note: String, progress: @escaping @Sendable (Double) -> Void) async throws -> InstanceMetadata {
        for log in copiedLogs {
            let url = copyDir.appending(path: log)
            if FileManager.default.fileExists(atPath: url.path) { _ = truncate(url.path, 0) }
        }
        if ExternalDisk.owner(sharingWith: copyDir) != nil {
            try await ExternalDisk.separate(instanceDir: copyDir, name: name, progress: progress)
        }
        let parent = source.map { InstanceMetadata.Parent(id: $0.id, name: sourceName, copiedAt: .now) }
        let meta = InstanceMetadata(instanceDir: copyDir, parent: parent, note: note)
        try meta.save()
        return meta
    }
}
