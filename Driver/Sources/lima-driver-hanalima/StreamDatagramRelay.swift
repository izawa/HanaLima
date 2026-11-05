import Darwin
import Foundation

/// Connects to a QEMU/socket_vmnet stream socket (HanaLima's netd speaks it: each Ethernet
/// frame is a 4-byte big-endian length and the frame) and returns the local end of a datagram
/// socket pair for `VZFileHandleNetworkDeviceAttachment`, which wants one frame per datagram.
/// Two threads relay in each direction, as Lima's `DialQemu` does. Closing the returned handle
/// ends the relay and the stream connection.
func connectQemuStreamSocket(path: String) throws -> FileHandle {
    let stream = socket(AF_UNIX, SOCK_STREAM, 0)
    guard stream >= 0 else { throw DriverError("socket: \(String(cString: strerror(errno)))") }
    var on: Int32 = 1
    setsockopt(stream, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(stream); throw DriverError("socket path too long: \(path)") }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(stream, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
        let err = errno
        close(stream)
        throw DriverError("connect to \(path): \(String(cString: strerror(err)))")
    }
    do {
        let pair = try makeDatagramSocketPair()  // FDPassing.swift: 1 MiB / 4 MiB buffers
        let remote = dup(pair.remote.fileDescriptor)
        guard remote >= 0 else { throw DriverError("dup failed (errno \(errno))") }
        let relay = StreamDatagramRelay(stream: stream, datagram: remote)
        try pair.remote.close()
        relay.start()
        return pair.local
    } catch {
        close(stream)
        throw error
    }
}

private final class StreamDatagramRelay: @unchecked Sendable {
    private let stream: Int32
    private let datagram: Int32
    private let lock = NSLock()
    private var stopped = false
    private var running = 2

    init(stream: Int32, datagram: Int32) {
        self.stream = stream
        self.datagram = datagram
        var on: Int32 = 1
        setsockopt(datagram, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        Thread.detachNewThread { self.datagramsToStream() }
        Thread.detachNewThread { self.streamToDatagrams() }
    }

    /// Either direction ending ends both; the descriptors close once both threads are done.
    private func finish() {
        lock.lock()
        if !stopped {
            stopped = true
            shutdown(stream, SHUT_RDWR)
            shutdown(datagram, SHUT_RDWR)
        }
        running -= 1
        if running == 0 {
            close(stream)
            close(datagram)
        }
        lock.unlock()
    }

    private func datagramsToStream() {
        defer { finish() }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(datagram, $0.baseAddress, $0.count, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }  // 0: the VM closed its end
            var header = [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
            guard writeAll(stream, &header, 4), writeAll(stream, &buffer, n) else { return }
        }
    }

    private func streamToDatagrams() {
        defer { finish() }
        var header = [UInt8](repeating: 0, count: 4)
        var frame = [UInt8](repeating: 0, count: 65536)
        while true {
            guard readAll(stream, &header, 4) else { return }
            let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard length <= frame.count, readAll(stream, &frame, length) else { return }
            while true {
                let n = frame.withUnsafeBytes { send(datagram, $0.baseAddress, length, 0) }
                if n == length { break }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == ENOBUFS { usleep(1000); continue }  // the VM is slow to read
                return
            }
        }
    }

    private func readAll(_ fd: Int32, _ buffer: inout [UInt8], _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + done, count - done, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return false }
            done += n
        }
        return true
    }

    private func writeAll(_ fd: Int32, _ buffer: inout [UInt8], _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = buffer.withUnsafeBytes { send(fd, $0.baseAddress! + done, count - done, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return false }
            done += n
        }
        return true
    }
}
