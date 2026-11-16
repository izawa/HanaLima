import Darwin
import Foundation

/// What a guest-only network's helper saw (docs/17): counters per connection (a VM's NIC) and for
/// the whole segment, and the packet capture, if any. Written into the status file once a second.
public struct NetworkObservation: Codable, Sendable, Hashable {
    public struct Counter: Codable, Sendable, Hashable {
        public var frames: UInt64 = 0
        /// Ethernet bytes, without the 4-byte length in front of each frame on the socket.
        public var bytes: UInt64 = 0

        public init(frames: UInt64 = 0, bytes: UInt64 = 0) { self.frames = frames; self.bytes = bytes }

        public mutating func add(_ length: Int) { frames += 1; bytes += UInt64(length) }
    }

    /// One connection to the helper: a VM's NIC, identified by the helper's run and the
    /// connection number. The MACs are the source addresses learned on it (labels, not identity).
    public struct Port: Codable, Sendable, Hashable, Identifiable {
        public var id: Int
        public var macs: [String]
        public var connectedAt: Date
        public var connected: Bool
        /// Frames the guest sent (before any checks or the helper's own answers).
        public var fromGuest = Counter()
        /// Frames written in full to the guest's socket (not proof the guest processed them).
        public var toGuest = Counter()
        /// Frames for this guest dropped because its send queue was full.
        public var droppedFull = Counter()
        /// Frames for this guest dropped because it was disconnecting, or cut short while written.
        public var droppedClosed = Counter()
        /// Frames from this guest shorter than an Ethernet header (also in `fromGuest`).
        public var malformed: UInt64 = 0

        public init(id: Int, macs: [String] = [], connectedAt: Date, connected: Bool = true) {
            self.id = id; self.macs = macs; self.connectedAt = connectedAt; self.connected = connected
        }
    }

    public struct Capture: Codable, Sendable, Hashable {
        public var id: String
        /// The finished file (`.pcap`); `<file>.partial` while it is written.
        public var file: String
        public var startedAt: Date
        public var frames: UInt64 = 0
        public var bytes: UInt64 = 0
        /// Frames not recorded because the capture's buffer was full (forwarding went on).
        public var lost: UInt64 = 0
        public var endedAt: Date?
        /// Why it ended: "stopped", "size limit", "time limit", "write failed: …", "helper exited".
        public var reason: String?

        public init(id: String, file: String, startedAt: Date) { self.id = id; self.file = file; self.startedAt = startedAt }
    }

    /// Changes every time the helper starts: counters restart from zero then.
    public var runID: String
    public var sequence: UInt64
    public var sampledAt: Date
    /// Seconds since the helper started, from a monotonic clock (for rates).
    public var uptime: Double
    /// Connected ports, then up to `keepClosed` recently disconnected ones.
    public var ports: [Port]
    /// Frames the helper itself answered with (DHCP, ARP, DNS).
    public var answered = Counter()
    /// Frames sent to every other port (broadcast, multicast, unknown destination).
    public var flooded: UInt64 = 0
    /// Frames with nobody to deliver them to.
    public var undelivered: UInt64 = 0
    /// The capture running now, or the last one.
    public var capture: Capture?

    public static let keepClosed = 32

    public init(runID: String, sequence: UInt64, sampledAt: Date, uptime: Double, ports: [Port]) {
        self.runID = runID; self.sequence = sequence; self.sampledAt = sampledAt; self.uptime = uptime; self.ports = ports
    }

    /// Per-second rates between two samples of the same run (nil across a restart).
    public static func rate(_ new: Counter, _ old: Counter, seconds: Double) -> (frames: Double, bytes: Double)? {
        guard seconds > 0, new.frames >= old.frames, new.bytes >= old.bytes else { return nil }
        return (Double(new.frames - old.frames) / seconds, Double(new.bytes - old.bytes) / seconds)
    }
}

// MARK: - pcap

/// The classic pcap file format (libpcap's savefile): little-endian, microsecond timestamps,
/// Ethernet frames.
public enum PcapFormat {
    public static let snaplen: UInt32 = 65536
    static let linktypeEthernet: UInt32 = 1

    public static func fileHeader() -> Data {
        var d = Data()
        d.append(le: UInt32(0xA1B2_C3D4))  // magic: microseconds
        d.append(le: UInt16(2))
        d.append(le: UInt16(4))
        d.append(le: Int32(0))            // thiszone
        d.append(le: UInt32(0))           // sigfigs
        d.append(le: snaplen)
        d.append(le: linktypeEthernet)
        return d
    }

    public static func record(_ frame: UnsafeRawBufferPointer, at time: Date) -> Data {
        let seconds = time.timeIntervalSince1970
        let whole = floor(seconds)
        let kept = min(frame.count, Int(snaplen))
        var d = Data(capacity: 16 + kept)
        d.append(le: UInt32(whole))
        d.append(le: UInt32((seconds - whole) * 1_000_000))
        d.append(le: UInt32(kept))
        d.append(le: UInt32(frame.count))
        d.append(contentsOf: UnsafeRawBufferPointer(rebasing: frame[0..<kept]))
        return d
    }
}

/// A capture's bounded buffer between forwarding and the file: `offer` never blocks; a record
/// that doesn't fit is lost (and counted), and forwarding goes on.
public final class CaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var records: [Data] = []
    private var buffered = 0
    private var closed = false
    public let capacity: Int
    private var dropped: UInt64 = 0
    /// Records refused because the buffer was full or closed.
    public var lost: UInt64 { lock.withLock { dropped } }

    public init(capacity: Int) { self.capacity = capacity }

    /// False when the record was dropped (full or closed).
    @discardableResult
    public func offer(_ record: Data) -> Bool {
        let accepted: Bool = lock.withLock {
            guard !closed, buffered + record.count <= capacity else { dropped += 1; return false }
            records.append(record)
            buffered += record.count
            return true
        }
        if accepted { ready.signal() }
        return accepted
    }

    /// The next records to write, waiting for some; nil once closed and drained.
    public func take() -> [Data]? {
        while true {
            let batch: [Data]? = lock.withLock {
                if !records.isEmpty {
                    let out = records
                    records = []
                    buffered = 0
                    return out
                }
                return closed ? nil : []
            }
            guard let batch else { return nil }
            if !batch.isEmpty { return batch }
            ready.wait()
        }
    }

    /// No more records; what's buffered is still handed out.
    public func close() {
        lock.withLock { closed = true }
        ready.signal()
    }
}

// MARK: - Control socket

/// The helper's control socket for guest-only networks (docs/17): one JSON line each way.
public enum NetdControl {
    public struct Request: Codable, Sendable {
        public enum Op: String, Codable, Sendable { case status, startCapture, stopCapture }
        public var op: Op
        /// For stopCapture: the capture to stop.
        public var capture: String?

        public init(op: Op, capture: String? = nil) { self.op = op; self.capture = capture }
    }

    public struct Response: Codable, Sendable {
        public var ok: Bool
        public var error: String?
        public var capture: NetworkObservation.Capture?

        public init(ok: Bool, error: String? = nil, capture: NetworkObservation.Capture? = nil) {
            self.ok = ok; self.error = error; self.capture = capture
        }
    }

    public struct Failure: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }

        public init(message: String) { self.message = message }
    }

    /// Captures are limited to this size or `maxCaptureTime`, whichever comes first.
    public static let maxCaptureBytes = 64 << 20
    public static let maxCaptureTime: TimeInterval = 300
    public static let captureBufferBytes = 8 << 20

    public static func send(_ request: Request, to socketPath: String, timeout: TimeInterval = 10) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reply = try exchange(try encoder.encode(request), socketPath: socketPath, timeout: timeout)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(Response.self, from: reply)
        guard response.ok else { throw Failure(message: response.error ?? "the helper refused the request") }
        return response
    }

    /// One line in, one line out, over a unix stream socket.
    static func exchange(_ line: Data, socketPath: String, timeout: TimeInterval) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure(message: "socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Failure(message: "the helper isn't listening (\(String(cString: strerror(errno))))") }
        let out = [UInt8](line) + [10]
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, out.count - sent, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw Failure(message: "write to the helper failed") }
            sent += n
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            received.append(contentsOf: buffer[0..<n])
            if let end = received.firstIndex(of: 10) { return received[..<end] }
        }
        guard !received.isEmpty else { throw Failure(message: "the helper closed the connection") }
        return received
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
