import Foundation

/// Reads and writes `networks.json`.
public enum NetworkStore {
    private struct File: Codable {
        var version = 1
        var networks: [VirtualNetwork]
    }

    public static func load(from url: URL = NetworkPaths.configFile) throws -> [VirtualNetwork] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).networks
    }

    public static func save(_ networks: [VirtualNetwork], to url: URL = NetworkPaths.configFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(networks: networks.sorted { $0.name < $1.name })).write(to: url, options: .atomic)
    }

    public static func network(named name: String, in url: URL = NetworkPaths.configFile) throws -> VirtualNetwork? {
        try load(from: url).first { $0.name == name }
    }
}
