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
        return LimaNetworks(networks: sorted, socketVMNetPath: yaml["paths"]?["socketVMNet"]?.stringValue)
    }

    public func network(named name: String) -> Network? { networks.first { $0.name == name } }
}
