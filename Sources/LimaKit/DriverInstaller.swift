import Foundation

/// Puts HanaLima's VM driver where `limactl` finds it on its own, so a `hanalima` VM also works
/// from the terminal and at login (`limactl autostart`), without the app's `LIMA_DRIVERS_PATH`.
///
/// Lima looks for `lima-driver-*` in `LIMA_DRIVERS_PATH` first, then in `<prefix>/lib/lima/`
/// where `<prefix>` is the parent of limactl's directory (`/opt/homebrew/bin` → `/opt/homebrew`;
/// Lima's `usrlocal.LibexecLima`, chosen because Homebrew keeps `libexec` to itself). That
/// prefix is the user's own on a Homebrew install, so no privileges are needed, and it survives
/// a Lima upgrade (the Cellar folder doesn't).
///
/// What goes there is a symbolic link to the app's driver, not a copy: the driver is the main
/// executable of `HanaLimaDriver.app`, and a release build's driver carries an entitlement that
/// only counts inside that bundle (a copy is killed at launch; started through a link it works,
/// docs/19). Only an app in an Applications folder places it, so the link doesn't point into a
/// disk image, a translocated copy or a build folder. An app replaced at the same path serves
/// the next start through the same link; the link is replaced by rename, so a driver that is
/// running keeps its file. The app's bundled driver still wins while the app runs, because
/// `LIMA_DRIVERS_PATH` is registered first.
public enum DriverInstaller {
    public static let driverName = "lima-driver-hanalima"

    public enum Outcome: Equatable, Sendable {
        case installed(URL)
        case upToDate(URL)
        /// No writable `<prefix>/lib` next to this limactl (not a Homebrew-style install).
        case noLocation
        /// The app isn't in /Applications or ~/Applications.
        case notInApplications
    }

    /// `<prefix>/lib/lima/` for `limactl`, when the prefix can be written to.
    public static func directory(limactl: URL) -> URL? {
        let prefix = limactl.deletingLastPathComponent().deletingLastPathComponent()
        let lib = prefix.appending(path: "lib", directoryHint: .isDirectory)
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: lib.path) || (!fm.fileExists(atPath: lib.path) && fm.isWritableFile(atPath: prefix.path)) else { return nil }
        return lib.appending(path: "lima", directoryHint: .isDirectory)
    }

    /// Links Lima's driver directory to `bundled` unless it already does.
    @discardableResult
    public static func installIfNeeded(bundled: URL, limactl: URL) throws -> Outcome {
        guard isInApplications(bundled) else { return .notInApplications }
        guard let dir = directory(limactl: limactl) else { return .noLocation }
        return try link(bundled, in: dir)
    }

    /// Whether `limactl` finds this app's driver on its own: a link (to an executable) that
    /// `installIfNeeded` placed. A copy left by an earlier version doesn't count: it can't, say,
    /// resume a VM hibernated by this version (docs/19).
    public static func isPlaced(limactl: URL) -> Bool {
        let prefix = limactl.deletingLastPathComponent().deletingLastPathComponent()
        let dest = prefix.appending(path: "lib/lima/\(driverName)").path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: dest) else { return false }
        return FileManager.default.isExecutableFile(atPath: target)
    }

    static func isInApplications(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return ["/Applications/", NSHomeDirectory() + "/Applications/"].contains { path.hasPrefix($0) }
    }

    /// Places `dir/lima-driver-hanalima` as a link to `target`, replacing a copy or another link.
    static func link(_ target: URL, in dir: URL) throws -> Outcome {
        let fm = FileManager.default
        let dest = dir.appending(path: driverName)
        if (try? fm.destinationOfSymbolicLink(atPath: dest.path)) == target.path { return .upToDate(dest) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: ".\(driverName).\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: tmp.path, withDestinationPath: target.path)
        guard rename(tmp.path, dest.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "cannot place \(driverName) in \(dir.path): \(reason)"])
        }
        return .installed(dest)
    }
}
