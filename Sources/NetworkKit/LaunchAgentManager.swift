import CryptoKit
import Foundation

/// Registers each virtual network as a per-user LaunchAgent. launchd owns the listening
/// socket and starts `hanalima-netd` on the first connection, so networks work whether or
/// not the app is running, including for VMs started with plain `limactl start`.
public struct LaunchAgentManager: Sendable {
    public enum State: Sendable, Equatable {
        /// Not registered with launchd.
        case notLoaded
        /// Registered; the helper starts on the next connection.
        case waiting
        case running(pid: Int32)
        /// Registered, but the helper's last run failed (see the log).
        case failed(exitCode: Int32)
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public let uid = getuid()
    public var domain: String { "gui/\(uid)" }

    public init() {}

    /// The LaunchAgent property list for `network`.
    public func plist(for network: VirtualNetwork, helper: URL = NetworkPaths.installedHelper) -> [String: Any] {
        var env: [String: String] = [:]
        if let dir = ProcessInfo.processInfo.environment["HANALIMA_SUPPORT_DIR"], !dir.isEmpty {
            env["HANALIMA_SUPPORT_DIR"] = dir
        }
        var plist: [String: Any] = [
            "Label": network.launchLabel,
            "ProgramArguments": [helper.path, "--network", network.name],
            "Sockets": ["Listener": ["SockPathName": network.socketPath, "SockPathMode": 0o600]],
            "StandardOutPath": NetworkPaths.log(for: network.name).path,
            "StandardErrorPath": NetworkPaths.log(for: network.name).path,
            // Background QoS would starve packet forwarding.
            "ProcessType": "Interactive",
        ]
        if !env.isEmpty { plist["EnvironmentVariables"] = env }
        return plist
    }

    /// Writes the plist and (re)loads it. Any running helper is stopped, so attached VMs lose
    /// this network until they are restarted.
    public func install(_ network: VirtualNetwork, helper: URL = NetworkPaths.installedHelper) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: NetworkPaths.launchAgentsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: NetworkPaths.socketDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: NetworkPaths.logDirectory, withIntermediateDirectories: true)

        let url = NetworkPaths.launchAgentPlist(for: network.name)
        let data = try PropertyListSerialization.data(fromPropertyList: plist(for: network, helper: helper),
                                                      format: .xml, options: 0)
        try data.write(to: url, options: .atomic)

        bootout(network.name)
        // launchd refuses to bind over a stale socket file.
        try? fm.removeItem(at: NetworkPaths.socket(for: network.name))
        try? fm.removeItem(at: NetworkPaths.status(for: network.name))
        let out = launchctl(["bootstrap", domain, url.path])
        guard out.status == 0 else {
            throw Failure(message: String(localized: "launchctl bootstrap に失敗しました: \(out.output.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
        // launchd creates the socket asynchronously; wait so a VM started right away can connect.
        // The first registration of a new helper file can take several seconds (Background Task
        // Management checks it), more so when several agents register at once.
        let socket = NetworkPaths.socket(for: network.name).path
        for _ in 0..<300 where !fm.fileExists(atPath: socket) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard fm.fileExists(atPath: socket) else {
            throw Failure(message: String(localized: "launchd がソケット \(socket) を作成しませんでした"))
        }
    }

    /// Unloads the agent and removes its plist, socket and status file.
    public func uninstall(_ name: String) {
        bootout(name)
        let fm = FileManager.default
        try? fm.removeItem(at: NetworkPaths.launchAgentPlist(for: name))
        try? fm.removeItem(at: NetworkPaths.socket(for: name))
        try? fm.removeItem(at: NetworkPaths.status(for: name))
    }

    /// Stops the helper without unregistering; launchd starts it again on the next connection.
    public func restart(_ name: String) {
        _ = launchctl(["kill", "SIGTERM", "\(domain)/\(NetworkPaths.launchLabel(for: name))"])
    }

    /// The program path in `name`'s plist on disk.
    public func registeredProgram(of name: String) -> String? {
        guard let data = try? Data(contentsOf: NetworkPaths.launchAgentPlist(for: name)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return nil }
        return args.first
    }

    /// Re-registers agents that point at an older helper copy, but only while their helper is not
    /// running, so attached VMs keep their network; the rest are retried on a later call.
    /// Returns the names that were re-registered.
    @discardableResult
    public func upgradeIdleAgents(_ networks: [VirtualNetwork], helper: URL = NetworkPaths.installedHelper) -> [String] {
        var upgraded: [String] = []
        for network in networks where isInstalled(network.name) && registeredProgram(of: network.name) != helper.path {
            if case .running = state(of: network.name) { continue }
            if (try? install(network, helper: helper)) != nil { upgraded.append(network.name) }
        }
        return upgraded
    }

    public func state(of name: String) -> State {
        let out = launchctl(["print", "\(domain)/\(NetworkPaths.launchLabel(for: name))"])
        guard out.status == 0 else { return .notLoaded }
        return Self.parseState(out.output)
    }

    public func isInstalled(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: NetworkPaths.launchAgentPlist(for: name).path)
    }

    /// Labels of all HanaLima network agents currently on disk.
    public func installedNetworkNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: NetworkPaths.launchAgentsDirectory.path)) ?? []
        return files.compactMap { file in
            guard file.hasPrefix(NetworkPaths.labelPrefix), file.hasSuffix(".plist") else { return nil }
            return String(file.dropFirst(NetworkPaths.labelPrefix.count).dropLast(".plist".count))
        }
    }

    static func parseState(_ output: String) -> State {
        var pid: Int32?
        var running = false
        var lastExit: Int32?
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "state = running" { running = true }
            if t.hasPrefix("pid = "), let p = Int32(t.dropFirst("pid = ".count)) { pid = p }
            if t.hasPrefix("last exit code = "), let c = Int32(t.dropFirst("last exit code = ".count)) { lastExit = c }
        }
        if running, let pid { return .running(pid: pid) }
        if let lastExit, lastExit != 0 { return .failed(exitCode: lastExit) }
        return .waiting
    }

    /// The last error line the helper logged, for showing next to a failed network.
    public func lastError(of name: String) -> String? {
        guard let text = try? String(contentsOf: NetworkPaths.log(for: name), encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last { $0.contains("error:") }
            .map { String($0.split(separator: " ", maxSplits: 1).last ?? $0) }
    }

    private func bootout(_ name: String) {
        _ = launchctl(["bootout", "\(domain)/\(NetworkPaths.launchLabel(for: name))"])
    }

    @discardableResult
    private func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Installs the helper bundled in the app as a copy whose name contains a hash of its contents.
///
/// launchd pins a LaunchAgent to the code signature (cdhash) of its program when the agent is
/// registered: if the file is later replaced by a different build, launchd refuses to spawn it
/// ("spawn failed", last exit code 78) until the agent is registered again. So a new helper never
/// overwrites the old one. Agents are re-registered onto the new copy while their helper is not
/// running (`LaunchAgentManager.upgradeIdleAgents`), and old copies are removed once no agent uses them.
public enum HelperInstaller {
    /// Copies `bundled` into the helper directory unless that version is already there, and
    /// makes it the current helper. Returns the installed copy.
    @discardableResult
    public static func installIfNeeded(from bundled: URL, into dir: URL = NetworkPaths.helperDirectory) throws -> URL {
        let fm = FileManager.default
        let data = try Data(contentsOf: bundled)
        let name = "hanalima-netd-" + SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        let dest = dir.appending(path: name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.contentsEqual(atPath: bundled.path, andPath: dest.path) {
            let tmp = dir.appending(path: ".\(name).\(UUID().uuidString)")
            try fm.copyItem(at: bundled, to: tmp)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
        }
        if NetworkPaths.currentHelper(in: dir) != dest {
            try Data(name.utf8).write(to: dir.appending(path: "current"), options: .atomic)
        }
        return dest
    }

    /// Deletes helper copies that are neither current nor used by a registered agent.
    public static func removeUnusedCopies(agents: LaunchAgentManager = LaunchAgentManager()) {
        let programs = agents.installedNetworkNames().compactMap { agents.registeredProgram(of: $0) }
        removeUnusedCopies(in: NetworkPaths.helperDirectory, inUse: programs)
    }

    static func removeUnusedCopies(in dir: URL, inUse programs: [String]) {
        let fm = FileManager.default
        var keep: Set<String> = [NetworkPaths.currentHelper(in: dir).lastPathComponent]
        for program in programs { keep.insert(URL(fileURLWithPath: program).lastPathComponent) }
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for file in files where file.hasPrefix("hanalima-netd") && !keep.contains(file) {
            try? fm.removeItem(at: dir.appending(path: file))
        }
    }
}
