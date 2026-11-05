import Darwin
import Foundation
import LimaKit

/// `hanalima-ctl.sock` in the instance directory: HanaLima's own requests to the driver
/// (`DriverControl` in LimaKit). One JSON line in, one out, per connection; each request is
/// answered by `handler` off this thread.
final class ControlServer: @unchecked Sendable {
    private let listener: Int32
    private let path: String
    private let handler: @Sendable (DriverControl.Request) async -> DriverControl.Response

    init(path: String, handler: @escaping @Sendable (DriverControl.Request) async -> DriverControl.Response) throws {
        self.path = path
        self.handler = handler
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
        guard bound == 0, listen(fd, 8) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw DriverError("listen on \(path): \(String(cString: strerror(err)))")
        }
        chmod(path, 0o600)
        listener = fd
        Thread.detachNewThread { self.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            Thread.detachNewThread { self.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { Darwin.close(client) }
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !line.contains(10), line.count < 65536 {
            let n = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            line.append(contentsOf: buffer[0..<n])
        }
        let response: DriverControl.Response
        if let request = try? JSONDecoder().decode(DriverControl.Request.self, from: line) {
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result = DriverControl.Response.failure("no answer")
            let handler = handler
            Task.detached {
                result = await handler(request)
                done.signal()
            }
            done.wait()
            response = result
        } else {
            response = .failure("unknown request")
        }
        guard var out = try? JSONEncoder().encode(response) else { return }
        out.append(10)
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { send(client, $0.baseAddress! + sent, out.count - sent, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            sent += n
        }
    }

    func close() {
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(path)
    }
}
