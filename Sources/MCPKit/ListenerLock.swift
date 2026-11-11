import Foundation
import Darwin

/// Keep the inode in place after release so competing instances always lock the same file.
public final class ListenerLock {
    private let lock = NSLock()
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    public static func acquire(at url: URL) -> ListenerLock? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return ListenerLock(fd: fd)
    }

    public func release() {
        lock.withLock {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    deinit { release() }
}
