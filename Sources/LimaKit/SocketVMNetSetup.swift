import CryptoKit
import Foundation
import Yams
import vmnet

/// Installs and configures socket_vmnet, which Lima needs for `lima:shared|host|bridged`
/// networks. Bridged networking is the reason HanaLima still needs it: macOS 26's rootless
/// vmnet_network API doesn't support bridged mode.
///
/// Installation follows Lima's documented procedure: extract the official release tarball into
/// /opt/socket_vmnet (root-owned) and install the output of `limactl sudoers` as
/// /etc/sudoers.d/lima. Both steps need root, so they run in one script authorized once by the
/// user through the standard macOS administrator prompt.
public struct SocketVMNetSetup: Sendable {
    public let client: LimaClient

    public static let sudoersPath = "/private/etc/sudoers.d/lima"
    public static let installDirectory = "/opt/socket_vmnet"

    public init(client: LimaClient) {
        self.client = client
    }

    // MARK: - Status

    public struct Status: Sendable, Equatable {
        public var binaryPath: String
        public var binaryInstalled: Bool
        /// Lima only accepts a socket_vmnet that non-root users cannot modify.
        public var binarySecure: Bool
        public var sudoersInstalled: Bool
        /// Readable by the current user (needed for `limactl sudoers --check`).
        public var sudoersReadable: Bool
        /// `limactl sudoers --check` passes (the file matches networks.yaml).
        public var sudoersUpToDate: Bool
        /// The group networks.yaml grants socket_vmnet access to, and whether we're in it.
        public var group: String
        public var userInGroup: Bool
        public var bridgedInterface: String?

        public var isReady: Bool { binaryInstalled && binarySecure && sudoersUpToDate && userInGroup }
    }

    public func status() async -> Status {
        let networks = LimaNetworks.load()
        let path = networks.socketVMNetPath ?? "\(Self.installDirectory)/bin/socket_vmnet"
        let fm = FileManager.default
        let installed = fm.isExecutableFile(atPath: path)
        var secure = false
        if installed, let attrs = try? fm.attributesOfItem(atPath: path),
           let owner = attrs[.ownerAccountID] as? NSNumber, let perms = attrs[.posixPermissions] as? NSNumber {
            secure = owner.intValue == 0 && perms.intValue & 0o022 == 0
        }
        let sudoersInstalled = fm.fileExists(atPath: Self.sudoersPath)
        var upToDate = false
        if installed && sudoersInstalled {
            upToDate = (try? await client.runner.run(["sudoers", "--check", Self.sudoersPath])) != nil
        }
        let group = Self.configuredGroup() ?? "admin"
        return Status(binaryPath: path, binaryInstalled: installed, binarySecure: secure,
                      sudoersInstalled: sudoersInstalled,
                      sudoersReadable: fm.isReadableFile(atPath: Self.sudoersPath),
                      sudoersUpToDate: upToDate,
                      group: group, userInGroup: Self.currentUserIsMember(of: group),
                      bridgedInterface: networks.network(named: "bridged")?.interface)
    }

    static func configuredGroup() -> String? {
        guard let text = try? String(contentsOf: LimaNetworks.configURL, encoding: .utf8),
              let yaml = try? JSONValue.parseYAML(text) else { return nil }
        return yaml["group"]?.stringValue
    }

    static func currentUserIsMember(of group: String) -> Bool {
        guard let gr = getgrnam(group) else { return false }
        let gid = Int32(bitPattern: gr.pointee.gr_gid)
        guard let pw = getpwuid(getuid()) else { return false }
        var groups = [Int32](repeating: 0, count: 128)
        var count = Int32(groups.count)
        guard getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &groups, &count) != -1 else {
            return false
        }
        return groups.prefix(Int(count)).contains(gid)
    }

    // MARK: - Release

    public struct Release: Sendable, Equatable {
        public var version: String
        public var tarballURL: URL
        public var sha256: String
        public var size: Int?
    }

    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// Looks up the latest official release and its checksum on GitHub.
    public func latestRelease(session: URLSession = .shared) async throws -> Release {
        struct GitHubRelease: Decodable {
            struct Asset: Decodable {
                var name: String
                var size: Int
                var browser_download_url: URL
            }
            var tag_name: String
            var assets: [Asset]
        }
        let api = URL(string: "https://api.github.com/repos/lima-vm/socket_vmnet/releases/latest")!
        let (data, _) = try await session.data(from: api)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let tarName = "socket_vmnet-\(version)-\(Self.architecture).tar.gz"
        guard let tarball = release.assets.first(where: { $0.name == tarName }),
              let sums = release.assets.first(where: { $0.name == "SHA256SUMS" }) else {
            throw SetupError("リリース \(release.tag_name) に \(tarName) または SHA256SUMS がありません。")
        }
        let (sumData, _) = try await session.data(from: sums.browser_download_url)
        guard let sha = Self.checksum(for: tarName, in: String(decoding: sumData, as: UTF8.self)) else {
            throw SetupError("SHA256SUMS に \(tarName) のチェックサムがありません。")
        }
        return Release(version: version, tarballURL: tarball.browser_download_url, sha256: sha, size: tarball.size)
    }

    /// Parses `sha256sum`-style lines ("<hex>  <name>").
    static func checksum(for name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let file = parts[1].hasPrefix("*") ? parts[1].dropFirst() : parts[1]
            if file == name, parts[0].count == 64 { return parts[0].lowercased() }
        }
        return nil
    }

    /// Downloads the tarball into HanaLima's work directory and verifies its SHA-256.
    public func download(_ release: Release, session: URLSession = .shared) async throws -> URL {
        let (tmp, _) = try await session.download(from: release.tarballURL)
        let dest = LimaClient.workDirectory.appending(path: release.tarballURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        try Self.verify(dest, sha256: release.sha256)
        return dest
    }

    static func verify(_ file: URL, sha256 expected: String) throws {
        let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else {
            throw SetupError("チェックサムが一致しません（期待値 \(expected)、実際 \(digest)）。ダウンロードが破損しているか改ざんされています。")
        }
    }

    // MARK: - Privileged scripts

    /// Root script: install the tarball (re-verifying its checksum), then generate the sudoers file
    /// as the invoking user (`limactl sudoers` refuses to run as root), validate it with visudo and
    /// install it. Arguments: $1 tarball, $2 sha256, $3 user, $4 limactl path.
    public static let installScript = """
    set -eu
    TARBALL="$1"; SHA="$2"; TARGET_USER="$3"; LIMACTL="$4"
    echo "$SHA  $TARBALL" | /usr/bin/shasum -a 256 -c - >/dev/null
    /bin/mkdir -p /opt
    /usr/bin/tar -C / -xzf "$TARBALL" opt/socket_vmnet
    /usr/sbin/chown -R root:wheel /opt/socket_vmnet
    /bin/chmod -R go-w /opt/socket_vmnet
    \(sudoersSteps)
    """

    /// Root script that only regenerates /etc/sudoers.d/lima (after networks.yaml changes).
    /// Arguments: $1 user, $2 limactl path.
    public static let sudoersScript = """
    set -eu
    TARGET_USER="$1"; LIMACTL="$2"
    \(sudoersSteps)
    """

    /// The sudoers file is installed 0444: sudo only requires it to be root-owned and not
    /// writable by others, and `limactl sudoers --check` (run as the user) must be able to read it.
    private static let sudoersSteps = """
    TMP="$(/usr/bin/mktemp /tmp/hanalima-sudoers.XXXXXX)"
    trap '/bin/rm -f "$TMP"' EXIT
    /usr/bin/sudo -u "$TARGET_USER" -H "$LIMACTL" sudoers > "$TMP"
    /usr/sbin/visudo -cf "$TMP" >/dev/null
    /bin/mkdir -p /private/etc/sudoers.d
    /usr/bin/install -o root -g wheel -m 0444 "$TMP" \(sudoersPath)
    """

    /// Root script that removes socket_vmnet and the sudoers file.
    public static let uninstallScript = """
    set -eu
    /bin/rm -f \(sudoersPath)
    /bin/rm -rf \(installDirectory)
    """

    public func install(tarball: URL, release: Release) async throws {
        try await Self.runPrivileged(Self.installScript,
                                     arguments: [tarball.path, release.sha256, NSUserName(), client.limactlURL.path],
                                     prompt: "HanaLima が socket_vmnet を /opt/socket_vmnet にインストールし、/etc/sudoers.d/lima を設定します。")
    }

    public func regenerateSudoers() async throws {
        try await Self.runPrivileged(Self.sudoersScript,
                                     arguments: [NSUserName(), client.limactlURL.path],
                                     prompt: "HanaLima がネットワーク設定に合わせて /etc/sudoers.d/lima を更新します。")
    }

    public func uninstall() async throws {
        try await Self.runPrivileged(Self.uninstallScript, arguments: [],
                                     prompt: "HanaLima が socket_vmnet と /etc/sudoers.d/lima を削除します。")
    }

    /// AppleScript source that runs `script` with arguments as root after the standard
    /// administrator authentication dialog. Everything is passed through `quoted form of`.
    static func appleScript(for script: String, arguments: [String], prompt: String, privileged: Bool = true) -> String {
        func literal(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var command = "\"/bin/sh -c \" & quoted form of \(literal(script)) & \" hanalima-setup\""
        for arg in arguments { command += " & \" \" & quoted form of \(literal(arg))" }
        guard privileged else { return "do shell script \(command)" }
        return "do shell script \(command) with prompt \(literal(prompt)) with administrator privileges"
    }

    static func runPrivileged(_ script: String, arguments: [String], prompt: String) async throws {
        let osa = ProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/osascript"), environment: [:])
        do {
            _ = try await osa.run(["-e", appleScript(for: script, arguments: arguments, prompt: prompt)])
        } catch let error as CommandError {
            // -128 is "User canceled".
            if error.stderr.contains("-128") { throw SetupError("キャンセルされました。", canceled: true) }
            throw SetupError(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Bridged interface

    public struct HostInterface: Sendable, Hashable, Identifiable {
        public var id: String { device }
        public var device: String
        /// e.g. "Wi-Fi", "Ethernet".
        public var displayName: String

        public init(device: String, displayName: String) {
            self.device = device
            self.displayName = displayName
        }
    }

    /// Interfaces vmnet can bridge to, with their System Settings names.
    public static func bridgeableInterfaces() async -> [HostInterface] {
        var devices: [String] = []
        if let list = vmnet_copy_shared_interface_list() {
            for i in 0..<xpc_array_get_count(list) {
                if let s = xpc_array_get_string(list, i) { devices.append(String(cString: s)) }
            }
        }
        let ns = ProcessRunner(executableURL: URL(fileURLWithPath: "/usr/sbin/networksetup"), environment: [:])
        let ports = (try? await ns.run(["-listallhardwareports"]).stdoutString) ?? ""
        let names = parseHardwarePorts(ports)
        return devices.map { HostInterface(device: $0, displayName: names[$0] ?? $0) }
    }

    static func parseHardwarePorts(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var port: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Hardware Port: ") { port = String(line.dropFirst("Hardware Port: ".count)) }
            if line.hasPrefix("Device: "), let p = port { result[String(line.dropFirst("Device: ".count))] = p }
        }
        return result
    }

    /// Points the `bridged` network in networks.yaml at `interface`. The previous file is kept
    /// as networks.yaml.bak (comments in the file are not preserved). sudoers must be regenerated
    /// afterwards, because it lists the interface.
    public static func setBridgedInterface(_ interface: String, configURL: URL = LimaNetworks.configURL) throws {
        let text = try String(contentsOf: configURL, encoding: .utf8)
        guard var root = try Yams.compose(yaml: text), case .mapping(var top) = root,
              case .mapping(var nets)? = top["networks"], case .mapping(var bridged)? = nets["bridged"] else {
            throw SetupError("networks.yaml に networks.bridged がありません。")
        }
        bridged["interface"] = Node(interface)
        nets["bridged"] = .mapping(bridged)
        top["networks"] = .mapping(nets)
        root = .mapping(top)
        let backup = configURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: configURL, to: backup)
        try Yams.serialize(node: root).write(to: configURL, atomically: true, encoding: .utf8)
    }
}

public struct SetupError: Error, LocalizedError, Sendable {
    public let message: String
    public let canceled: Bool
    public init(_ message: String, canceled: Bool = false) {
        self.message = message
        self.canceled = canceled
    }
    public var errorDescription: String? { message }
}
