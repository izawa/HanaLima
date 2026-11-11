import Foundation
import Darwin

public enum UnixSocketError: Error, Equatable, Sendable, CustomStringConvertible {
    case pathTooLong
    case inUse
    case notListening
    case connectionLost
    case timeout
    case system(Int32)

    public var description: String {
        switch self {
        case .pathTooLong: "Unix socket path exceeds 103 UTF-8 bytes (104 bytes including NUL)."
        case .inUse: "The Unix socket is already in use."
        case .notListening: "HanaLima is not listening."
        case .connectionLost: "The connection to HanaLima was lost."
        case .timeout: "The Unix socket request timed out."
        case .system(let code): "Unix socket error: \(String(cString: strerror(code)))"
        }
    }
}

/// Shared framing and SIGPIPE protection keep the app and helper consistent.
enum UnixSocketIO {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw UnixSocketError.pathTooLong
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes + [0])
        }
        return address
    }

    static func withAddress<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func socket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.system(errno) }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.system(code)
        }
        return fd
    }

    static func protect(_ fd: Int32) -> Bool {
        var one: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0
            && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
            && fcntl(fd, F_SETFL, 0) == 0
    }

    static func wait(_ fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw UnixSocketError.timeout }
            let milliseconds = min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max))
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(milliseconds))
            if result > 0 { return }
            if result == 0 { throw UnixSocketError.timeout }
            if errno != EINTR { throw UnixSocketError.system(errno) }
        }
    }

    static func write(_ data: Data, to fd: Int32, deadline: UInt64? = nil) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                if let deadline { try wait(fd, events: Int16(POLLOUT), deadline: deadline) }
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count > 0 { offset += count }
                else if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                else { throw UnixSocketError.connectionLost }
            }
        }
    }

    static func readLine(from fd: Int32, limit: Int = Int.max, deadline: UInt64? = nil) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            if let deadline { try wait(fd, events: Int16(POLLIN), deadline: deadline) }
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw UnixSocketError.connectionLost }
            let end = buffer[..<count].firstIndex(of: 10)
            let length = end ?? count
            guard length <= limit - result.count else { throw UnixSocketError.connectionLost }
            result.append(contentsOf: buffer[..<length])
            if end != nil { return result }
        }
    }
}
