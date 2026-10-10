import Foundation

/// One line of `limactl watch --json` (mirrors `watchEvent` / `events.Event` in Lima v2.x).
public struct WatchEvent: Decodable, Sendable, Hashable {
    public var instance: String
    public var event: Event

    public struct Event: Decodable, Sendable, Hashable {
        public var time: Date?
        public var status: Status

        enum CodingKeys: String, CodingKey { case time, status }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            time = (try c.decodeIfPresent(String.self, forKey: .time)).flatMap(LogEntry.parseDate)
            status = try c.decodeIfPresent(Status.self, forKey: .status) ?? Status()
        }
    }

    public struct Status: Decodable, Sendable, Hashable {
        public var running: Bool?
        public var degraded: Bool?
        public var exiting: Bool?
        public var errors: [String]?
        public var sshLocalPort: Int?
        public var cloudInitProgress: CloudInitProgress?
        public var portForward: PortForward?
        public var vsock: Vsock?

        public init() {}
    }

    public struct CloudInitProgress: Decodable, Sendable, Hashable {
        public var logLine: String?
        public var completed: Bool?
        public var active: Bool?
    }

    public struct PortForward: Decodable, Sendable, Hashable {
        public var type: String
        public var `protocol`: String?
        public var guestAddr: String?
        public var hostAddr: String?
        public var error: String?
    }

    public struct Vsock: Decodable, Sendable, Hashable {
        public var type: String
        public var hostAddr: String?
        public var vsockPort: Int?
        public var reason: String?
    }

    /// Human-readable summary, matching `limactl watch` text output where possible.
    public var summary: String { summary(previousSSHPort: nil) }

    /// Like `summary`, but omits the SSH port when it equals `previousSSHPort`. Lima repeats
    /// the port in every event's status, which is noise in a log view.
    public func summary(previousSSHPort: Int?) -> String {
        let s = event.status
        var parts: [String] = []
        if s.running == true { parts.append(s.degraded == true ? "running (degraded)" : "running") }
        if s.exiting == true { parts.append("exiting") }
        if let port = s.sshLocalPort, port != 0, port != previousSSHPort {
            parts.append("ssh available on port \(port)")
        }
        for e in s.errors ?? [] { parts.append("error: \(e)") }
        if let ci = s.cloudInitProgress {
            if ci.completed == true { parts.append("cloud-init completed") }
            else if let line = ci.logLine, !line.isEmpty { parts.append("cloud-init: \(line)") }
        }
        if let pf = s.portForward {
            let proto = pf.protocol ?? ""
            let guest = pf.guestAddr ?? ""
            switch pf.type {
            case "forwarding": parts.append("forwarding \(proto) \(guest) to \(pf.hostAddr ?? "")")
            case "not-forwarding": parts.append("not forwarding \(proto) \(guest)")
            case "stopping": parts.append("stopping forwarding \(proto) \(guest)")
            case "failed": parts.append("failed to forward \(proto) \(guest): \(pf.error ?? "")")
            default: parts.append("port forward \(pf.type)")
            }
        }
        if let vs = s.vsock {
            switch vs.type {
            case "started": parts.append("started vsock forwarder: \(vs.hostAddr ?? "") -> vsock:\(vs.vsockPort ?? 0)")
            default: parts.append("vsock \(vs.type): \(vs.reason ?? "")")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// True for events that imply the instance's list status may have changed.
    public var affectsStatus: Bool {
        let s = event.status
        return s.running != nil || s.exiting != nil || !(s.errors ?? []).isEmpty
            || s.cloudInitProgress?.completed == true
    }
}
