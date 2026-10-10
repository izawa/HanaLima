import Foundation

/// A disk managed by `limactl disk` (as printed by `limactl disk list --json`).
public struct LimaDisk: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }

    public var name: String
    /// Bytes.
    public var size: Int64
    /// "qcow2" or "raw".
    public var format: String?
    public var dir: String
    /// The instance the disk is attached to, or empty.
    public var instance: String?
    public var instanceDir: String?
    public var mountPoint: String?
    public var fsType: String?

    public var attachedInstance: String? {
        guard let instance, !instance.isEmpty else { return nil }
        return instance
    }

    public static func decodeList(_ data: Data) throws -> [LimaDisk] {
        let decoder = JSONDecoder()
        return try data.split(separator: UInt8(ascii: "\n"))
            .filter { !$0.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") } }
            .map { try decoder.decode(LimaDisk.self, from: Data($0)) }
    }
}
