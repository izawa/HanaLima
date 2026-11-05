import Foundation

/// Named networks from `$LIMA_HOME/_config/networks.yaml`, referenced from an instance as `lima: <name>`.
public struct LimaNetworks: Sendable, Hashable {
    public struct Network: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        /// "shared", "host", "bridged", or "user-v2".
        public var mode: String
        public var gateway: String?
        public var netmask: String?
        public var interface: String?

        /// Everything except user-v2 runs through socket_vmnet.
        public var needsSocketVMNet: Bool { mode != "user-v2" }
    }

    public var networks: [Network]
    public var socketVMNetPath: String?
    /// `paths.varRun`: where socket_vmnet's sockets live (`socket_vmnet.<name>`).
    public var varRun: String = "/private/var/run/lima"

    public var socketVMNetInstalled: Bool {
        guard let socketVMNetPath else { return false }
        return FileManager.default.isExecutableFile(atPath: socketVMNetPath)
    }

    public static var limaHome: URL {
        if let home = ProcessInfo.processInfo.environment["LIMA_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".lima")
    }

    public static var configURL: URL { limaHome.appending(path: "_config/networks.yaml") }

    /// Lima's built-in defaults, used before networks.yaml has been generated.
    public static let defaults = LimaNetworks(networks: [
        Network(name: "user-v2", mode: "user-v2", gateway: "192.168.104.1", netmask: "255.255.255.0"),
        Network(name: "shared", mode: "shared", gateway: "192.168.105.1", netmask: "255.255.255.0"),
        Network(name: "host", mode: "host", gateway: "192.168.106.1", netmask: "255.255.255.0"),
        Network(name: "bridged", mode: "bridged", interface: "en0"),
    ], socketVMNetPath: "/opt/socket_vmnet/bin/socket_vmnet")

    public static func load(from url: URL = configURL) -> LimaNetworks {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let yaml = try? JSONValue.parseYAML(text) else { return defaults }
        return parse(yaml)
    }

    static func parse(_ yaml: JSONValue) -> LimaNetworks {
        let nets = (yaml["networks"]?.objectValue ?? [:]).map { name, value in
            Network(name: name,
                    mode: value["mode"]?.stringValue ?? "",
                    gateway: value["gateway"]?.stringValue,
                    netmask: value["netmask"]?.stringValue,
                    interface: value["interface"]?.stringValue)
        }
        // user-v2 first (no root needed), then alphabetical.
        let sorted = nets.sorted { a, b in
            if (a.mode == "user-v2") != (b.mode == "user-v2") { return a.mode == "user-v2" }
            return a.name < b.name
        }
        var networks = LimaNetworks(networks: sorted, socketVMNetPath: yaml["paths"]?["socketVMNet"]?.stringValue)
        if let varRun = yaml["paths"]?["varRun"]?.stringValue, !varRun.isEmpty { networks.varRun = varRun }
        return networks
    }

    public func network(named name: String) -> Network? { networks.first { $0.name == name } }

    /// socket_vmnet's socket for `name` (Lima's `Config.Sock`): the QEMU stream protocol, like
    /// HanaLima's own `socket:` networks.
    public func socketVMNetSocket(for name: String) -> String { "\(varRun)/socket_vmnet.\(name)" }

    /// A user-v2 network's shared usernet sockets (Lima's `usernet.Sock`): `<LIMA_HOME>/_networks/<name>/<name>_fd.sock` and `_ep.sock`.
    public static func usernetSocket(limaHome: URL, network name: String, kind: String) -> String {
        limaHome.appending(path: "_networks/\(name)/\(name)_\(kind).sock").path
    }

    /// The gateway usernet serves for a user-v2 network: the subnet's second address (Lima's
    /// `usernet.GatewayIP`; the yaml's `gateway` names the first). DNS is served there too.
    public static func usernetGateway(of network: Network) -> String? {
        guard let g = network.gateway, let ip = IPv4Address(g), let mask = IPv4Address(network.netmask ?? "255.255.255.0") else { return nil }
        return IPv4Address((ip.value & mask.value) + 2).description
    }

    /// A tiny IPv4 helper (NetworkKit's IPv4 isn't visible from LimaKit).
    public struct IPv4Address {
        public var value: UInt32
        public init(_ value: UInt32) { self.value = value }
        public init?(_ text: String) {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var v: UInt32 = 0
            for p in parts { guard let o = UInt8(p) else { return nil }; v = v << 8 | UInt32(o) }
            value = v
        }
        public var description: String { "\(value >> 24).\(value >> 16 & 0xff).\(value >> 8 & 0xff).\(value & 0xff)" }
    }
}
