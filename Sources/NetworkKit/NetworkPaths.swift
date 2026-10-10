import Foundation

/// File locations shared by the app and `hanalima-netd`.
public enum NetworkPaths {
    public static let labelPrefix = "org.izawa.HanaLima.net."

    /// `~/Library/Application Support/HanaLima`. Overridable for tests with `HANALIMA_SUPPORT_DIR`.
    public static var supportDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["HANALIMA_SUPPORT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/HanaLima", directoryHint: .isDirectory)
    }

    public static var configFile: URL { supportDirectory.appending(path: "networks.json") }
    public static var socketDirectory: URL { supportDirectory.appending(path: "net", directoryHint: .isDirectory) }
    public static var helperDirectory: URL { supportDirectory.appending(path: "bin", directoryHint: .isDirectory) }
    /// The current copy of the helper that LaunchAgents point at, so moving the app doesn't break
    /// registered networks. Each version gets its own file (see `HelperInstaller`).
    public static var installedHelper: URL { currentHelper(in: helperDirectory) }

    /// The helper named by `dir/current`; the plain `hanalima-netd` is what older builds installed.
    static func currentHelper(in dir: URL) -> URL {
        let name = (try? String(contentsOf: dir.appending(path: "current"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.appending(path: name.flatMap { $0.isEmpty ? nil : $0 } ?? "hanalima-netd")
    }

    public static func socket(for name: String) -> URL { socketDirectory.appending(path: "\(name).sock") }
    public static func status(for name: String) -> URL { socketDirectory.appending(path: "\(name).status.json") }
    /// flock(2)ed by every hanalima-netd around vmnet calls, so the helpers never call vmnet at once.
    public static var vmnetLock: URL { socketDirectory.appending(path: "vmnet.lock") }

    public static var logDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Logs/HanaLima", directoryHint: .isDirectory)
    }

    public static func log(for name: String) -> URL { logDirectory.appending(path: "net-\(name).log") }

    public static var launchAgentsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
    }

    public static func launchLabel(for name: String) -> String { labelPrefix + name }
    public static func launchAgentPlist(for name: String) -> URL {
        launchAgentsDirectory.appending(path: "\(launchLabel(for: name)).plist")
    }
}

/// What `hanalima-netd` reports about itself while running.
public struct NetworkDaemonStatus: Codable, Sendable, Hashable {
    public struct Client: Codable, Sendable, Hashable {
        public var id: Int
        public var vmnetMAC: String
        public var connectedAt: Date

        public init(id: Int, vmnetMAC: String, connectedAt: Date) {
            self.id = id
            self.vmnetMAC = vmnetMAC
            self.connectedAt = connectedAt
        }
    }

    public var pid: Int32
    public var startedAt: Date
    public var clients: [Client]

    public init(pid: Int32, startedAt: Date, clients: [Client]) {
        self.pid = pid
        self.startedAt = startedAt
        self.clients = clients
    }

    public static func load(for name: String) -> NetworkDaemonStatus? {
        guard let data = try? Data(contentsOf: NetworkPaths.status(for: name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(NetworkDaemonStatus.self, from: data)
    }

    public func write(for name: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: NetworkPaths.status(for: name), options: .atomic)
    }
}
