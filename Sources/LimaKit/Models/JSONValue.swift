import Foundation
import Yams

/// A JSON/YAML value. Used to carry config entries whose keys we don't model,
/// so editing one field never drops the others.
public enum JSONValue: Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        get { if case .object(let o) = self { o[key] } else { nil } }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var intValue: Int? {
        switch self {
        case .int(let i): i
        case .double(let d) where d.rounded() == d: Int(d)
        default: nil
        }
    }

    /// Compact JSON text. JSON is valid YAML flow syntax, so this is what we hand to
    /// `limactl edit --set '.key = <value>'`.
    public var jsonText: String {
        switch self {
        case .string(let s): Self.quote(s)
        case .int(let i): String(i)
        case .double(let d): d.isFinite ? String(d) : "null"
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        case .array(let a): "[" + a.map(\.jsonText).joined(separator: ",") + "]"
        case .object(let o):
            "{" + o.keys.sorted().map { "\(Self.quote($0)):\(o[$0]!.jsonText)" }.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue {
    /// Parses a YAML document (e.g. lima.yaml). Scalars are typed by the YAML core schema.
    public static func parseYAML(_ yaml: String) throws -> JSONValue {
        guard let node = try Yams.compose(yaml: yaml) else { return .object([:]) }
        return JSONValue(node: node)
    }

    init(node: Node) {
        switch node {
        case .scalar(let scalar):
            switch node.tag.rawValue {
            case Tag.Name.null.rawValue: self = .null
            case Tag.Name.bool.rawValue: self = node.bool.map(JSONValue.bool) ?? .string(scalar.string)
            case Tag.Name.int.rawValue: self = node.int.map(JSONValue.int) ?? .string(scalar.string)
            case Tag.Name.float.rawValue: self = node.float.map(JSONValue.double) ?? .string(scalar.string)
            default: self = .string(scalar.string)
            }
        case .sequence(let seq):
            self = .array(seq.map(JSONValue.init(node:)))
        case .mapping(let map):
            var o: [String: JSONValue] = [:]
            for (k, v) in map { o[k.string ?? ""] = JSONValue(node: v) }
            self = .object(o)
        case .alias:
            self = .null
        }
    }
}
