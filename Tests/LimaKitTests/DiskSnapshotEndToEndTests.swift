import Foundation
import Testing
@testable import LimaKit

/// HanaLima's VZ snapshots on a real VM: save, change, restore and boot; and a new VM from a
/// snapshot. Run with `HANALIMA_E2E=1 swift test --filter DiskSnapshotEndToEnd`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DiskSnapshotEndToEndTests {
    let vm = "hanalima-e2e-snap"
    let copy = "hanalima-e2e-snapcopy"
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(20)))
    func snapshotRestoreAndCopy() async throws {
        for name in [vm, copy] { _ = try? await drain(client.delete(name, force: true)) }
        _ = try await drain(client.create(CreateOptions(name: vm, template: "alpine", cpus: 1, memoryGiB: 1,
                                                        diskGiB: 10, vmType: .vz, mountNone: true)))
        _ = try await drain(client.start(vm))
        try await setMarker(vm, "before")
        _ = try await drain(client.stop(vm))
        let dir = URL(filePath: try #require(try await client.list().first { $0.name == vm }).dir, directoryHint: .isDirectory)

        let started = Date.now
        let snap = try DiskSnapshot.create(instanceDir: dir, name: "before")
        #expect(Date.now.timeIntervalSince(started) < 5)  // an APFS clone

        _ = try await drain(client.start(vm))
        #expect(try await marker(vm) == "before")
        try await setMarker(vm, "after")
        _ = try await drain(client.stop(vm))

        try DiskSnapshot.restore(snap, of: dir, into: dir)
        _ = try await drain(client.start(vm))
        #expect(try await marker(vm) == "before")
        try await setMarker(vm, "after")
        _ = try await drain(client.stop(vm))

        // A new VM from the snapshot, while the source stays as it is now.
        _ = try await drain(client.clone(vm, as: copy))
        let copyDir = dir.deletingLastPathComponent().appending(path: copy, directoryHint: .isDirectory)
        _ = try await InstanceCopy.finish(copyDir: copyDir, name: copy, source: nil, sourceName: vm,
                                          snapshot: snap.name, note: "") { _ in }
        #expect(DiskSnapshot.list(instanceDir: copyDir).isEmpty)
        try DiskSnapshot.restore(snap, of: dir, into: copyDir)
        _ = try await drain(client.start(copy))
        #expect(try await marker(copy) == "before")
        _ = try await drain(client.stop(copy))
        _ = try await drain(client.start(vm))
        #expect(try await marker(vm) == "after")
        _ = try await drain(client.stop(vm))

        let id = try #require(InstanceMetadata.load(instanceDir: dir)?.id)
        for name in [vm, copy] { _ = try await drain(client.delete(name, force: true)) }
        DiskSnapshot.removeLocalSnapshots(limaHome: dir.deletingLastPathComponent(), id: id)
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appending(path: "_hanalima-snapshots").path))
    }

    private func setMarker(_ name: String, _ text: String) async throws {
        _ = try await client.runner.run(["shell", name, "sudo", "sh", "-c", "echo \(text) > /root/marker && sync"])
    }

    private func marker(_ name: String) async throws -> String {
        try await client.runner.run(["shell", name, "sudo", "cat", "/root/marker"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
