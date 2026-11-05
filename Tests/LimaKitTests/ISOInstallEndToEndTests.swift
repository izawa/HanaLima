import Foundation
import Testing
@testable import LimaKit

/// Creates a VM from an installer ISO the way the app does (docs/07), installs Ubuntu Server
/// unattended, and boots the result under Lima. The install itself runs in the signed driver's
/// hosted mode (`lima-driver-hanalima --hosted`, headless), the way the installer window does.
///
/// Needs `scripts/build-app.sh` first and the ISO: `HANALIMA_E2E_ISO=~/Downloads/ubuntu-26.04-live-server-arm64.iso`.
/// Run with `HANALIMA_E2E=1 HANALIMA_E2E_ISO=… swift test --filter ISOInstallEndToEnd` (about 10 minutes).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"
                                && ProcessInfo.processInfo.environment["HANALIMA_E2E_ISO"] != nil))
struct ISOInstallEndToEndTests {
    let vm = "hanalima-e2e-iso"
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(25)))
    func installsFromISOAndBootsUnderLima() async throws {
        let iso = URL(filePath: NSString(string: ProcessInfo.processInfo.environment["HANALIMA_E2E_ISO"]!).expandingTildeInPath)
        try #require(FileManager.default.isExecutableFile(atPath: HostedBoot.driver.path), "run scripts/build-app.sh first")
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
        let serialLog = "hanalima-installer-serial.log"
        let install = try HostedBoot(dir: dir, cpus: 2, memoryGiB: 4, options: [
            "--iso", iso.path, "--boot-image", boot.path, "--seed", seed.path, "--no-cidata", "--serial-log", serialLog])
        // The unattended install powers the guest off at the end; the driver then exits.
        let exit = await install.waitForExit(timeout: 20 * 60)
        print("install: \(Int(Date.now.timeIntervalSince(started))) s, driver exit \(exit)")
        #expect(exit == 0, Comment(rawValue: install.logText.suffix(400).description))
        let serial = (try? String(contentsOf: dir.appending(path: serialLog), encoding: .utf8)) ?? ""
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
