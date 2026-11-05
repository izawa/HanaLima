import Darwin
import Foundation

/// The guest's virtio console, both ways. VZ gets one end of a stream socket pair; this end is
/// relayed to `serialv.log` (what Lima's vz driver writes, and the app's log tab follows) and to
/// whoever connects to `serialv.sock` (the name Lima's QEMU driver gives its virtio console
/// socket). Bytes from a connected client go to the guest, so a getty on hvc0 gives a login.
final class SerialConsole: @unchecked Sendable {
    /// VZ's end of the pair (reading and writing). Closed by `close()`.
    let guestHandle: FileHandle
    private let host: Int32
    private let listener: Int32
    private let socketPath: String
    private let log: FileHandle
    private let lock = NSLock()
    /// Connected clients. A descriptor is closed only by the thread that reads it, under the
    /// lock, so a broadcast (also under the lock) never writes to a reused number.
    private var clients: [Int32] = []
    private var closed = false

    init(logURL: URL, socketPath: String) throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw DriverError("socketpair: \(String(cString: strerror(errno)))") }
        for fd in pair {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        // Lima recreates the log on every boot.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else {
            Darwin.close(pair[0]); Darwin.close(pair[1])
            throw DriverError("can't write \(logURL.path)")
        }
        try? log.truncate(atOffset: 0)
        self.log = log
        self.socketPath = socketPath
        do {
            listener = try Self.listen(at: socketPath)
        } catch {
            Darwin.close(pair[0]); Darwin.close(pair[1])
            try? log.close()
            throw error
        }
        guestHandle = FileHandle(fileDescriptor: pair[0], closeOnDealloc: false)
        host = pair[1]
        Thread.detachNewThread { self.relayGuestOutput() }
        Thread.detachNewThread { self.acceptClients() }
    }

    private static func listen(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DriverError("socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); throw DriverError("socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            let err = errno
            Darwin.close(fd)
            if bound == 0 { unlink(path) }
            throw DriverError("listen on \(path): \(String(cString: strerror(err)))")
        }
        chmod(path, 0o600)
        return fd
    }

    /// Guest → log and every client. A client that can't keep up is dropped rather than
    /// stalling the console (the sends don't block; the log never blocks for long).
    private func relayGuestOutput() {
        defer { Darwin.close(host) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(host, $0.baseAddress, $0.count, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            let chunk = Data(buffer[0..<n])
            try? log.write(contentsOf: chunk)
            lock.lock()
            for client in clients {
                let sent = chunk.withUnsafeBytes { send(client, $0.baseAddress, n, MSG_DONTWAIT) }
                if sent != n { shutdown(client, SHUT_RDWR) }  // its reader thread ends and closes it
            }
            lock.unlock()
        }
    }

    private func acceptClients() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // the listener was closed (on macOS only close wakes accept)
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            if closed { lock.unlock(); Darwin.close(client); return }
            clients.append(client)
            lock.unlock()
            Thread.detachNewThread { self.relayClientInput(client) }
        }
    }

    /// Client → guest. This thread owns the client's descriptor: it's closed here, once the
    /// client hangs up or someone shut it down.
    private func relayClientInput(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            var done = 0
            while done < n {
                let w = buffer.withUnsafeBytes { send(host, $0.baseAddress! + done, n - done, 0) }
                if w < 0 && errno == EINTR { continue }
                guard w > 0 else { break }
                done += w
            }
        }
        lock.lock()
        clients.removeAll { $0 == client }
        Darwin.close(client)
        lock.unlock()
    }

    /// Ends the relays and removes the socket. Descriptors are shut down here and closed by
    /// the threads that own them; the guest's end is closed too (the VM is gone).
    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        for client in clients { shutdown(client, SHUT_RDWR) }
        lock.unlock()
        Darwin.close(listener)  // shutdown doesn't wake accept on macOS; this does
        unlink(socketPath)
        shutdown(host, SHUT_RDWR)
        try? guestHandle.close()
        try? log.close()
    }
}
