import Foundation

/// Instance status as reported by `limactl list`.
public enum InstanceStatus: Sendable, Hashable, Codable {
    case running, stopped, broken, installing, uninitialized
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "Running": self = .running
        case "Stopped": self = .stopped
        case "Broken": self = .broken
        case "Installing": self = .installing
        case "Uninitialized": self = .uninitialized
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .running: "Running"
        case .stopped: "Stopped"
        case .broken: "Broken"
        case .installing: "Installing"
        case .uninitialized: "Uninitialized"
        case .unknown(let s): s
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// One entry of the instance's `networks:` list.
public struct NetworkAttachment: Codable, Sendable, Hashable {
    public var lima: String?
    public var socket: String?
    public var vzNAT: Bool?
    public var macAddress: String?
    public var interface: String?
    public var metric: UInt32?

    public init(lima: String? = nil, socket: String? = nil, vzNAT: Bool? = nil,
                macAddress: String? = nil, interface: String? = nil, metric: UInt32? = nil) {
        self.lima = lima
        self.socket = socket
        self.vzNAT = vzNAT
        self.macAddress = macAddress
        self.interface = interface
        self.metric = metric
    }

    /// Short human-readable kind, e.g. "vzNAT", "lima:shared".
    public var kindDescription: String {
        if vzNAT == true { return "vzNAT" }
        if let lima, !lima.isEmpty { return "lima:\(lima)" }
        if let socket, !socket.isEmpty { return "socket:\(socket)" }
        return "unknown"
    }
}

public struct AdditionalDiskRef: Codable, Sendable, Hashable {
    public var name: String
}

/// An instance as reported by `limactl list --format json`.
/// The Go `errors` field is intentionally not decoded (errors marshal as `{}`).
public struct LimaInstance: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }

    public var name: String
    public var hostname: String?
    public var status: InstanceStatus
    public var dir: String
    public var vmType: String?
    public var arch: String?
    public var cpus: Int?
    /// Bytes.
    public var memory: Int64?
    /// Bytes.
    public var disk: Int64?
    public var message: String?
    public var additionalDisks: [AdditionalDiskRef]?
    public var networks: [NetworkAttachment]?
    public var sshLocalPort: Int?
    public var sshConfigFile: String?
    public var sshAddress: String?
    public var hostAgentPID: Int?
    public var driverPID: Int?
    public var protected: Bool?
    public var limaVersion: String?
    public var param: [String: String]?
    public var autoStartedIdentifier: String?
    /// The effective configuration (lima.yaml with all defaults filled in).
    public var config: JSONValue?

    enum CodingKeys: String, CodingKey {
        case name, hostname, status, dir, vmType, arch, cpus, memory, disk, message
        case additionalDisks
        case networks = "network"
        case sshLocalPort, sshConfigFile, sshAddress, hostAgentPID, driverPID
        case protected, limaVersion, param, autoStartedIdentifier, config
    }

    public var isRunning: Bool { status == .running }

    public var configURL: URL { URL(fileURLWithPath: dir).appending(path: "lima.yaml") }
    public var hostAgentStderrLogURL: URL { URL(fileURLWithPath: dir).appending(path: "ha.stderr.log") }
}

extension LimaInstance {
    /// Decodes the newline-delimited JSON that `limactl list --format json` prints.
    public static func decodeList(_ data: Data) throws -> [LimaInstance] {
        let decoder = JSONDecoder()
        return try data.split(separator: UInt8(ascii: "\n"))
            .filter { !$0.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") } }
            .map { try decoder.decode(LimaInstance.self, from: Data($0)) }
    }
}
