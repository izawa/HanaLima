import Foundation
import Darwin

private func bridgeError(_ operation: String, _ code: Int32 = errno) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"])
}

private func bridgeAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8) + [0]
    guard !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw bridgeError("Unix socket path", ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}

private func bridgeNoSIGPIPE(_ fd: Int32) throws {
    var enabled: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw bridgeError("SO_NOSIGPIPE")
    }
}

private final class BridgeJob<T: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<T, Error>?

    init(_ work: @escaping @Sendable () throws -> T) {
        Thread.detachNewThread {
            let result = Result { try work() }
            self.condition.lock()
            self.result = result
            self.condition.broadcast()
            self.condition.unlock()
        }
    }

    func wait() throws -> T {
        condition.lock()
        defer { condition.unlock() }
        while result == nil { condition.wait() }
        return try result!.get()
    }
}

private func bridgeWriteAll(_ fd: Int32, _ bytes: [UInt8]) throws {
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
        if n < 0 {
            if errno == EINTR { continue }
            throw bridgeError("send")
        }
        guard n > 0 else { throw bridgeError("Zero-length write", EIO) }
        offset += n
    }
}

private final class BridgeConnection: @unchecked Sendable {
    private let condition = NSCondition()
    private let client: Int32
    private var peer: Int32 = -1
    private var stopped = false
    private var closed = false
    private var workers = 0
    private let onClose: @Sendable () -> Void

    init(client: Int32, onClose: @escaping @Sendable () -> Void) {
        self.client = client
        self.onClose = onClose
    }

    func start(peer: Int32) {
        condition.lock()
        if stopped {
            condition.unlock()
            Darwin.close(peer)
            return
        }
        self.peer = peer
        workers = 2
        Thread.detachNewThread { self.copy(from: self.client, to: peer) }
        Thread.detachNewThread { self.copy(from: peer, to: self.client) }
        condition.unlock()
    }

    private func stopLocked() {
        if !stopped {
            stopped = true
            shutdown(client, SHUT_RDWR)
            if peer >= 0 { shutdown(peer, SHUT_RDWR) }
        }
    }

    private func closeLocked() {
        Darwin.close(client)
        if peer >= 0 { Darwin.close(peer) }
        closed = true
        condition.broadcast()
    }

    func stop() {
        condition.lock()
        stopLocked()
        let finish = workers == 0 && !closed
        if finish { closeLocked() }
        condition.unlock()
        if finish { onClose() }
    }

    func waitClosed() {
        condition.lock()
        while !closed { condition.wait() }
        condition.unlock()
    }

    private func copy(from source: Int32, to destination: Int32) {
        defer {
            condition.lock()
            stopLocked()
            workers -= 1
            let finish = workers == 0
            if finish { closeLocked() }
            condition.unlock()
            if finish { onClose() }
        }
        var buffer = [UInt8](repeating: 0, count: 65536)
        do {
            while true {
                let n = buffer.withUnsafeMutableBytes { recv(source, $0.baseAddress, $0.count, 0) }
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return }
                try bridgeWriteAll(destination, Array(buffer.prefix(n)))
            }
        } catch { /* Both directions are stopped in defer. */ }
    }
}

private final class BridgeState: @unchecked Sendable {
    let lock = NSLock()
    var listener: Int32
    var connections: [UUID: BridgeConnection] = [:]
    let path: String
    let connectPeer: @Sendable () throws -> Int32

    init(listener: Int32, path: String, connect: @escaping @Sendable () throws -> Int32) {
        self.listener = listener
        self.path = path
        self.connectPeer = connect
    }

    func run() {
        while true {
            lock.lock()
            guard listener >= 0 else { lock.unlock(); return }
            // Nonblocking accept under the lock prevents descriptor reuse races.
            let client = accept(listener, nil, nil)
            let code = errno
            if client < 0 {
                lock.unlock()
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
                close()
                return
            }
            do {
                let flags = fcntl(client, F_GETFL)
                guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
                    throw bridgeError("fcntl accepted socket")
                }
                try bridgeNoSIGPIPE(client)
            } catch {
                Darwin.close(client)
                lock.unlock()
                continue
            }
            let id = UUID()
            let connection = BridgeConnection(client: client) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.connections.removeValue(forKey: id)
                self.lock.unlock()
            }
            connections[id] = connection
            lock.unlock()
            do {
                let peer = try connectPeer()
                do { try bridgeNoSIGPIPE(peer) }
                catch { Darwin.close(peer); throw error }
                connection.start(peer: peer)
            } catch {
                connection.stop()
            }
        }
    }

    func close() {
        lock.lock()
        if listener >= 0 {
            Darwin.close(listener)
            listener = -1
            unlink(path)
        }
        let active = Array(connections.values)
        lock.unlock()
        // Don't wait for the copy threads: a peer that never answers (a vsock whose VM is gone)
        // would hold the driver's teardown.
        active.forEach { $0.stop() }
    }
}

/// Owns a Unix listener and its active bidirectional connections.
/// Synchronous init/close wait for dedicated threads; call outside concurrency tasks.
final class UnixSocketBridge: @unchecked Sendable {
    private let state: BridgeState

    init(path: String, connect: @escaping @Sendable () throws -> Int32) throws {
        state = try BridgeJob {
            var address = try bridgeAddress(path)
            var info = stat()
            if lstat(path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFSOCK else {
                    throw bridgeError("Refusing to remove a non-socket path", EEXIST)
                }
                guard unlink(path) == 0 else { throw bridgeError("unlink stale socket") }
            } else if errno != ENOENT { throw bridgeError("lstat") }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw bridgeError("socket") }
            var bound = false
            do {
                try bridgeNoSIGPIPE(fd)
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard result == 0 else { throw bridgeError("bind") }
                bound = true
                guard chmod(path, 0o600) == 0 else { throw bridgeError("chmod") }
                guard listen(fd, 128) == 0 else { throw bridgeError("listen") }
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw bridgeError("fcntl listener")
                }
                return BridgeState(listener: fd, path: path, connect: connect)
            } catch {
                Darwin.close(fd)
                if bound { unlink(path) }
                throw error
            }
        }.wait()
        let state = state
        Thread.detachNewThread { state.run() }
    }

    func close() {
        let state = state
        _ = try? BridgeJob<Void> { state.close() }.wait()
    }

    deinit { close() }
}

private func bridgeDial(_ path: String) throws -> Int32 {
    var address = try bridgeAddress(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw bridgeError("test socket") }
    do {
        try bridgeNoSIGPIPE(fd)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw bridgeError("test connect") }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    } catch {
        Darwin.close(fd)
        throw error
    }
}

private func bridgeCheck(_ test: Bool, _ message: String) throws {
    if !test { throw NSError(domain: "UnixSocketBridgeSelfTest", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func bridgeTestExchange(_ fd: Int32, _ payload: [UInt8]) throws {
    // Drain echoes while writing so large full-duplex transfers cannot deadlock.
    let writer = BridgeJob<Void> { try bridgeWriteAll(fd, payload) }
    do {
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 32768)
        while received.count < payload.count {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw bridgeError("test client recv", n == 0 ? EPIPE : errno) }
            received.append(contentsOf: buffer.prefix(n))
        }
        try writer.wait()
        try bridgeCheck(received == payload, "Echo payload mismatch")
    } catch {
        shutdown(fd, SHUT_RDWR)
        _ = try? writer.wait()
        throw error
    }
}

func unixSocketBridgeSelfTest() throws {
    try BridgeJob<Void> {
        let directory = "/tmp/bridge-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let echoPath = directory + "/echo"
        let bridgePath = directory + "/bridge"
        var address = try bridgeAddress(echoPath)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw bridgeError("test listener") }
        defer { Darwin.close(listener) }
        try bridgeNoSIGPIPE(listener)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else { throw bridgeError("test listen") }
        let server = BridgeJob<Void> {
            var jobs: [BridgeJob<Void>] = []
            for _ in 0..<6 {
                var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&event, 1, 10000) > 0 else { throw bridgeError("test accept timeout", ETIMEDOUT) }
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { throw bridgeError("test accept") }
                jobs.append(BridgeJob<Void> {
                    defer { Darwin.close(fd) }
                    try bridgeNoSIGPIPE(fd)
                    var timeout = timeval(tv_sec: 10, tv_usec: 0)
                    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    var buffer = [UInt8](repeating: 0, count: 16384)
                    while true {
                        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                        if n < 0, errno == EINTR { continue }
                        if n == 0 { return }
                        if n < 0 { throw bridgeError("test echo recv") }
                        try bridgeWriteAll(fd, Array(buffer.prefix(n)))
                    }
                })
            }
            for job in jobs { try job.wait() }
        }
        defer { _ = try? server.wait() }
        let bridge = try UnixSocketBridge(path: bridgePath) { try bridgeDial(echoPath) }
        defer { bridge.close() }
        let clients = [17, 8192, 200 * 1024].enumerated().map { index, size in
            BridgeJob<Void> {
                let fd = try bridgeDial(bridgePath)
                defer { Darwin.close(fd) }
                let payload = (0..<size).map { UInt8(($0 + index * 41) % 251) }
                try bridgeTestExchange(fd, payload)
            }
        }
        for client in clients { try client.wait() }
        for size in [33, 67] {
            let fd = try bridgeDial(bridgePath)
            defer { Darwin.close(fd) }
            try bridgeTestExchange(fd, [UInt8](repeating: UInt8(size), count: size))
        }
        let active = try bridgeDial(bridgePath)
        defer { Darwin.close(active) }
        try bridgeTestExchange(active, [1, 2, 3])
        bridge.close()
        var byte: UInt8 = 0
        try bridgeCheck(recv(active, &byte, 1, 0) == 0, "Active client did not receive EOF on close")
        try server.wait()
        var info = stat()
        try bridgeCheck(lstat(bridgePath, &info) != 0 && errno == ENOENT, "Bridge path remains")
        do {
            let fd = try bridgeDial(bridgePath)
            Darwin.close(fd)
            throw bridgeError("Connect succeeded after close", EINVAL)
        } catch let error as NSError {
            try bridgeCheck(error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT),
                            "Unexpected error after close: \(error)")
        }
        let rejecting = try UnixSocketBridge(path: directory + "/reject") {
            throw bridgeError("Expected peer failure", ECONNREFUSED)
        }
        defer { rejecting.close() }
        let rejected = try bridgeDial(directory + "/reject")
        defer { Darwin.close(rejected) }
        try bridgeCheck(recv(rejected, &byte, 1, 0) == 0, "Failed peer did not close accepted client")
    }.wait()
}
