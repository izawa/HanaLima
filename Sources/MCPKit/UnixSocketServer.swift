import Foundation
import Darwin

public struct PeerInfo: Sendable {
    public let uid: uid_t
    public let pid: pid_t?

    public init(uid: uid_t, pid: pid_t?) {
        self.uid = uid
        self.pid = pid
    }
}

/// All descriptor ownership is guarded by the lock; workers alone close accepted descriptors.
public final class UnixSocketServer: @unchecked Sendable {
    public typealias Error = UnixSocketError
    private let path: String
    private let maxRequestBytes: Int
    private let maxConnections: Int
    private let handler: @Sendable (Data, PeerInfo) async -> Data
    private let lock = NSLock()
    private var source: (any DispatchSourceRead)?
    private var clients: Set<Int32> = []

    public init(path: String, maxRequestBytes: Int = 1 << 20, maxConnections: Int = 8,
                handler: @escaping @Sendable (Data, PeerInfo) async -> Data) {
        self.path = path
        self.maxRequestBytes = max(0, maxRequestBytes)
        self.maxConnections = max(0, maxConnections)
        self.handler = handler
    }

    public func start() throws {
        try lock.withLock {
            guard source == nil else { throw UnixSocketError.inUse }
            var address = try UnixSocketIO.address(path)
            let fd = try UnixSocketIO.socket()
            var bound = false
            do {
                var status = stat()
                if lstat(path, &status) == 0 {
                    let probe = try UnixSocketIO.socket()
                    defer { Darwin.close(probe) }
                    guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else { throw UnixSocketError.system(errno) }
                    let result = UnixSocketIO.withAddress(&address) { Darwin.connect(probe, $0, $1) }
                    let code = errno
                    if result == 0 || (code != ECONNREFUSED && code != ENOENT) { throw UnixSocketError.inUse }
                    // Do not remove a regular file merely because it cannot answer as a socket.
                    guard (status.st_mode & S_IFMT) == S_IFSOCK else { throw UnixSocketError.inUse }
                    guard unlink(path) == 0 || errno == ENOENT else { throw UnixSocketError.system(errno) }
                } else if errno != ENOENT {
                    throw UnixSocketError.system(errno)
                }
                guard UnixSocketIO.withAddress(&address, { Darwin.bind(fd, $0, $1) }) == 0 else {
                    throw errno == EADDRINUSE ? UnixSocketError.inUse : UnixSocketError.system(errno)
                }
                bound = true
                guard chmod(path, 0o600) == 0, Darwin.listen(fd, Int32(clamping: maxConnections)) == 0,
                      fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw UnixSocketError.system(errno) }
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
                source.setEventHandler { @Sendable [weak self] in self?.acceptConnections(fd) }
                source.setCancelHandler { @Sendable in Darwin.close(fd) }
                self.source = source
                source.resume()
            } catch {
                Darwin.close(fd)
                if bound { unlink(path) }
                throw error
            }
        }
    }

    public func stop() {
        lock.withLock {
            guard let source else { return }
            self.source = nil
            source.cancel()
            for client in clients { Darwin.shutdown(client, SHUT_RDWR) }
            unlink(path)
        }
    }

    deinit { stop() }

    private func acceptConnections(_ listener: Int32) {
        lock.withLock {
            guard let source, source.handle == listener else { return }
            while true {
                let fd = Darwin.accept(listener, nil, nil)
                if fd < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard clients.count < maxConnections, UnixSocketIO.protect(fd) else {
                    Darwin.close(fd)
                    continue
                }
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                    Darwin.close(fd)
                    continue
                }
                var pid: pid_t = 0
                var size = socklen_t(MemoryLayout.size(ofValue: pid))
                let hasPID = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0
                let peer = PeerInfo(uid: uid, pid: hasPID ? pid : nil)
                clients.insert(fd)
                DispatchQueue.global(qos: .utility).async { @Sendable [weak self, handler, maxRequestBytes] in
                    do {
                        let line = try UnixSocketIO.readLine(from: fd, limit: maxRequestBytes)
                        Task { @Sendable [weak self, handler] in
                            var reply = await handler(line, peer)
                            reply.append(10)
                            // Blocking socket I/O stays off Swift's cooperative executor.
                            DispatchQueue.global(qos: .utility).async { @Sendable [weak self, reply] in
                                try? UnixSocketIO.write(reply, to: fd)
                                if let self { finish(fd) } else { Darwin.close(fd) }
                            }
                        }
                    } catch {
                        if let self { finish(fd) } else { Darwin.close(fd) }
                    }
                }
            }
        }
    }

    private func finish(_ fd: Int32) {
        lock.withLock {
            clients.remove(fd)
            Darwin.close(fd)
        }
    }
}
