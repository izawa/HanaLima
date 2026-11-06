import Foundation

/// Puts HanaLima's VM driver where `limactl` finds it on its own, so a `hanalima` VM also works
/// from the terminal, without the app's `LIMA_DRIVERS_PATH`.
///
/// Lima looks for `lima-driver-*` in `LIMA_DRIVERS_PATH` first, then in `<prefix>/lib/lima/`
/// where `<prefix>` is the parent of limactl's directory (`/opt/homebrew/bin` → `/opt/homebrew`;
/// Lima's `usrlocal.LibexecLima`, chosen because Homebrew keeps `libexec` to itself). That
/// prefix is the user's own on a Homebrew install, so no privileges are needed, and it survives
/// a Lima upgrade (the Cellar folder doesn't). A copy is replaced by rename, so a driver that is
/// running keeps its old file. The app's bundled driver still wins while the app runs, because
/// `LIMA_DRIVERS_PATH` is registered first.
public enum DriverInstaller {
    public static let driverName = "lima-driver-hanalima"

    public enum Outcome: Equatable, Sendable {
        case installed(URL)
        case upToDate(URL)
        /// No writable `<prefix>/lib` next to this limactl (not a Homebrew-style install).
        case noLocation
    }

    /// `<prefix>/lib/lima/` for `limactl`, when the prefix can be written to.
    public static func directory(limactl: URL) -> URL? {
        let prefix = limactl.deletingLastPathComponent().deletingLastPathComponent()
        let lib = prefix.appending(path: "lib", directoryHint: .isDirectory)
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: lib.path) || (!fm.fileExists(atPath: lib.path) && fm.isWritableFile(atPath: prefix.path)) else { return nil }
        return lib.appending(path: "lima", directoryHint: .isDirectory)
    }

    /// Copies `bundled` to Lima's driver directory unless the same build is already there.
    @discardableResult
    public static func installIfNeeded(bundled: URL, limactl: URL) throws -> Outcome {
        guard let dir = directory(limactl: limactl) else { return .noLocation }
        let fm = FileManager.default
        let dest = dir.appending(path: driverName)
        if fm.contentsEqual(atPath: bundled.path, andPath: dest.path) { return .upToDate(dest) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: ".\(driverName).\(UUID().uuidString)")
        try fm.copyItem(at: bundled, to: tmp)
        guard rename(tmp.path, dest.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "cannot place \(driverName) in \(dir.path): \(reason)"])
        }
        return .installed(dest)
    }
}
