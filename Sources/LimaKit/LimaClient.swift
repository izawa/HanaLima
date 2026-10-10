import Foundation

/// Front end for the `limactl` CLI. Every operation maps to a command a user could type.
public struct LimaClient: Sendable {
    public let limactlURL: URL
    public let runner: ProcessRunner

    /// Directories prepended to PATH: apps launched from Finder don't inherit the shell's PATH,
    /// but limactl needs to find helpers such as qemu-img and the guest agents.
    static let extraPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]

    public init(limactlURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.limactlURL = limactlURL
        var env = environment
        let current = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let merged = Self.extraPaths.filter { !current.contains($0) } + current
        env["PATH"] = merged.joined(separator: ":")
        // Some commands write into the current directory (e.g. `limactl edit` saves
        // lima.REJECTED.yaml), so give them a scratch directory of their own.
        self.runner = ProcessRunner(executableURL: limactlURL, environment: env,
                                    currentDirectoryURL: Self.workDirectory)
    }

    /// `$TMPDIR/HanaLima`, created on demand.
    static let workDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appending(path: "HanaLima", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Finds limactl: `$LIMACTL` first, then the usual Homebrew locations, then PATH.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let explicit = environment["LIMACTL"], !explicit.isEmpty { candidates.append(explicit) }
        candidates += extraPaths.map { "\($0)/limactl" }
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/limactl" }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// The process environment limactl runs with (also used for the embedded terminal).
    public var environment: [String: String] { runner.environment }

    // MARK: - Queries

    public func version() async throws -> String {
        let out = try await runner.run(["--version"]).stdoutString
        // "limactl version 2.2.1"
        return out.split(separator: " ").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? out
    }

    public func list() async throws -> [LimaInstance] {
        let out = try await runner.run(["list", "--format=json", "--tty=false"])
        return try LimaInstance.decodeList(out.stdout)
    }

    public func templates() async throws -> [String] {
        let out = try await runner.run(["create", "--list-templates", "--tty=false"])
        return out.stdoutString.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Reads the instance's `lima.yaml` as written by `limactl create`.
    public func configYAML(of instance: LimaInstance) throws -> String {
        try String(contentsOf: instance.configURL, encoding: .utf8)
    }

    /// The editable config, combining the raw lima.yaml with the effective config from `list`.
    public func config(of instance: LimaInstance) throws -> InstanceConfig {
        InstanceConfig(raw: try JSONValue.parseYAML(configYAML(of: instance)), effective: instance.config)
    }

    public func disks() async throws -> [LimaDisk] {
        let out = try await runner.run(["disk", "list", "--json", "--tty=false"])
        return try LimaDisk.decodeList(out.stdout)
    }

    // MARK: - Editing (instance must be stopped)

    /// Applies yq expressions with `limactl edit --set`, which validates the result.
    public func edit(_ name: String, set expressions: [String]) -> AsyncThrowingStream<LogEntry, Error> {
        logStream(["edit", name, "--start=false"] + expressions.flatMap { ["--set", $0] })
    }

    /// Replaces lima.yaml with `yaml` through `limactl edit`, so Lima validates it exactly as it
    /// would an interactive edit. limactl only reads a whole document through `$VISUAL`, so we
    /// point that at a script that copies our content into the editor's temp file.
    public func replaceConfig(_ name: String, yaml: String) -> AsyncThrowingStream<LogEntry, Error> {
        let source = Self.workDirectory.appending(path: "edit-\(UUID().uuidString).yaml")
        do {
            try yaml.write(to: source, atomically: true, encoding: .utf8)
            let editor = try Self.copyEditorScript()
            let stream = logStream(["edit", name, "--start=false"], tty: true,
                                   extraEnvironment: ["VISUAL": editor.path, "HANALIMA_EDIT_SOURCE": source.path])
            return AsyncThrowingStream { continuation in
                let task = Task {
                    defer { try? FileManager.default.removeItem(at: source) }
                    do {
                        for try await entry in stream { continuation.yield(entry) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    private static func copyEditorScript() throws -> URL {
        let url = workDirectory.appending(path: "copy-editor.sh")
        let script = "#!/bin/sh\nexec /bin/cp \"$HANALIMA_EDIT_SOURCE\" \"$1\"\n"
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - Disks

    /// `size` uses Lima's syntax, e.g. "20GiB".
    public func createDisk(_ name: String, size: String, format: String = "qcow2") -> AsyncThrowingStream<LogEntry, Error> {
        logStream(["disk", "create", name, "--size=\(size)", "--format=\(format)"])
    }

    public func resizeDisk(_ name: String, size: String) -> AsyncThrowingStream<LogEntry, Error> {
        logStream(["disk", "resize", name, "--size=\(size)"])
    }

    public func deleteDisk(_ name: String) -> AsyncThrowingStream<LogEntry, Error> {
        logStream(["disk", "delete", name])
    }

    // MARK: - Lifecycle (streamed so the UI can show progress)

    public func create(_ options: CreateOptions) -> AsyncThrowingStream<LogEntry, Error> {
        logStream(options.arguments)
    }

    public func start(_ name: String) -> AsyncThrowingStream<LogEntry, Error> {
        logStream(["start", name])
    }

    public func stop(_ name: String, force: Bool = false) -> AsyncThrowingStream<LogEntry, Error> {
        logStream(["stop"] + (force ? ["--force"] : []) + [name])
    }

    public func restart(_ name: String) -> AsyncThrowingStream<LogEntry, Error> {
        logStream(["restart", name])
    }

    public func delete(_ name: String, force: Bool = false) -> AsyncThrowingStream<LogEntry, Error> {
        logStream(["delete"] + (force ? ["--force"] : []) + [name])
    }

    // MARK: - Screenshots

    /// A PNG of the VM's display window. Lima 2.2 supports this only for VZ instances with
    /// `video.display` enabled, while their window is open (the host agent captures it).
    public func screenshot(_ name: String) async throws -> Data {
        let dir = Self.workDirectory.appending(path: "screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(name)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await runner.run(["screenshot", name, "-o", file.path, "--tty=false"])
        return try Data(contentsOf: file)
    }

    // MARK: - Snapshots (QEMU only; see LimaSnapshot)

    public func snapshots(_ name: String) async throws -> [LimaSnapshot] {
        LimaSnapshot.parseList(try await runner.run(["snapshot", "list", name, "--tty=false"]).stdoutString)
    }

    public func createSnapshot(_ name: String, tag: String) -> AsyncThrowingStream<LogEntry, Error> {
        logStream(["snapshot", "create", name, "--tag", tag])
    }

    /// Restores the main disk to `tag`. Changes made after the snapshot are lost.
    public func applySnapshot(_ name: String, tag: String) -> AsyncThrowingStream<LogEntry, Error> {
        logStream(["snapshot", "apply", name, "--tag", tag])
    }

    public func deleteSnapshot(_ name: String, tag: String) -> AsyncThrowingStream<LogEntry, Error> {
        logStream(["snapshot", "delete", name, "--tag", tag])
    }

    // MARK: - Start at login (`limactl autostart`)

    /// The LaunchAgent `limactl autostart enable` writes. Lima itself treats an instance as
    /// registered exactly when this file exists (pkg/autostart, v2.2.1). While registered,
    /// `limactl start`/`stop` go through launchd.
    public static func autostartPlist(for name: String, home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appending(path: "Library/LaunchAgents/io.lima-vm.autostart.\(name).plist")
    }

    public func isAutostartEnabled(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.autostartPlist(for: name).path)
    }

    /// Registers or unregisters `name` to start at login. Doesn't start or stop the VM now.
    public func setAutostart(_ name: String, enabled: Bool) async throws {
        _ = try await runner.run(["autostart", enabled ? "enable" : "disable", name, "--tty=false"])
    }

    /// Kills `limactl watch` processes orphaned by an earlier app instance that was force-quit
    /// (normal quits clean up via `ProcessRunner.terminateBackgroundProcesses()`). Only processes
    /// with our exact arguments whose parent has died (re-parented to launchd) are touched.
    public func terminateOrphanedWatchers() async {
        let ps = ProcessRunner(executableURL: URL(fileURLWithPath: "/bin/ps"), environment: [:])
        guard let out = try? await ps.run(["-axo", "pid=,ppid=,command="]).stdoutString else { return }
        let signature = "\(limactlURL.path) \(Self.watchArguments.joined(separator: " "))"
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, parts[1] == "1", parts[2] == signature, let pid = pid_t(parts[0]) else { continue }
            kill(pid, SIGTERM)
        }
    }

    static let watchArguments = ["watch", "--json", "--tty=false"]

    /// Streams `limactl watch --json` for all instances (including ones created later).
    /// Finishes when the process exits; callers should restart it.
    public func watch() -> AsyncThrowingStream<WatchEvent, Error> {
        let lines = runner.lines(Self.watchArguments, background: true)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let decoder = JSONDecoder()
                do {
                    for try await line in lines {
                        guard case .stdout(let text) = line,
                              let event = try? decoder.decode(WatchEvent.self, from: Data(text.utf8))
                        else { continue }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Command line for an interactive shell in the instance (for a terminal emulator).
    public func shellCommand(_ name: String) -> (executable: String, arguments: [String]) {
        (limactlURL.path, ["shell", name])
    }

    // MARK: -

    /// Runs a command non-interactively with JSON logging and yields its log lines.
    private func logStream(_ arguments: [String], tty: Bool = false,
                           extraEnvironment: [String: String] = [:]) -> AsyncThrowingStream<LogEntry, Error> {
        let lines = runner.lines(arguments + ["--tty=\(tty)", "--log-format=json"],
                                 extraEnvironment: extraEnvironment)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        continuation.yield(LogEntry.parse(line.text))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
