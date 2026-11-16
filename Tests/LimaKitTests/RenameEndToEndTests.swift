import Foundation
import Testing
@testable import LimaKit

/// Renames a real VM the way HanaLima does (`InstanceRename.run`) and boots it under the new
/// name. Run with `HANALIMA_E2E=1 swift test --filter RenameEndToEnd`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct RenameEndToEndTests {
    let vm = "hanalima-e2e-ren1"
    let renamed = "hanalima-e2e-ren2"
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(15)))
    func renameKeepsIdentityMACsAndStartAtLogin() async throws {
        for name in [vm, renamed] { _ = try? await drain(client.delete(name, force: true)) }
        var snapshotsToRemove: (home: URL, id: UUID)?
        defer {
            E2ECleanup.deleteInstances([vm, renamed], disableAutostart: true)
            if let s = snapshotsToRemove { DiskSnapshot.removeLocalSnapshots(limaHome: s.home, id: s.id) }
        }

        // A NIC whose MAC Lima derives from the lima.yaml path.
        _ = try await drain(client.create(CreateOptions(
            name: vm, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10, vmType: .vz, mountNone: true,
            setExpressions: [#".networks = [{"vzNAT": true}]"#])))
        _ = try await drain(client.start(vm))
        _ = try await drain(client.stop(vm))

        let before = try #require(try await client.list().first { $0.name == vm })
        let dir = before.instanceDir
        let home = dir.deletingLastPathComponent()
        var record = try #require(InstanceMetadata.reconcile([(vm, dir)])[vm])
        record.group = "e2e"
        try record.save()
        snapshotsToRemove = (home, record.id)
        let snapshot = try DiskSnapshot.create(instanceDir: dir, name: "before-rename")
        try await client.setAutostart(vm, enabled: true)
        let mac = try #require(before.networks?.first?.macAddress)

        #expect(InstanceRename.blocker(of: before) == nil)
        #expect(InstanceRename.nameProblem(renamed, for: before) == nil)
        try await InstanceRename.run(before, to: renamed, client: client)

        let list = try await client.list()
        #expect(!list.contains { $0.name == vm })
        let after = try #require(list.first { $0.name == renamed })
        let newDir = after.instanceDir
        #expect(after.networks?.first?.macAddress == mac)
        let moved = try #require(InstanceMetadata.load(instanceDir: newDir))
        #expect(moved.id == record.id)
        #expect(moved.group == "e2e")
        #expect(moved.autostartAfterRename == nil)
        #expect(InstanceMetadata.reconcile([(renamed, newDir)])[renamed]?.id == record.id)
        #expect(DiskSnapshot.list(instanceDir: newDir).map(\.id) == [snapshot.id])
        #expect(client.isAutostartEnabled(renamed))
        #expect(!client.isAutostartEnabled(vm))

        // Boots with the pinned host key and the new host name.
        try await client.setAutostart(renamed, enabled: false)  // start directly, not through launchd
        _ = try await drain(client.start(renamed))
        let hostname = try await client.runner.run(["shell", renamed, "hostname"]).stdoutString
        #expect(hostname.trimmingCharacters(in: .whitespacesAndNewlines) == "lima-\(renamed)")
        _ = try await drain(client.stop(renamed))
    }
}

private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
