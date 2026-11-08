import Foundation
import Testing
@testable import LimaKit

/// Hibernating a `hanalima` VM (docs/11, stage 2): the control socket's `hibernate` saves the
/// guest's RAM next to its disk (VZ's state save) and powers it off; Lima sees an ordinary stop.
/// The next `limactl start` restores the state instead of booting: the same boot, a process and
/// a file in tmpfs still there, and the driver runs Lima's boot scripts again over SSH so Lima
/// sees the new instance ID. A start after the settings changed is refused with the state kept;
/// a `limactl clone` copy and a renamed VM (both get a new `vz-identifier`) throw the state away and boot afresh.
///
/// Needs `scripts/build-app.sh` first and the Mac unlocked (the state is encrypted with a Secure
/// Enclave key). Alpine by default (`HANALIMA_E2E_TEMPLATE` changes it), seven boots.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DriverHibernateEndToEndTests {
    let vm = "hanalima-e2e-hibernate"
    let copy = "hanalima-e2e-hibernate-copy"
    let renamed = "hanalima-e2e-hibernate-renamed"
    let template = ProcessInfo.processInfo.environment["HANALIMA_E2E_TEMPLATE"] ?? "alpine"
    static let helpers = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/Helpers")
    let client = LimaClient(limactlURL: LimaClient.locate()!,
                            environment: ProcessInfo.processInfo.environment.merging(["LIMA_DRIVERS_PATH": helpers.path]) { $1 })

    @Test(.timeLimit(.minutes(20)))
    func hibernateAndResume() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "lima-driver-hanalima").path),
                     "run scripts/build-app.sh first")
        for name in [vm, copy, renamed] { _ = try? await drain(client.delete(name, force: true)) }
        defer { E2ECleanup.deleteInstances([vm, copy, renamed], environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }
        _ = try await drain(client.create(CreateOptions(name: vm, template: template, cpus: 2, memoryGiB: 2, diskGiB: 10,
                                                        vmType: .hanalima, mountNone: true)))
        let created = try #require(try await client.list().first { $0.name == vm })
        let dir = URL(filePath: created.dir, directoryHint: .isDirectory)
        _ = try await drain(client.start(vm))
        let bootID = try await sh(vm, "cat /proc/sys/kernel/random/boot_id")
        let firstIID = try await sh(vm, "cat /run/lima-boot-done")
        _ = try await sh(vm, "echo kept > /dev/shm/hibernate-marker; nohup sleep 99999 </dev/null >/dev/null 2>&1 &")

        // Hibernate: Lima lists the VM as stopped, with the state and its record in the folder.
        try hibernate(dir)
        try await waitForStatus(vm, .stopped)
        #expect(SavedState.exists(instanceDir: dir))

        // Resume: the same boot, tmpfs and processes kept, a new instance ID handed over.
        _ = try await drain(client.start(vm))
        #expect(try await sh(vm, "cat /proc/sys/kernel/random/boot_id") == bootID)
        #expect(try await sh(vm, "cat /dev/shm/hibernate-marker") == "kept")
        #expect(!(try await sh(vm, "pgrep -f 'sleep 99999'")).isEmpty)
        let iid = try await sh(vm, "cat /run/lima-boot-done")
        #expect(iid.hasPrefix("iid-") && iid != firstIID)
        #expect(!SavedState.exists(instanceDir: dir), "the state is used once")
        let log = (try? String(contentsOf: dir.appending(path: "driver.stderr.log"), encoding: .utf8)) ?? ""
        #expect(log.contains("resumed the hibernated state"))
        #expect(log.contains("ran Lima's boot scripts again"))

        // Hibernate again and change the memory: the start is refused and the state kept.
        try hibernate(dir)
        try await waitForStatus(vm, .stopped)
        _ = try await drain(client.edit(vm, set: [".memory = \"3GiB\""]))
        await #expect(throws: (any Error).self) { try await drain(client.start(vm)) }
        #expect(SavedState.exists(instanceDir: dir))
        let refused = (try? String(contentsOf: dir.appending(path: "driver.stderr.log"), encoding: .utf8)) ?? ""
        #expect(refused.contains("can't resume the hibernated VM: the VM's settings changed"))

        _ = try await drain(client.edit(vm, set: [".memory = \"2GiB\""]))

        // A clone copies the state; its start throws it away and boots afresh.
        _ = try await drain(client.clone(vm, as: copy))
        _ = try await drain(client.start(copy))
        let copyDir = dir.deletingLastPathComponent().appending(path: copy)
        #expect(!SavedState.exists(instanceDir: copyDir))
        #expect(try await sh(copy, "cat /proc/sys/kernel/random/boot_id") != bootID)
        _ = try await drain(client.stop(copy))

        // The settings back as saved: the original resumes after all.
        _ = try await drain(client.start(vm))
        #expect(try await sh(vm, "cat /proc/sys/kernel/random/boot_id") == bootID)

        // Renamed while hibernated: Lima gives the VM a new identifier and MAC, so the state
        // can't be restored; the start throws it away and boots afresh, like a clone's.
        try hibernate(dir)
        try await waitForStatus(vm, .stopped)
        _ = try await client.runner.run(["rename", vm, renamed])
        let renamedDir = dir.deletingLastPathComponent().appending(path: renamed)
        #expect(SavedState.exists(instanceDir: renamedDir))
        _ = try await drain(client.start(renamed))
        #expect(!SavedState.exists(instanceDir: renamedDir))
        #expect(try await sh(renamed, "cat /proc/sys/kernel/random/boot_id") != bootID)
        _ = try await drain(client.stop(renamed))
    }

    private func hibernate(_ dir: URL) throws {
        let started = Date()
        let response = try DriverControl.send(DriverControl.Request(op: .hibernate), instanceDir: dir, timeout: 120)
        print("hibernate: \(response.state ?? "?") in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, "
              + "\((SavedState.record(instanceDir: dir)?.size ?? 0) >> 20) MiB")
    }

    private func waitForStatus(_ name: String, _ status: InstanceStatus) async throws {
        let started = Date()
        while Date().timeIntervalSince(started) < 60 {
            if try await client.list().first(where: { $0.name == name })?.status == status { return }
            try await Task.sleep(for: .seconds(1))
        }
        Issue.record("\(name) didn't become \(status)")
    }

    private func sh(_ name: String, _ script: String) async throws -> String {
        let out = try? await client.runner.run(["shell", name, "sh", "-c", script])
        if out == nil { print("failed: \(script.prefix(80))") }
        return (out?.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
