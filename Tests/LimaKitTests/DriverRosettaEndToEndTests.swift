import Foundation
import Testing
@testable import LimaKit

/// Rosetta on HanaLima's driver (docs/09, item 1): a VM created with `--rosetta` boots. On a Mac
/// with Rosetta installed the guest gets the `vz-rosetta` share and the binfmt entry (Lima's own
/// boot script; VZ reports it installed on the development Mac even though Rosetta 2 for Mac
/// apps isn't); without it the driver logs what to install and boots the VM without the share
/// instead of failing or installing it, unlike Lima's vz.
///
/// Needs `scripts/build-app.sh` first. Alpine, one boot.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DriverRosettaEndToEndTests {
    let vm = "hanalima-e2e-rosetta"
    static let helpers = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/Helpers")
    let client = LimaClient(limactlURL: LimaClient.locate()!,
                            environment: ProcessInfo.processInfo.environment.merging(["LIMA_DRIVERS_PATH": helpers.path]) { $1 })

    @Test(.timeLimit(.minutes(10)))
    func rosettaVMBootsWithOrWithoutRosetta() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "lima-driver-hanalima").path),
                     "run scripts/build-app.sh first")
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm], environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }
        _ = try await drain(client.create(CreateOptions(name: vm, template: "alpine", cpus: 2, memoryGiB: 2, diskGiB: 10,
                                                        vmType: .hanalima, rosetta: true)))
        let created = try #require(try await client.list().first { $0.name == vm })
        #expect(created.config?["vmOpts"]?["vz"]?["rosetta"]?["enabled"]?.boolValue == true)
        let dir = URL(filePath: created.dir, directoryHint: .isDirectory)
        _ = try await drain(client.start(vm))
        let log = (try? String(contentsOf: dir.appending(path: "driver.stderr.log"), encoding: .utf8)) ?? ""
        let installed = !log.contains("Rosetta is not installed") && !log.contains("Rosetta is not supported")
        let mounted = try await sh("mount | grep -c vz-rosetta; true")
        let binfmt = try await sh("test -f /proc/sys/fs/binfmt_misc/rosetta && echo yes || echo no")
        print("rosetta: host installed=\(installed) guest mounted=\(mounted) binfmt=\(binfmt)")
        if installed {
            #expect(mounted == "1")
            #expect(binfmt == "yes")
        } else {
            #expect(mounted == "0", "no share without Rosetta on the host")
        }
        // Lima's boot script ran (cidata saw the flag from Info); it fails loudly only on the mount.
        #expect(try await sh("sudo grep -c 05-rosetta-volume.sh /var/log/cloud-init-output.log; true") != "0")
        _ = try await drain(client.stop(vm))
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
