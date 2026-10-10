import Foundation

/// A log line from limactl. limactl logs through logrus; we request `--log-format=json`
/// but also understand the text format (`time="..." level=info msg="..."`) and plain lines.
public struct LogEntry: Sendable, Hashable, Identifiable {
    public enum Level: String, Sendable, Comparable {
        case trace, debug, info, warning, error, fatal, panic

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.order < rhs.order }

        private var order: Int {
            switch self {
            case .trace: 0
            case .debug: 1
            case .info: 2
            case .warning: 3
            case .error: 4
            case .fatal: 5
            case .panic: 6
            }
        }

        init(logrus raw: String) {
            switch raw.lowercased() {
            case "warn", "warning": self = .warning
            default: self = Level(rawValue: raw.lowercased()) ?? .info
            }
        }
    }

    public let id = UUID()
    public let date: Date
    public let level: Level
    public let message: String
    /// Extra structured fields (e.g. `error`, `instance`).
    public let fields: [String: String]

    public init(date: Date = .now, level: Level, message: String, fields: [String: String] = [:]) {
        self.date = date
        self.level = level
        self.message = message
        self.fields = fields
    }

    /// The message plus its `error` field, if any.
    public var displayText: String {
        if let err = fields["error"], !err.isEmpty { return "\(message): \(err)" }
        return message
    }

    public static func parse(_ line: String) -> LogEntry {
        if line.hasPrefix("{"),
           let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
            let level = Level(logrus: obj["level"] as? String ?? "info")
            let message = obj["msg"] as? String ?? line
            let date = (obj["time"] as? String).flatMap(Self.parseDate) ?? .now
            var fields: [String: String] = [:]
            for (k, v) in obj where !["level", "msg", "time"].contains(k) {
                fields[k] = "\(v)"
            }
            return LogEntry(date: date, level: level, message: message, fields: fields)
        }
        if line.contains("level=") && line.contains("msg=") {
            let kv = parseLogfmt(line)
            return LogEntry(
                date: kv["time"].flatMap(Self.parseDate) ?? .now,
                level: Level(logrus: kv["level"] ?? "info"),
                message: kv["msg"] ?? line,
                fields: kv.filter { !["time", "level", "msg"].contains($0.key) })
        }
        return LogEntry(level: .info, message: line)
    }

    /// Picks the most useful error text out of a stderr blob.
    public static func summarize(stderr: String) -> String {
        let entries = stderr.split(whereSeparator: \.isNewline).map { parse(String($0)) }
        if let fatal = entries.last(where: { $0.level >= .error }) { return fatal.displayText }
        return entries.last?.displayText ?? ""
    }

    static func parseDate(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// Minimal logfmt parser: `key=value key="quoted value"`.
    static func parseLogfmt(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        var i = line.startIndex
        func skipSpaces() { while i < line.endIndex, line[i] == " " { i = line.index(after: i) } }
        while i < line.endIndex {
            skipSpaces()
            guard let eq = line[i...].firstIndex(of: "=") else { break }
            let key = String(line[i..<eq])
            i = line.index(after: eq)
            var value = ""
            if i < line.endIndex, line[i] == "\"" {
                i = line.index(after: i)
                while i < line.endIndex, line[i] != "\"" {
                    if line[i] == "\\", line.index(after: i) < line.endIndex {
                        i = line.index(after: i)
                    }
                    value.append(line[i])
                    i = line.index(after: i)
                }
                if i < line.endIndex { i = line.index(after: i) }
            } else {
                let end = line[i...].firstIndex(of: " ") ?? line.endIndex
                value = String(line[i..<end])
                i = end
            }
            result[key] = value
        }
        return result
    }
}
