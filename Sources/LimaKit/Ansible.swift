import Foundation

/// Ansible from the host against Lima VMs (docs/08). HanaLima touches only Ansible's stable
/// outside: an INI inventory line that points `ssh` at Lima's `ssh.config`, the
/// `ansible-playbook` command line, and its exit status. No callbacks, no Python API.
public enum Ansible {
    /// The inventory host name for an instance, as Lima's `ssh.config` names it.
    public static func host(for instance: String) -> String { "lima-\(instance)" }

    /// `lima-<name> ansible_ssh_common_args='-F <ssh.config>'`: Lima's config carries the port,
    /// user, key, host-key settings and the control socket, so nothing else is needed.
    public static func inventoryLine(instance: String, instanceDir: URL) -> String {
        let config = instanceDir.appending(path: "ssh.config").path(percentEncoded: false)
        return "\(host(for: instance)) ansible_ssh_common_args='-F \(shellQuote(config))'"
    }

    /// The whole inventory: every instance under `[hanalima]`, so a playbook can target one
    /// (`--limit lima-<name>`) or all of them, also from the user's own terminal.
    public static func inventory(instances: [(name: String, dir: URL)]) -> String {
        var s = "# Written by HanaLima. Hosts are Lima instances; ssh goes through each one's ssh.config.\n# Stopped VMs are unreachable: target running ones with --limit.\n[hanalima]\n"
        for inst in instances.sorted(by: { $0.name < $1.name }) {
            s += inventoryLine(instance: inst.name, instanceDir: inst.dir) + "\n"
        }
        return s
    }

    /// `<support>/ansible/inventory.ini`.
    public static func inventoryURL(supportDirectory: URL) -> URL {
        supportDirectory.appending(path: "ansible/inventory.ini")
    }

    /// Writes the inventory (creating the folder); returns its URL.
    @discardableResult
    public static func writeInventory(instances: [(name: String, dir: URL)], supportDirectory: URL) throws -> URL {
        let url = inventoryURL(supportDirectory: supportDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try inventory(instances: instances).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// `ansible-playbook -i <inventory> --limit <host> [extra…] <playbook>`; run it with the
    /// playbook's folder as the working directory so `roles/`, `group_vars/` and `ansible.cfg` resolve.
    public static func arguments(playbook: URL, inventory: URL, limitTo instance: String?, extra: [String] = []) -> [String] {
        var args = ["-i", inventory.path(percentEncoded: false)]
        if let instance { args += ["--limit", host(for: instance)] }
        args += extra
        args.append(playbook.path(percentEncoded: false))
        return args
    }

    /// Splits extra arguments the way a shell would for simple cases (spaces, single and
    /// double quotes, backslash). Enough for `-e key=value --tags x`.
    public static func splitArguments(_ text: String) -> [String] {
        var out: [String] = [], cur = "", inSingle = false, inDouble = false, escape = false, has = false
        for c in text {
            if escape { cur.append(c); escape = false; continue }
            switch c {
            case "\\" where !inSingle: escape = true
            case "'" where !inDouble: inSingle.toggle(); has = true
            case "\"" where !inSingle: inDouble.toggle(); has = true
            case " ", "\t", "\n":
                if inSingle || inDouble { cur.append(c) } else if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
            default: cur.append(c)
            }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: - Finding ansible-playbook

    public struct Tool: Equatable, Sendable {
        public var url: URL
        /// The first line of `--version`, e.g. "ansible-playbook [core 2.21.5]".
        public var version: String
    }

    /// Where `ansible-playbook` usually is: Homebrew, pip under pyenv, pipx/uv, then the
    /// Intel-era `/usr/local/bin`. Apps launched from Finder don't see the shell's PATH.
    public static func candidates(home: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var dirs = ["/opt/homebrew/bin", home.appending(path: ".pyenv/shims").path(percentEncoded: false),
                    home.appending(path: ".local/bin").path(percentEncoded: false), "/usr/local/bin"]
        dirs += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.map { URL(filePath: $0).appending(path: "ansible-playbook") }
    }

    /// Runs `<url> --version` and returns the tool if it works. A file that exists but can't
    /// run (an Intel binary on Apple silicon, a broken shim) is not a tool.
    public static func probe(_ url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) async -> Tool? {
        guard FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) else { return nil }
        let runner = ProcessRunner(executableURL: url, environment: environment)
        guard let out = try? await runner.run(["--version"]) else { return nil }
        let first = out.stdoutString.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard first.contains("ansible") else { return nil }
        return Tool(url: url, version: first)
    }

    /// The first working candidate (`preferred` first, when set).
    public static func locate(preferred: URL?, environment: [String: String] = ProcessInfo.processInfo.environment) async -> Tool? {
        for url in ([preferred].compactMap { $0 } + candidates(environment: environment)) {
            if let tool = await probe(url, environment: environment) { return tool }
        }
        return nil
    }

    static func shellQuote(_ s: String) -> String {
        s.contains(where: { " '\"\\$`".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : s
    }
}
