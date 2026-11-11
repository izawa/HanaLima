import Foundation
import Darwin

public struct MCPPaths: Sendable {
    public let home: URL

    public init(home: URL) { self.home = home }

    public static func current() -> MCPPaths {
        if let override = ProcessInfo.processInfo.environment["HANALIMA_MCP_HOME"] {
            return MCPPaths(home: URL(fileURLWithPath: override, isDirectory: true))
        }
        return MCPPaths(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hanalima"))
    }

    public var socket: URL { home.appendingPathComponent("agent.sock") }
    public var config: URL { home.appendingPathComponent("mcp.json") }
    public var lock: URL { home.appendingPathComponent("agent.lock") }
    public var callLog: URL { home.appendingPathComponent("calls.jsonl") }

    public func ensureHome() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard chmod(home.path, 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
