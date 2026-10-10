import Foundation
import Testing
@testable import LimaKit

/// Creates, starts, watches, stops and deletes a real VM. Slow and downloads an image,
/// so it only runs with `HANALIMA_E2E=1 swift test --filter EndToEnd`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct EndToEndTests {
    @Test(.timeLimit(.minutes(15)))
    func lifecycle() async throws {
        let client = LimaClient(limactlURL: try #require(LimaClient.locate()))
        let name = "hanalima-e2e"
        _ = try? await drain(client.delete(name, force: true))

        // Collect watch events in the background.
        let collected = EventBox()
        let watcher = Task {
            for try await ev in client.watch() where ev.instance == name { collected.append(ev) }
        }
        defer { watcher.cancel() }

        let opts = CreateOptions(name: name, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10, vmType: .vz)
        let createLog = try await drain(client.create(opts))
        print("create:", createLog.map(\.displayText).joined(separator: "\n  "))
        #expect(try await client.list().first { $0.name == name }?.status == .stopped)

        let startLog = try await drain(client.start(name))
        print("start (last 10):", startLog.suffix(10).map(\.displayText).joined(separator: "\n  "))
        let running = try #require(try await client.list().first { $0.name == name })
        #expect(running.status == .running)
        #expect(running.cpus == 1)
        #expect(running.memory == Int64(1) << 30)
        print("instance:", running)

        let shell = try await client.runner.run(["shell", name, "uname", "-a"])
        print("uname:", shell.stdoutString)
        #expect(shell.stdoutString.contains("Linux"))

        _ = try await drain(client.stop(name))
        #expect(try await client.list().first { $0.name == name }?.status == .stopped)

        try await Task.sleep(for: .seconds(1))
        print("events:", collected.events.map(\.summary).joined(separator: "\n  "))
        #expect(collected.events.contains { $0.event.status.running == true })

        _ = try await drain(client.delete(name))
        #expect(try await client.list().first { $0.name == name } == nil)
    }

    private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
        var out: [LogEntry] = []
        for try await e in s { out.append(e) }
        return out
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [WatchEvent] = []
    var events: [WatchEvent] { lock.withLock { list } }
    func append(_ e: WatchEvent) { lock.withLock { list.append(e) } }
}

/// Edits a stopped VM's config and attaches a disk. Needs the alpine image (cached after the
/// lifecycle test). Run with `HANALIMA_E2E=1 swift test --filter EditEndToEnd`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct EditEndToEndTests {
    let client = LimaClient(limactlURL: LimaClient.locate()!)
    let name = "hanalima-e2e-edit"
    let diskName = "hanalima-e2e-disk"

    @Test(.timeLimit(.minutes(10)))
    func editAndAttachDisk() async throws {
        _ = try? await drain(client.delete(name, force: true))
        _ = try? await drain(client.deleteDisk(diskName))
        _ = try await drain(client.create(CreateOptions(name: name, template: "alpine", cpus: 1,
                                                        memoryGiB: 1, diskGiB: 10, vmType: .vz)))

        // Form-style edit via --set.
        var inst = try await instance()
        let original = try client.config(of: inst)
        #expect(original.mounts.map(\.location) == ["~"])
        var edited = original
        edited.cpus = 2
        edited.memory = "2GiB"
        edited.mounts[0].writable = true
        edited.portForwards.append(PortForwardConfig(guestPort: 80, hostPort: 18080))
        let exprs = edited.setExpressions(comparedTo: original)
        print("set:", exprs)
        _ = try await drain(client.edit(name, set: exprs))
        inst = try await instance()
        #expect(inst.cpus == 2)
        #expect(inst.memory == Int64(2) << 30)
        let reloaded = try client.config(of: inst)
        #expect(reloaded.mounts.first?.writable == true)
        #expect(reloaded.portForwards.first?.hostPort == 18080)
        #expect(reloaded.setExpressions(comparedTo: edited).isEmpty)

        // Shrinking the disk must be rejected by Lima.
        var shrink = reloaded
        shrink.disk = "5GiB"
        await #expect(throws: CommandError.self) {
            try await drain(client.edit(name, set: shrink.setExpressions(comparedTo: reloaded)))
        }

        // Raw YAML replacement through $VISUAL.
        let yaml = try client.configYAML(of: inst).replacingOccurrences(of: "cpus: 2", with: "cpus: 3")
        _ = try await drain(client.replaceConfig(name, yaml: yaml))
        #expect(try await instance().cpus == 3)

        // Invalid YAML is rejected and leaves the file unchanged.
        let before = try client.configYAML(of: inst)
        await #expect(throws: CommandError.self) {
            try await drain(client.replaceConfig(name, yaml: "cpus: [oops\n"))
        }
        #expect(try client.configYAML(of: inst) == before)
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/lima.REJECTED.yaml"))

        // Disk: create, attach, check, detach, delete.
        _ = try await drain(client.createDisk(diskName, size: "1GiB"))
        #expect(try await client.disks().contains { $0.name == diskName })
        var withDisk = try client.config(of: try await instance())
        let beforeDisk = withDisk
        withDisk.additionalDisks.append(AdditionalDiskConfig(name: diskName))
        _ = try await drain(client.edit(name, set: withDisk.setExpressions(comparedTo: beforeDisk)))
        #expect(try await instance().additionalDisks?.map(\.name) == [diskName])

        _ = try await drain(client.delete(name))
        _ = try await drain(client.deleteDisk(diskName))
        #expect(try await client.disks().contains { $0.name == diskName } == false)
    }

    private func instance() async throws -> LimaInstance {
        try #require(try await client.list().first { $0.name == name })
    }

    @discardableResult
    private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
        var out: [LogEntry] = []
        for try await e in s { out.append(e) }
        return out
    }
}

/// `limactl autostart enable/disable` on a stopped VM: registration only, the VM stays stopped.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct AutostartEndToEndTests {
    let name = "hanalima-e2e-autostart"
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(5)))
    func enableAndDisable() async throws {
        _ = try? await drain(client.delete(name, force: true))
        _ = try await drain(client.create(CreateOptions(name: name, template: "alpine", cpus: 1, memoryGiB: 1,
                                                        diskGiB: 10, vmType: .vz)))
        defer { Task { [client, name] in
            try? await client.setAutostart(name, enabled: false)
            _ = try? await drain(client.delete(name, force: true))
        } }
        #expect(!client.isAutostartEnabled(name))

        try await client.setAutostart(name, enabled: true)
        #expect(client.isAutostartEnabled(name))
        let plist = try String(contentsOf: LimaClient.autostartPlist(for: name), encoding: .utf8)
        #expect(plist.contains("<string>\(name)</string>"))
        #expect(try await client.list().first { $0.name == name }?.isRunning == false)

        try await client.setAutostart(name, enabled: false)
        #expect(!client.isAutostartEnabled(name))
        // Disabling twice is not an error.
        try await client.setAutostart(name, enabled: false)
        _ = try await drain(client.delete(name))
    }

    private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
        var out: [LogEntry] = []
        for try await e in s { out.append(e) }
        return out
    }
}

/// Snapshots on a stopped QEMU VM: create, restore (a file written later disappears), delete.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct SnapshotEndToEndTests {
    let name = "hanalima-e2e-snapshot"
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(15)))
    func createRestoreDelete() async throws {
        _ = try? await drain(client.delete(name, force: true))
        _ = try await drain(client.create(CreateOptions(name: name, template: "alpine", cpus: 1, memoryGiB: 1,
                                                        diskGiB: 10, vmType: .qemu)))
        defer { Task { [client, name] in _ = try? await drain(client.delete(name, force: true)) } }
        _ = try await drain(client.start(name))
        _ = try await client.runner.run(["shell", name, "sh", "-c", "echo before > $HOME/marker; sync"])
        _ = try await drain(client.stop(name))

        _ = try await drain(client.createSnapshot(name, tag: "e2e1"))
        #expect(try await client.snapshots(name).map(\.tag) == ["e2e1"])

        _ = try await drain(client.start(name))
        _ = try await client.runner.run(["shell", name, "sh", "-c", "echo after > $HOME/marker; sync"])
        _ = try await drain(client.stop(name))
        _ = try await drain(client.applySnapshot(name, tag: "e2e1"))
        _ = try await drain(client.start(name))
        let marker = try await client.runner.run(["shell", name, "sh", "-c", "cat $HOME/marker"]).stdoutString
        #expect(marker.trimmingCharacters(in: .whitespacesAndNewlines) == "before")
        _ = try await drain(client.stop(name))

        // Restoring a tag that doesn't exist fails (while stopped).
        await #expect(throws: (any Error).self) { try await drain(client.applySnapshot(name, tag: "missing")) }

        _ = try await drain(client.deleteSnapshot(name, tag: "e2e1"))
        #expect(try await client.snapshots(name).isEmpty)
        _ = try await drain(client.delete(name))
    }

    @discardableResult
    private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
        var out: [LogEntry] = []
        for try await e in s { out.append(e) }
        return out
    }
}
