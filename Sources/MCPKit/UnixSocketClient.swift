import Foundation
import Darwin

public enum UnixSocketClient {
    public typealias Error = UnixSocketError

    /// The deadline covers connect, the complete write, and the complete reply, even for trickle traffic.
    public static func request(path: String, line: Data, timeout: TimeInterval) throws -> Data {
        var address = try UnixSocketIO.address(path)
        let fd = try UnixSocketIO.socket()
        defer { Darwin.close(fd) }
        guard timeout.isFinite, timeout > 0 else { throw UnixSocketError.timeout }
        let nanoseconds = UInt64(min(timeout * 1_000_000_000, Double(UInt64.max / 2)))
        let deadline = DispatchTime.now().uptimeNanoseconds &+ nanoseconds
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw UnixSocketError.system(errno) }
        let connected = UnixSocketIO.withAddress(&address) { Darwin.connect(fd, $0, $1) }
        if connected != 0 {
            let code = errno
            if code == ENOENT || code == ECONNREFUSED { throw UnixSocketError.notListening }
            guard code == EINPROGRESS || code == EAGAIN || code == EINTR else { throw UnixSocketError.system(code) }
            try UnixSocketIO.wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { throw UnixSocketError.system(errno) }
            if error == ENOENT || error == ECONNREFUSED { throw UnixSocketError.notListening }
            guard error == 0 else { throw UnixSocketError.system(error) }
        }
        // Once sending starts, failures must never cause an automatic retry of a possibly applied call.
        var framed = line
        framed.append(10)
        try UnixSocketIO.write(framed, to: fd, deadline: deadline)
        return try UnixSocketIO.readLine(from: fd, deadline: deadline)
    }
}
