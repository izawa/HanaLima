import Foundation
import Testing
@testable import LimaKit

/// Moving an existing VM between Lima's vz and HanaLima's driver (docs/09, stage 3): `limactl
/// edit --set '.vmType = "hanalima"'` on a stopped vz VM, and back. Both use the same `disk`,
/// `vz-efi` and `vz-identifier`, so a file written under one driver is there under the other,
/// and the guest keeps its usernet address and SSH.
///
/// Needs `scripts/build-app.sh` first. Alpine, four boots, a few minutes.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DriverMigrationEndToEndTests {
    let vm = "hanalima-e2e-migrate"
    static let template = ProcessInfo.processInfo.environment["HANALIMA_E2E_TEMPLATE"] ?? "alpine"
    static let helpers = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/Helpers")
    let client = LimaClient(limactlURL: LimaClient.locate()!,
                            environment: ProcessInfo.processInfo.environment.merging(["LIMA_DRIVERS_PATH": helpers.path]) { $1 })

    @Test(.timeLimit(.minutes(15)))
    func switchesBetweenVZAndTheDriverAndBack() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "lima-driver-hanalima").path),
                     "run scripts/build-app.sh first")
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm], environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }

        _ = try await drain(client.create(CreateOptions(name: vm, template: Self.template, cpus: 2, memoryGiB: 2, diskGiB: 10, vmType: .vz)))
        _ = try await drain(client.start(vm))
        _ = try await sh("echo under-vz > ~/hanalima-migration")
        _ = try await drain(client.stop(vm))

        // vz → hanalima: Lima validates the new config with the driver (Validate), then the
        // next start uses it. The file written under vz is still there.
        _ = try await drain(client.edit(vm, set: [".vmType = \"hanalima\""]))
        var listed = try #require(try await client.list().first { $0.name == vm })
        #expect(listed.vmType == "hanalima")
        #expect(listed.usesHanaLimaDriver && listed.usesVirtualization)
        _ = try await drain(client.start(vm))
        listed = try #require(try await client.list().first { $0.name == vm })
        #expect(listed.status == .running)
        #expect(try await sh("cat ~/hanalima-migration") == "under-vz")
        #expect(try await sh("ip -4 -o addr show eth0 | grep -c 192.168.5.15") == "1")
        _ = try await sh("echo under-hanalima >> ~/hanalima-migration")
        _ = try await drain(client.stop(vm))
        let dir = URL(filePath: listed.dir, directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "hanalima.pid").path))

        // hanalima → vz: the safety valve (a VM that works without HanaLima).
        _ = try await drain(client.edit(vm, set: [".vmType = \"vz\""]))
        listed = try #require(try await client.list().first { $0.name == vm })
        #expect(listed.vmType == "vz")
        _ = try await drain(client.start(vm))
        #expect(try await sh("cat ~/hanalima-migration | tr '\\n' ' '") == "under-vz under-hanalima")
        _ = try await drain(client.stop(vm))

        // What the driver refuses at edit time (Validate), with the reason for lima.REJECTED.yaml.
        await #expect(throws: Error.self, "Rosetta is refused by the driver's Validate") {
            _ = try await drain(client.edit(vm, set: [".vmType = \"hanalima\"", ".vmOpts.vz.rosetta.enabled = true"]))
        }
        listed = try #require(try await client.list().first { $0.name == vm })
        #expect(listed.vmType == "vz", "a rejected edit leaves lima.yaml alone")
    }

    private func sh(_ script: String) async throws -> String {
        let out = try? await client.runner.run(["shell", vm, "sh", "-c", script])
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
