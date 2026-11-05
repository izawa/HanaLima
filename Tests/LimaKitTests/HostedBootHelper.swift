import Foundation
@testable import LimaKit

/// Drives `lima-driver-hanalima --hosted` (the rescue boot and the installer outside Lima) from
/// a test: launches it headless, waits for its control socket, asks it to stop, waits for exit.
final class HostedBoot {
    static let driver = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/Helpers/lima-driver-hanalima")

    let dir: URL
    let process = Process()
    let log: URL

    /// `options` are the driver's own flags after `--hosted <dir> --cpus --memory --headless`.
    init(dir: URL, cpus: Int = 2, memoryGiB: Int = 2, options: [String]) throws {
        self.dir = dir
        log = FileManager.default.temporaryDirectory.appending(path: "hanalima-hosted-\(dir.lastPathComponent).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.executableURL = Self.driver
        process.arguments = ["--hosted", dir.path, "--cpus", "\(cpus)", "--memory", "\(UInt64(memoryGiB) << 30)", "--headless"] + options
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: log)
        try process.run()
    }

    var isRunning: Bool { process.isRunning }
    var logText: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    /// True once the driver reports the VM running (its control socket answers).
    func waitUntilRunning(timeout: TimeInterval = 120) async -> Bool {
        let started = Date.now
        while Date.now.timeIntervalSince(started) < timeout, process.isRunning {
            if let status = try? DriverControl.send(DriverControl.Request(op: .status), instanceDir: dir, timeout: 3),
               status.state == "running" { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Whether the guest answers on `port` through the hosted boot's usernet. usernet's
    /// `wait_port` answers 408 after its timeout while the port is closed; once it opens, the
    /// reply is 200 or the connection just closes.
    func usernetPortOpen(_ port: Int, guestIP: String = "192.168.5.15") -> Bool {
        let path = dir.appending(path: "default_ep.sock").path
        guard let status = try? unixHTTPStatus(socketPath: path, path: "/extension/wait_port?ip=\(guestIP)&port=\(port)&timeout=3", timeout: 5) else { return false }
        return status == 200 || status == 0
    }

    func stop(force: Bool = false) {
        _ = try? DriverControl.send(DriverControl.Request(op: force ? .forceStop : .stop), instanceDir: dir, timeout: 5)
    }

    /// Waits for the driver to exit; forces the VM off after `timeout`, SIGTERMs it 30 s later,
    /// and gives up (-1) 30 s after that.
    func waitForExit(timeout: TimeInterval = 60) async -> Int32 {
        let started = Date.now
        while process.isRunning {
            let elapsed = Date.now.timeIntervalSince(started)
            if elapsed > timeout + 60 { return -1 }
            if elapsed > timeout + 30 { process.terminate() } else if elapsed > timeout { stop(force: true) }
            try? await Task.sleep(for: .seconds(1))
        }
        return process.terminationStatus
    }
}

/// A one-shot HTTP/1.0 GET over a unix socket; returns the body (empty if the server just closes).
func unixHTTPGet(socketPath: String, path: String, timeout: Int = 5) throws -> String {
    try unixHTTPExchange(socketPath: socketPath, path: path, timeout: timeout).body
}

/// The status code of a one-shot GET (0 when the server closed without a status line).
func unixHTTPStatus(socketPath: String, path: String, timeout: Int = 5) throws -> Int {
    try unixHTTPExchange(socketPath: socketPath, path: path, timeout: timeout).status
}

func unixHTTPExchange(socketPath: String, path: String, timeout: Int) throws -> (status: Int, body: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DriverControl.Failure("socket") }
    defer { close(fd) }
    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw DriverControl.Failure("connect: \(String(cString: strerror(errno)))") }
    let request = [UInt8]("GET \(path) HTTP/1.0\r\nHost: lima\r\n\r\n".utf8)
    _ = request.withUnsafeBytes { send(fd, $0.baseAddress, request.count, 0) }
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if n > 0 { received.append(contentsOf: buffer[0..<n]) } else {
            if n < 0 { throw DriverControl.Failure("timed out") }
            break
        }
    }
    let text = String(decoding: received, as: UTF8.self)
    let status = text.hasPrefix("HTTP/") ? Int(text.split(separator: " ", maxSplits: 2).dropFirst().first ?? "") ?? 0 : 0
    return (status, text.components(separatedBy: "\r\n\r\n").dropFirst().joined().trimmingCharacters(in: .whitespacesAndNewlines))
}
