import Foundation
import LimaKit

/// Cleanup for end-to-end tests that must run even when a test fails or throws.
///
/// It is synchronous so it can sit in `defer`: a `Task` started there may not run before the
/// test process exits, which left test VMs behind (seen on 2026-10-12).
enum E2ECleanup {
    /// `limactl delete --force` for each VM that exists (errors ignored), optionally after
    /// turning off its start at login.
    static func deleteInstances(_ names: [String], disableAutostart: Bool = false) {
        guard let limactl = LimaClient.locate() else { return }
        for name in names {
            if disableAutostart { run(limactl, ["autostart", "disable", name, "--tty=false"]) }
            run(limactl, ["delete", "--force", name, "--tty=false"])
        }
    }

    private static func run(_ executable: URL, _ arguments: [String]) {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }
}
