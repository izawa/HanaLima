import Darwin
import Foundation
import NetworkKit

/// One packet capture of a guest-only segment (docs/17): forwarding offers each frame and never
/// waits; a writer thread drains the bounded buffer into `<file>.partial`, which becomes the
/// `.pcap` (with a small summary next to it) when the capture ends.
final class CaptureSession: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer = CaptureBuffer(capacity: NetdControl.captureBufferBytes)
    private let started = ContinuousClock.now
    private var state: NetworkObservation.Capture
    /// Bytes of the file so far, counting the header and every record admitted.
    private var reserved = PcapFormat.fileHeader().count
    /// Set when writing fails, also after the capture already ended (it then wins the reason).
    private var writeError: String?
    private var ended = false
    private let finished = DispatchSemaphore(value: 0)
    private let fd: Int32
    private let finalURL: URL
    private let partialURL: URL

    /// Creates the file with the pcap header and starts the writer.
    static func start(network: String) throws -> CaptureSession {
        let fm = FileManager.default
        let dir = NetworkPaths.capturesDirectory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let finalURL = dir.appending(path: "\(network)-\(formatter.string(from: .now))-\(id).pcap")
        let partialURL = URL(filePath: finalURL.path + ".partial")
        let fd = open(partialURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw NetdControl.Failure(message: "can't create \(partialURL.path): \(String(cString: strerror(errno)))") }
        let header = PcapFormat.fileHeader()
        guard header.withUnsafeBytes({ writeFully(fd, $0.baseAddress!, $0.count) }) else {
            close(fd)
            unlink(partialURL.path)
            throw NetdControl.Failure(message: "can't write \(partialURL.path)")
        }
        let session = CaptureSession(id: id, fd: fd, finalURL: finalURL, partialURL: partialURL)
        Thread.detachNewThread { session.writeLoop() }
        return session
    }

    private init(id: String, fd: Int32, finalURL: URL, partialURL: URL) {
        self.fd = fd
        self.finalURL = finalURL
        self.partialURL = partialURL
        state = NetworkObservation.Capture(id: id, file: finalURL.path, startedAt: .now)
    }

    var id: String { state.id }
    var snapshot: NetworkObservation.Capture {
        lock.withLock { var s = state; s.lost = buffer.lost; return s }
    }
    var isRunning: Bool { lock.withLock { !ended } }

    /// Records one frame, unless the capture ended or its buffer is full. Never blocks.
    func offer(_ frame: UnsafeRawBufferPointer) {
        guard isRunning else { return }  // an ended capture records nothing more (nor counts it lost)
        let record = PcapFormat.record(frame, at: .now)
        // Checked and reserved in one step, so concurrent senders can't overshoot the limit.
        let fits: Bool = lock.withLock {
            guard !ended, reserved + record.count <= NetdControl.maxCaptureBytes else { return false }
            reserved += record.count
            return true
        }
        guard fits else { stop("size limit"); return }
        let admitted = buffer.offer(record)
        lock.withLock {
            if admitted {
                state.frames += 1
                state.bytes += UInt64(record.count)
            } else {
                reserved -= record.count
            }
        }
    }

    func checkTime() {
        if ContinuousClock.now - started > .seconds(NetdControl.maxCaptureTime) { stop("time limit") }
    }

    /// Ends the capture (the first reason wins); the writer finishes the file.
    func stop(_ reason: String) {
        let first: Bool = lock.withLock {
            guard !ended else { return false }
            ended = true
            state.reason = reason
            return true
        }
        if first { buffer.close() }
    }

    /// Waits for the file to be finished, at most `timeout` seconds.
    func waitFinished(timeout: TimeInterval) { _ = finished.wait(timeout: .now() + timeout) }

    private func writeLoop() {
        defer { finished.signal() }
        var failed: String?
        while let batch = buffer.take() {
            guard failed == nil else { continue }  // drain without writing
            for record in batch where failed == nil {
                if !record.withUnsafeBytes({ writeFully(fd, $0.baseAddress!, $0.count) }) {
                    failed = String(cString: strerror(errno))
                }
            }
            if let failed {
                lock.withLock { writeError = failed }
                stop("write failed: \(failed)")
            }
        }
        close(fd)
        rename(partialURL.path, finalURL.path)
        let summary: NetworkObservation.Capture = lock.withLock {
            if let writeError { state.reason = "write failed: \(writeError)" }  // even after a stop
            state.endedAt = .now
            state.lost = buffer.lost
            return state
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(summary) {
            let url = URL(filePath: finalURL.path + ".json")
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        log("capture \(summary.id) ended (\(summary.reason ?? "?")): \(summary.frames) frames, \(summary.lost) lost")
    }
}

// MARK: - Control socket

/// Answers the app on the control socket: one JSON request per connection, from the same user only.
func serveControl(_ listener: Int32, guestSwitch: GuestSwitch, network: String) {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    while true {
        let fd = accept(listener, nil, nil)
        if fd < 0 {
            if errno == EINTR { continue }
            log("control accept: \(String(cString: strerror(errno)))")
            return
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var uid: uid_t = 0, gid: gid_t = 0
        let response: NetdControl.Response
        if getpeereid(fd, &uid, &gid) != 0 || uid != getuid() {
            response = .init(ok: false, error: "not allowed")
        } else if let line = readLine(fd, limit: 4096), let request = try? decoder.decode(NetdControl.Request.self, from: line) {
            response = handle(request, guestSwitch: guestSwitch, network: network)
        } else {
            response = .init(ok: false, error: "bad request")
        }
        if var data = try? encoder.encode(response) {
            data.append(10)
            _ = data.withUnsafeBytes { writeFully(fd, $0.baseAddress!, $0.count) }
        }
        close(fd)
    }
}

private func handle(_ request: NetdControl.Request, guestSwitch: GuestSwitch, network: String) -> NetdControl.Response {
    switch request.op {
    case .status:
        return .init(ok: true, capture: guestSwitch.captureState)
    case .startCapture:
        do {
            return .init(ok: true, capture: try guestSwitch.startCapture(network: network))
        } catch {
            return .init(ok: false, error: error.localizedDescription)
        }
    case .stopCapture:
        guard let capture = guestSwitch.stopCapture(id: request.capture) else {
            return .init(ok: false, error: "no such capture running")
        }
        return .init(ok: true, capture: capture)
    }
}

private func readLine(_ fd: Int32, limit: Int) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < limit {
        let n = read(fd, &byte, 1)
        if n < 0 && errno == EINTR { continue }
        guard n == 1 else { break }
        if byte == 10 { return data }
        data.append(byte)
    }
    return data.isEmpty ? nil : data
}
