import Foundation
import Testing
@testable import LimaKit

/// Creates a VM from an installer ISO the way the app does (docs/07), installs Ubuntu Server
/// unattended, and boots the result under Lima. Virtualization.framework needs the signed app,
/// so the install itself runs in `build/HanaLima.app` through `HANALIMA_E2E_AUTOINSTALL`.
///
/// Needs `scripts/build-app.sh` first and the ISO: `HANALIMA_E2E_ISO=~/Downloads/ubuntu-26.04-live-server-arm64.iso`.
/// Run with `HANALIMA_E2E=1 HANALIMA_E2E_ISO=… swift test --filter ISOInstallEndToEnd` (about 10 minutes).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"
                                && ProcessInfo.processInfo.environment["HANALIMA_E2E_ISO"] != nil))
struct ISOInstallEndToEndTests {
    let vm = "hanalima-e2e-iso"
    let client = LimaClient(limactlURL: LimaClient.locate()!)
    static let app = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/MacOS/HanaLima")

    @Test(.timeLimit(.minutes(25)))
    func installsFromISOAndBootsUnderLima() async throws {
        let iso = URL(filePath: NSString(string: ProcessInfo.processInfo.environment["HANALIMA_E2E_ISO"]!).expandingTildeInPath)
        try #require(FileManager.default.isExecutableFile(atPath: Self.app.path), "run scripts/build-app.sh first")
        let work = FileManager.default.temporaryDirectory.appending(path: "hanalima-e2e-iso-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm]) }

        // What the create sheet does: a placeholder image gives a blank disk of the wanted size.
        let placeholder = work.appending(path: "placeholder.raw")
        try Data(count: 1 << 20).write(to: placeholder)
        _ = try await drain(client.create(CreateOptions(
            name: vm, template: "default", cpus: 2, memoryGiB: 4, diskGiB: 12, vmType: .vz,
            setExpressions: [#".images = [{"location": "\#(placeholder.path)", "arch": "aarch64"}]"#,
                             #".containerd = {"system": false, "user": false}"#])))
        let inst = try #require(try await client.list().first { $0.name == vm })
        let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)
        #expect(StorageReport.allocatedSize(of: dir.appending(path: "disk")) < 16 << 20)  // blank

        // The unattended install: EFI boot image, seed with the fix-up as late commands.
        let boot = work.appending(path: "boot.img"), seed = work.appending(path: "seed.iso")
        try InstallerAutoinstall.makeBootImage(at: boot, iso: iso)
        let openssl = Process()
        openssl.executableURL = URL(filePath: "/usr/bin/openssl")
        openssl.arguments = ["passwd", "-6", "hanalima"]
        let hashPipe = Pipe()
        openssl.standardOutput = hashPipe
        try openssl.run()
        let hash = String(data: hashPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        openssl.waitUntilExit()
        try InstallerAutoinstall.makeSeedISO(at: seed, userData: InstallerAutoinstall.userData(
            hostname: "autoinst", userName: "test", passwordHash: hash))

        let started = Date.now
        let install = Process()
        install.executableURL = Self.app
        install.environment = ProcessInfo.processInfo.environment.merging([
            "HANALIMA_E2E_AUTOINSTALL": vm, "HANALIMA_E2E_AUTOINSTALL_ISO": iso.path,
            "HANALIMA_E2E_AUTOINSTALL_BOOT": boot.path, "HANALIMA_E2E_AUTOINSTALL_SEED": seed.path,
        ]) { $1 }
        install.standardOutput = FileHandle.nullDevice
        try install.run()
        while install.isRunning { try await Task.sleep(for: .seconds(5)) }
        print("install: \(Int(Date.now.timeIntervalSince(started))) s, exit \(install.terminationStatus)")
        #expect(install.terminationStatus == 0)
        let serial = (try? String(contentsOf: dir.appending(path: "hanalima-installer-serial.log"), encoding: .utf8)) ?? ""
        #expect(serial.contains("HANALIMA-LATE-DONE"))

        // Back to Lima: cloud-init takes cidata.iso, so the user, agent and shares are there.
        _ = try await drain(client.start(vm))
        let out = try await client.runner.run(["shell", vm, "sh", "-c",
            ". /etc/os-release; echo \"$ID $(id -un) $(cloud-init status | cut -d' ' -f2) $(pgrep -c lima-guestagent) $(cat /var/lib/cloud/instance/datasource)\""]).stdoutString
        print("guest:", out.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(out.contains("ubuntu"))
        #expect(out.contains(NSUserName()))
        #expect(out.contains("done"))
        #expect(out.contains("DataSourceNoCloud"))
        #expect(out.contains("/dev/vd"))  // Lima's cidata, not a seed left behind
        _ = try await drain(client.stop(vm))
        _ = try await drain(client.delete(vm, force: true))
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
