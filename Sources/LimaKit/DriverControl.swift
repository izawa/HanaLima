import Darwin
import Foundation

/// HanaLima's side channel to its own Lima driver (`lima-driver-hanalima`, docs/09): what Lima's
/// driver interface has no call for. The driver listens on `<instance dir>/hanalima-ctl.sock`
/// while it runs; one request per connection, a JSON object and a newline each way.
///
/// Lima 2.2.1 can't show or capture an external driver's screen (its `RunGUI` call times out
/// after 10 s and `limactl screenshot` only reaches internal drivers), so the driver owns the
/// window and these calls open and capture it.
public enum DriverControl {
    public static let socketName = "hanalima-ctl.sock"
    /// The guest's virtio console, both ways (Lima's QEMU driver uses the same name).
    public static let serialSocketName = "serialv.sock"

    public enum Op: String, Codable, Sendable {
        /// What the driver is doing; answers `state` and `display`.
        case status
        /// Shows the VM's window (and brings it to the front).
        case openScreen
        /// A PNG of the VM's window; fails while the window is hidden.
        case screenshot
        /// Asks the guest to power off (ACPI); the driver pulls the plug after a while.
        case stop
        /// Pulls the plug now.
        case forceStop
    }

    /// The pid file of a hosted boot (`lima-driver-hanalima --hosted`: the rescue boot and the
    /// installer), distinct from `hanalima.pid` so Lima doesn't take the VM for one of its own.
    public static let hostedPIDName = "hanalima-hosted.pid"

    /// The pid of a hosted boot of `instanceDir` that is still alive, if any. The number is
    /// trusted only if that process is the driver booting this very directory (a pid file left
    /// by a crash may by now belong to anything).
    public static func hostedPID(instanceDir: URL) -> Int32? {
        guard let text = try? String(contentsOf: instanceDir.appending(path: hostedPIDName), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, kill(pid, 0) == 0 else { return nil }
        let command = commandLine(of: pid)
        guard command.contains("lima-driver-hanalima"), command.contains("--hosted"),
              command.contains(instanceDir.path.hasSuffix("/") ? String(instanceDir.path.dropLast()) : instanceDir.path) else { return nil }
        return pid
    }

    static func commandLine(of pid: Int32) -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", "\(pid)"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return "" }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }

    public struct Request: Codable, Sendable {
        public var op: Op
        public init(op: Op) { self.op = op }
    }

    public struct Response: Codable, Sendable {
        public var ok: Bool
        public var error: String?
        /// VZ's state name: "running", "stopped", "paused"…, or "none" before Start.
        public var state: String?
        /// Whether the VM has a display (video.display other than "none").
        public var display: Bool?
        /// Whether the window is on screen now.
        public var screenShown: Bool?
        public var png: Data?

        public init(ok: Bool, error: String? = nil, state: String? = nil, display: Bool? = nil,
                    screenShown: Bool? = nil, png: Data? = nil) {
            self.ok = ok
            self.error = error
            self.state = state
            self.display = display
            self.screenShown = screenShown
            self.png = png
        }

        public static func failure(_ message: String) -> Response { Response(ok: false, error: message) }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public static func socketPath(instanceDir: URL) -> String { instanceDir.appending(path: socketName).path }

    /// Whether the driver's control socket exists (it does only while the driver runs).
    public static func isAvailable(instanceDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: socketPath(instanceDir: instanceDir))
    }

    /// Sends one request and waits for the answer (blocking; call off the main thread). A
    /// response with `ok == false` is thrown as `Failure`.
    public static func send(_ request: Request, instanceDir: URL, timeout: TimeInterval = 10) throws -> Response {
        let response = try exchange(try JSONEncoder().encode(request), socketPath: socketPath(instanceDir: instanceDir), timeout: timeout)
        let decoded = try JSONDecoder().decode(Response.self, from: response)
        guard decoded.ok else { throw Failure(decoded.error ?? "the driver refused the request") }
        return decoded
    }

    public static func screenshot(instanceDir: URL) throws -> Data {
        guard let png = try send(Request(op: .screenshot), instanceDir: instanceDir).png else {
            throw Failure("the driver sent no image")
        }
        return png
    }

    /// One line in, one line out, over a unix stream socket.
    static func exchange(_ line: Data, socketPath: String, timeout: TimeInterval) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure("socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Failure("the driver isn't listening (\(String(cString: strerror(errno))))") }

        let out = [UInt8](line) + [10]
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, out.count - sent, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw Failure("write to the driver failed") }
            sent += n
        }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else {
                if received.isEmpty { throw Failure(n == 0 ? "the driver closed the connection" : "no answer from the driver in \(Int(timeout)) s") }
                return received
            }
            received.append(contentsOf: buffer[0..<n])
            if buffer[n - 1] == 10 { return received }
        }
    }
}
