import Foundation

/// The editable subset of an instance's lima.yaml.
///
/// Scalars come from the effective config (what Lima actually uses). Lists come from the raw
/// lima.yaml when present, so writing them back doesn't bake Lima's filled-in defaults into the
/// file; every entry keeps keys we don't model in `extra`.
public struct InstanceConfig: Hashable, Sendable {
    public var cpus: Int?
    /// As written in YAML, e.g. "4GiB".
    public var memory: String?
    public var disk: String?
    /// `video.display`: "none" (headless, Lima's default for VZ), "default" or "vz" (a VM window).
    public var videoDisplay: String?
    public var networks: [NetworkConfig]
    public var mounts: [MountConfig]
    public var portForwards: [PortForwardConfig]
    public var additionalDisks: [AdditionalDiskConfig]
    public var provision: [ProvisionConfig]

    public init(cpus: Int? = nil, memory: String? = nil, disk: String? = nil,
                networks: [NetworkConfig] = [], mounts: [MountConfig] = [],
                portForwards: [PortForwardConfig] = [], additionalDisks: [AdditionalDiskConfig] = [],
                provision: [ProvisionConfig] = []) {
        self.cpus = cpus
        self.memory = memory
        self.disk = disk
        self.networks = networks
        self.mounts = mounts
        self.portForwards = portForwards
        self.additionalDisks = additionalDisks
        self.provision = provision
    }

    /// - Parameters:
    ///   - raw: the parsed lima.yaml
    ///   - effective: the `config` field of `limactl list --format json`
    public init(raw: JSONValue, effective: JSONValue?) {
        func list(_ key: String) -> (entries: [JSONValue], fromRaw: Bool) {
            if let a = raw[key]?.arrayValue { return (a, true) }
            return (effective?[key]?.arrayValue ?? [], false)
        }
        cpus = effective?["cpus"]?.intValue ?? raw["cpus"]?.intValue
        memory = effective?["memory"]?.stringValue ?? raw["memory"]?.stringValue
        disk = effective?["disk"]?.stringValue ?? raw["disk"]?.stringValue
        videoDisplay = effective?["video"]?["display"]?.stringValue ?? raw["video"]?["display"]?.stringValue

        let nets = list("networks")
        networks = nets.entries.map { NetworkConfig(json: $0, stripDefaults: !nets.fromRaw) }
        let mnts = list("mounts")
        mounts = mnts.entries.map { MountConfig(json: $0, stripDefaults: !mnts.fromRaw) }
        let pfs = list("portForwards")
        portForwards = pfs.entries.map { PortForwardConfig(json: $0) }
        let disks = list("additionalDisks")
        additionalDisks = disks.entries.map { AdditionalDiskConfig(json: $0, stripDefaults: !disks.fromRaw) }
        provision = list("provision").entries.map(ProvisionConfig.init(json:))
    }

    /// yq expressions for `limactl edit --set`, covering only what differs from `original`.
    public func setExpressions(comparedTo original: InstanceConfig) -> [String] {
        var exprs: [String] = []
        if cpus != original.cpus, let cpus { exprs.append(".cpus = \(cpus)") }
        if memory != original.memory, let memory { exprs.append(".memory = \(JSONValue.string(memory).jsonText)") }
        if disk != original.disk, let disk { exprs.append(".disk = \(JSONValue.string(disk).jsonText)") }
        if videoDisplay != original.videoDisplay, let videoDisplay {
            exprs.append(".video.display = \(JSONValue.string(videoDisplay).jsonText)")
        }
        func list(_ key: String, _ new: [JSONValue], _ old: [JSONValue]) {
            guard new != old else { return }
            exprs.append(".\(key) = \(JSONValue.array(new).jsonText)")
        }
        list("networks", networks.map(\.json), original.networks.map(\.json))
        list("mounts", mounts.map(\.json), original.mounts.map(\.json))
        list("portForwards", portForwards.map(\.json), original.portForwards.map(\.json))
        list("additionalDisks", additionalDisks.map(\.json), original.additionalDisks.map(\.json))
        list("provision", provision.map(\.json), original.provision.map(\.json))
        return exprs
    }
}

// MARK: - Entries

public struct NetworkConfig: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case vzNAT
        /// A network from networks.yaml, e.g. "shared", "bridged", or "user-v2".
        case lima(String)
        case socket(String)
    }

    public var id = UUID()
    public var kind: Kind
    public var macAddress: String
    public var interface: String
    var extra: [String: JSONValue]

    public init(kind: Kind, macAddress: String = "", interface: String = "") {
        self.kind = kind
        self.macAddress = macAddress
        self.interface = interface
        self.extra = [:]
    }

    init(json: JSONValue, stripDefaults: Bool) {
        var o = json.objectValue ?? [:]
        if o["vzNAT"]?.boolValue == true { kind = .vzNAT }
        else if let s = o["socket"]?.stringValue, !s.isEmpty { kind = .socket(s) }
        else { kind = .lima(o["lima"]?.stringValue ?? "") }
        // Lima fills in a generated MAC and interface name; only keep them if the user wrote them.
        macAddress = stripDefaults ? "" : (o["macAddress"]?.stringValue ?? "")
        interface = stripDefaults ? "" : (o["interface"]?.stringValue ?? "")
        for k in ["vzNAT", "lima", "socket", "macAddress", "interface"] { o[k] = nil }
        if stripDefaults { o["metric"] = nil }
        extra = o
    }

    public var json: JSONValue {
        var o = extra
        switch kind {
        case .vzNAT: o["vzNAT"] = .bool(true)
        case .lima(let name): o["lima"] = .string(name)
        case .socket(let path): o["socket"] = .string(path)
        }
        if !macAddress.isEmpty { o["macAddress"] = .string(macAddress) }
        if !interface.isEmpty { o["interface"] = .string(interface) }
        return .object(o)
    }

    public var kindDescription: String {
        switch kind {
        case .vzNAT: "vzNAT"
        case .lima(let n): "lima:\(n)"
        case .socket(let p): "socket:\(p)"
        }
    }

    public static func == (a: Self, b: Self) -> Bool { a.json == b.json }
    public func hash(into h: inout Hasher) { h.combine(json) }
}

public struct MountConfig: Hashable, Sendable, Identifiable {
    public var id = UUID()
    /// Host path; `~` is allowed.
    public var location: String
    /// Guest path; empty means "same as location".
    public var mountPoint: String
    public var writable: Bool
    var extra: [String: JSONValue]

    public init(location: String, mountPoint: String = "", writable: Bool = false) {
        self.location = location
        self.mountPoint = mountPoint
        self.writable = writable
        self.extra = [:]
    }

    init(json: JSONValue, stripDefaults: Bool) {
        var o = json.objectValue ?? [:]
        location = o["location"]?.stringValue ?? ""
        let mp = o["mountPoint"]?.stringValue ?? ""
        mountPoint = mp == location ? "" : mp
        writable = o["writable"]?.boolValue ?? false
        for k in ["location", "mountPoint", "writable"] { o[k] = nil }
        // The effective config spells out every per-type default (sshfs, 9p, virtiofs).
        if stripDefaults { o = [:] }
        extra = o
    }

    public var json: JSONValue {
        var o = extra
        o["location"] = .string(location)
        if !mountPoint.isEmpty { o["mountPoint"] = .string(mountPoint) }
        if writable { o["writable"] = .bool(true) }
        return .object(o)
    }

    public static func == (a: Self, b: Self) -> Bool { a.json == b.json }
    public func hash(into h: inout Hasher) { h.combine(json) }
}

public struct PortForwardConfig: Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var guestPort: Int?
    public var hostPort: Int?
    /// "tcp", "udp", "any", or nil for Lima's default.
    public var proto: String?
    /// Empty means Lima's default (127.0.0.1).
    public var hostIP: String
    var extra: [String: JSONValue]

    public init(guestPort: Int? = nil, hostPort: Int? = nil, proto: String? = nil, hostIP: String = "") {
        self.guestPort = guestPort
        self.hostPort = hostPort
        self.proto = proto
        self.hostIP = hostIP
        self.extra = [:]
    }

    init(json: JSONValue) {
        var o = json.objectValue ?? [:]
        guestPort = o["guestPort"]?.intValue
        hostPort = o["hostPort"]?.intValue
        proto = o["proto"]?.stringValue
        hostIP = o["hostIP"]?.stringValue ?? ""
        for k in ["guestPort", "hostPort", "proto", "hostIP"] { o[k] = nil }
        extra = o
    }

    /// Rules using ranges, sockets, `ignore`, etc. are shown read-only; edit them as YAML.
    public var isAdvanced: Bool { !extra.isEmpty || guestPort == nil }

    public var json: JSONValue {
        var o = extra
        if let guestPort { o["guestPort"] = .int(guestPort) }
        if let hostPort { o["hostPort"] = .int(hostPort) }
        if let proto, !proto.isEmpty { o["proto"] = .string(proto) }
        if !hostIP.isEmpty { o["hostIP"] = .string(hostIP) }
        return .object(o)
    }

    /// e.g. "127.0.0.1:8080 → guest:80/tcp", or the JSON for advanced rules.
    public var summary: String {
        guard !isAdvanced, let guestPort else { return json.jsonText }
        let host = "\(hostIP.isEmpty ? "127.0.0.1" : hostIP):\(hostPort ?? guestPort)"
        return "\(host) → guest:\(guestPort)" + (proto.map { "/\($0)" } ?? "")
    }

    public static func == (a: Self, b: Self) -> Bool { a.json == b.json }
    public func hash(into h: inout Hasher) { h.combine(json) }
}

public struct AdditionalDiskConfig: Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    var extra: [String: JSONValue]

    public init(name: String) {
        self.name = name
        self.extra = [:]
    }

    init(json: JSONValue, stripDefaults: Bool) {
        // lima.yaml allows the shorthand `- diskname`.
        if let s = json.stringValue {
            name = s
            extra = [:]
            return
        }
        var o = json.objectValue ?? [:]
        name = o["name"]?.stringValue ?? ""
        o["name"] = nil
        if stripDefaults { o = [:] }
        extra = o
    }

    public var json: JSONValue {
        var o = extra
        o["name"] = .string(name)
        return .object(o)
    }

    public static func == (a: Self, b: Self) -> Bool { a.json == b.json }
    public func hash(into h: inout Hasher) { h.combine(json) }
}

/// One `provision:` entry. Script modes and `data` are editable; entries that load a `file`, and
/// the `yq` and `ansible` modes, are kept as they are (edit them as YAML).
///
/// Lima runs provisioning on every boot (cloud-init `scripts_per_boot`), so scripts must be idempotent.
public struct ProvisionConfig: Hashable, Sendable, Identifiable {
    public enum Mode: String, CaseIterable, Sendable, Identifiable {
        case system, user, boot, dependency, data, yq, ansible
        public var id: String { rawValue }
        /// Modes whose entry is a `script`.
        public var isScript: Bool { [.system, .user, .boot, .dependency].contains(self) }
    }

    public var id = UUID()
    /// As written; Lima defaults a missing mode to `system`.
    public var mode: Mode
    public var script: String
    /// `data`: destination path in the guest and file content.
    public var path: String
    public var content: String
    /// `dependency`: skip Lima's own package installation.
    public var skipDefaultDependencyResolution: Bool
    var extra: [String: JSONValue]

    public init(mode: Mode, script: String = "", path: String = "", content: String = "") {
        self.mode = mode
        self.script = script
        self.path = path
        self.content = content
        self.skipDefaultDependencyResolution = false
        self.extra = [:]
    }

    init(json: JSONValue) {
        var o = json.objectValue ?? [:]
        mode = Mode(rawValue: o["mode"]?.stringValue ?? "system") ?? .system
        script = o["script"]?.stringValue ?? ""
        path = o["path"]?.stringValue ?? ""
        content = o["content"]?.stringValue ?? ""
        skipDefaultDependencyResolution = o["skipDefaultDependencyResolution"]?.boolValue ?? false
        for k in ["mode", "script", "path", "content", "skipDefaultDependencyResolution"] { o[k] = nil }
        // An unknown mode survives in `extra` so writing back doesn't change it.
        if let raw = json["mode"]?.stringValue, Mode(rawValue: raw) == nil { o["mode"] = .string(raw) }
        extra = o
    }

    /// False for entries HanaLima shows read-only: a `file` source, `yq`, `ansible`, or an unknown mode.
    public var isEditable: Bool {
        extra["file"] == nil && extra["mode"] == nil && (mode.isScript || mode == .data)
    }

    public var json: JSONValue {
        var o = extra
        if o["mode"] == nil { o["mode"] = .string(mode.rawValue) }
        if mode.isScript {
            if !script.isEmpty || extra["file"] == nil { o["script"] = .string(script) }
            if mode == .dependency && skipDefaultDependencyResolution { o["skipDefaultDependencyResolution"] = .bool(true) }
        }
        if mode == .data {
            o["path"] = .string(path)
            if !content.isEmpty || extra["file"] == nil { o["content"] = .string(content) }
        }
        if !mode.isScript && mode != .data {
            if !path.isEmpty { o["path"] = .string(path) }
            if !script.isEmpty { o["script"] = .string(script) }
        }
        return .object(o)
    }

    /// The first meaningful line of the script, or the data path.
    public var summary: String {
        if mode == .data || mode == .yq { return path.isEmpty ? "（パス未設定）" : path }
        if let file = extra["file"] { return "file: \(file.stringValue ?? file["url"]?.stringValue ?? file.jsonText)" }
        let line = script.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#!") && !$0.hasPrefix("set -") }
        return line ?? "（空のスクリプト）"
    }

    public static func == (a: Self, b: Self) -> Bool { a.json == b.json }
    public func hash(into h: inout Hasher) { h.combine(json) }
}

// MARK: - Sizes

public enum ByteSize {
    /// Parses go-units RAMInBytes-style sizes ("4GiB", "4G", "512m", "100GB" — all base 1024).
    public static func parse(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let m = trimmed.wholeMatch(of: /(?i)(\d+(?:\.\d+)?)\s*([kmgtp]?)(i?)(b?)/),
              let value = Double(m.1) else { return nil }
        let exp: Double = switch m.2.lowercased() {
        case "k": 1
        case "m": 2
        case "g": 3
        case "t": 4
        case "p": 5
        default: 0
        }
        return Int64(value * pow(1024, exp))
    }

    /// Formats whole GiB as "NGiB" (the form Lima writes).
    public static func gib(_ value: Int) -> String { "\(value)GiB" }

    public static func gibValue(_ s: String?) -> Int? {
        guard let s, let bytes = parse(s) else { return nil }
        return Int((Double(bytes) / Double(1 << 30)).rounded())
    }
}
