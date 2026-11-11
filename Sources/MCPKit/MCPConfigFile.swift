import Foundation
import Darwin

public enum MCPConfigFile {
    /// Preserve manual installations and unrelated client configuration when an app moves.
    @discardableResult
    public static func update(at url: URL, helper: URL) throws -> Bool {
        var root = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        var hanalima = servers["hanalima"] as? [String: Any] ?? ["args": [String]()]
        if let command = hanalima["command"] as? String {
            if command == helper.path { return false }
            let components = URL(fileURLWithPath: command).pathComponents
            let inBundle = components.indices.contains { index in
                components[index].hasSuffix(".app") && index + 2 < components.count
                    && components[index + 1] == "Contents" && components[index + 2] == "Helpers"
            }
            if !inBundle && FileManager.default.fileExists(atPath: command) { return false }
        }
        hanalima["command"] = helper.path
        servers["hanalima"] = hanalima
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        var template = Array(url.deletingLastPathComponent().appendingPathComponent(".mcp-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let temporary = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        defer { close(fd); unlink(temporary) }
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard rename(temporary, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return true
    }
}
