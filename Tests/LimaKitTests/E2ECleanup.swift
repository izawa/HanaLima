import Foundation
import LimaKit

/// Cleanup for end-to-end tests that must run even when a test fails or throws.
///
/// It is synchronous so it can sit in `defer`: a `Task` started there may not run before the
/// test process exits, which left test VMs behind (seen on 2026-10-12).
enum E2ECleanup {
    /// `limactl delete --force` for each VM that exists (errors ignored), optionally after
    /// turning off its start at login.
    static func deleteInstances(_ names: [String], disableAutostart: Bool = false, environment: [String: String] = [:]) {
        guard let limactl = LimaClient.locate() else { return }
        for name in names {
            if disableAutostart { run(limactl, ["autostart", "disable", name, "--tty=false"], environment: environment) }
            run(limactl, ["delete", "--force", name, "--tty=false"], environment: environment)
        }
    }

    /// `limactl disk delete` for each disk (errors ignored).
    static func deleteDisks(_ names: [String]) {
        guard let limactl = LimaClient.locate() else { return }
        for name in names { run(limactl, ["disk", "delete", name, "--tty=false"]) }
    }

    private static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:]) {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if !environment.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }
}
