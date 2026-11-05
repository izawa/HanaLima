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

    /// One network by name, decoding only that entry: the helper reads its own network this way,
    /// so an entry of a kind this build doesn't know (a newer app's `mode`, say) breaks only the
    /// helper of that network, not every helper on the Mac. `load` stays strict for the app.
    public static func network(named name: String, in url: URL = NetworkPaths.configFile) throws -> VirtualNetwork? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let file = json as? [String: Any], let entries = file["networks"] as? [Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) has no networks array"])
        }
        guard let entry = entries.first(where: { ($0 as? [String: Any])?["name"] as? String == name }) else { return nil }
        do {
            return try JSONDecoder().decode(VirtualNetwork.self, from: JSONSerialization.data(withJSONObject: entry))
        } catch {
            let mode = (entry as? [String: Any])?["mode"] as? String ?? "?"
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "network \(name) (mode \(mode)) can't be read by this build of the helper (\(error.localizedDescription)); update the agent from the app"])
        }
    }
}
