import Foundation
import Testing
@testable import LimaKit

/// `limactl snapshot` on a `hanalima` VM (docs/09, item 3): the driver answers the snapshot RPCs
/// with the app's APFS-clone snapshots (`DiskSnapshot`), so the CLI and the snapshot tab see one
/// list. Create a snapshot of the fresh VM, leave a marker file, take another, apply the first
/// (the marker is gone), delete both. A running VM is refused. The driver that `limactl
/// snapshot` spawns for a stopped VM (and never stops) exits on its own once limactl is gone.
///
/// Needs `scripts/build-app.sh` first. Alpine, three boots.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DriverSnapshotEndToEndTests {
    let vm = "hanalima-e2e-drvsnap"
    static let helpers = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/Helpers")
    let client = LimaClient(limactlURL: LimaClient.locate()!,
                            environment: ProcessInfo.processInfo.environment.merging(["LIMA_DRIVERS_PATH": helpers.path]) { $1 })

    @Test(.timeLimit(.minutes(15)))
    func limactlSnapshotUsesDiskSnapshots() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "lima-driver-hanalima").path),
                     "run scripts/build-app.sh first")
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm], environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }
        _ = try await drain(client.create(CreateOptions(name: vm, template: "alpine", cpus: 2, memoryGiB: 2, diskGiB: 10, vmType: .hanalima)))
        let created = try #require(try await client.list().first { $0.name == vm })
        let dir = URL(filePath: created.dir, directoryHint: .isDirectory)
        _ = try await drain(client.start(vm))
        _ = try await drain(client.stop(vm))

        // A snapshot of the fresh VM, through limactl, visible to the app's DiskSnapshot.
        _ = try await client.runner.run(["snapshot", "create", vm, "--tag", "clean"])
        #expect(DiskSnapshot.list(instanceDir: dir).map(\.name) == ["clean"])
        let listed = try await client.runner.run(["snapshot", "list", vm]).stdoutString
        print(listed, terminator: "")
        #expect(listed.hasPrefix("ID  TAG"), "QEMU-style header")
        #expect(try await client.runner.run(["snapshot", "list", vm, "--quiet"]).stdoutString == "clean\n")
        // Tags are one word (the quiet list is parsed by columns).
        await #expect(throws: (any Error).self) { try await client.runner.run(["snapshot", "create", vm, "--tag", "two words"]) }

        // The driver limactl spawned for the command outlives limactl; it exits once idle and orphaned.
        var lingering = try await processes(matching: "lima-driver-hanalima --inst-dir \(dir.path)")
        for _ in 0..<30 where lingering > 0 {
            try await Task.sleep(for: .seconds(1))
            lingering = try await processes(matching: "lima-driver-hanalima --inst-dir \(dir.path)")
        }
        #expect(lingering == 0, "the driver spawned by limactl snapshot exited on its own")

        // Leave a marker, snapshot that too; a running VM is refused.
        _ = try await drain(client.start(vm))
        await #expect(throws: (any Error).self) { try await client.runner.run(["snapshot", "create", vm, "--tag", "running"]) }
        #expect(try await sh("touch ~/hanalima-marker && echo ok") == "ok")
        _ = try await drain(client.stop(vm))
        _ = try await client.runner.run(["snapshot", "create", vm, "--tag", "marked"])
        #expect(try await client.runner.run(["snapshot", "list", vm, "--quiet"]).stdoutString == "clean\nmarked\n")

        // Back to the clean one: the marker is gone.
        _ = try await client.runner.run(["snapshot", "apply", vm, "--tag", "clean"])
        _ = try await drain(client.start(vm))
        #expect(try await sh("test -e ~/hanalima-marker && echo present || echo absent") == "absent")
        _ = try await drain(client.stop(vm))

        _ = try await client.runner.run(["snapshot", "delete", vm, "--tag", "clean"])
        _ = try await client.runner.run(["snapshot", "delete", vm, "--tag", "marked"])
        await #expect(throws: (any Error).self) { try await client.runner.run(["snapshot", "delete", vm, "--tag", "clean"]) }
        #expect(try await client.runner.run(["snapshot", "list", vm, "--quiet"]).stdoutString == "")
        #expect(DiskSnapshot.list(instanceDir: dir).isEmpty)
    }

    private func sh(_ script: String) async throws -> String {
        let out = try? await client.runner.run(["shell", vm, "sh", "-c", script])
        if out == nil { print("failed: \(script.prefix(80))") }
        return (out?.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func processes(matching pattern: String) async throws -> Int {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self).split(separator: "\n").count
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
