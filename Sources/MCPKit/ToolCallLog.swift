import Foundation
import Darwin

/// Counts and caller identity support auditing without retaining guest output or secrets.
public struct ToolCallRecord: Codable, Sendable {
    public let date: Date
    public let tool: String
    public let argumentBytes: Int
    public let resultBytes: Int
    public let durationMs: Double
    public let isError: Bool
    public let peerPID: pid_t?
    public let peerExecutable: String?

    public init(date: Date, tool: String, argumentBytes: Int, resultBytes: Int, durationMs: Double,
                isError: Bool, peerPID: pid_t? = nil, peerExecutable: String? = nil) {
        self.date = date
        self.tool = tool
        self.argumentBytes = argumentBytes
        self.resultBytes = resultBytes
        self.durationMs = durationMs
        self.isError = isError
        self.peerPID = peerPID
        self.peerExecutable = peerExecutable
    }
}

public enum ToolCallLog {
    public static func append(_ record: ToolCallRecord, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(record) else { return }
        data.append(10)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}
