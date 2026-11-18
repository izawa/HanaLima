import Darwin
import Foundation

/// A unix socket's file as this process made it, removed only while the path still leads to that
/// same file. A driver process that outlives its turn (left behind after its VM stopped) then
/// can't take away the socket of the driver that replaced it at the same path.
public final class SocketFile: @unchecked Sendable {
    private struct Identity: Equatable {
        var device: dev_t
        var inode: ino_t
    }

    public let path: String
    private let lock = NSLock()
    private var identity: Identity?

    public init(path: String) { self.path = path }

    /// Notes the socket now at `path` as this process's (call once it is bound).
    public func claim() {
        let found = Self.identity(of: path)
        lock.withLock { identity = found }
    }

    /// Removes the file, if it is still the one claimed.
    public func remove() {
        guard let claimed = lock.withLock({ identity }), Self.identity(of: path) == claimed else { return }
        unlink(path)
    }

    private static func identity(of path: String) -> Identity? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return Identity(device: st.st_dev, inode: st.st_ino)
    }
}
