import Darwin
import Foundation
import MCPKit
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct MCPEndToEndTests {
    @Test(.timeLimit(.minutes(25)))
    func buildOperateAndDeleteTopology() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let home = root.appending(path: "build/mcp-e2e")
        let log = home.appending(path: "app.log")
        do {
            let files = FileManager.default
            let app = root.appending(path: "build/HanaLima.app")
            try require(files.fileExists(atPath: app.path), "Run scripts/build-app.sh first (debug build required)")
            // By process name: `-f` would also match any shell whose command line mentions the app.
            let running = try run(URL(filePath: "/usr/bin/pgrep"), ["-x", "HanaLima"])
            try require(running.status == 1, "quit HanaLima first (pgrep status \(running.status): \(running.text))")
            let limactl = try locateLima()
            // Keep the socket path short: sockaddr_un allows only 104 bytes on macOS.
            try require(home.appending(path: "agent.sock").path.utf8.count < 104, "MCP socket path is too long: \(home.path)")
            if files.fileExists(atPath: home.path) { try files.removeItem(at: home) }
            try files.createDirectory(at: home, withIntermediateDirectories: true)
            files.createFile(atPath: log.path, contents: nil)
            let logHandle = try FileHandle(forWritingTo: log)
            defer { try? logHandle.close() }
            let client = Client(helper: app.appending(path: "Contents/Helpers/hanalima-mcp"), home: home, log: logHandle)
            let names = ["hanalima-e2e-mgw", "hanalima-e2e-mc1", "hanalima-e2e-mc2"]
            let process = Process()
            process.executableURL = app.appending(path: "Contents/MacOS/HanaLima")
            process.environment = ProcessInfo.processInfo.environment.merging([
                "HANALIMA_MCP_HOME": home.path, "HANALIMA_MCP_ACCEPT": "1",
                "HANALIMA_MCP_AUTO_APPROVE": "1", "HANALIMA_MCP_LAUNCH": "1",
            ]) { _, new in new }
            process.standardOutput = logHandle
            process.standardError = logHandle
            try process.run()
            // Cleanup must finish inside defer; an unstructured Task could outlive the test.
            defer {
                do {
                    let remaining = try existingVMs(limactl).filter { names.contains($0) }
                    if !remaining.isEmpty {
                        // Only include networks actually created before a possible build failure.
                        let networks = try storedNames("networks", supportFile("networks.json"))
                        let reply = try client.call("delete", arguments: [
                            "key": UUID().uuidString, "vms": remaining,
                            "networks": networks.contains("e2e-mcp") ? ["e2e-mcp"] : [],
                        ])
                        let finished = try client.wait(reply.text, seconds: 120)
                        try require(try jobHeader(finished).state == .succeeded, finished)
                    }
                } catch {
                    logHandle.write(Data("\nMCP cleanup: \(error)\n".utf8))
                }
                stop(process)
                do {
                    for name in try existingVMs(limactl) where names.contains(name) {
                        let result = try run(limactl, ["delete", "--force", name], timeout: 60)
                        try require(result.status == 0, "Fallback deletion of \(name): \(result.text)")
                    }
                    try require(try Set(existingVMs(limactl)).isDisjoint(with: names), "Cleanup left test VMs behind")
                } catch {
                    Issue.record("Cleanup failed: \(error). App log: \(log.path)")
                }
            }

            let deadline = ContinuousClock.now + .seconds(30)
            while !files.fileExists(atPath: home.appending(path: "agent.sock").path),
                  process.isRunning, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            try require(process.isRunning && files.fileExists(atPath: home.appending(path: "agent.sock").path),
                        "HanaLima did not create agent.sock within 30 seconds")
            let listed = try client.request("tools/list")
            let tools = listed["tools"]?.arrayValue ?? []
            try require(tools.count == 7 && Set(tools.compactMap { $0["name"]?.stringValue })
                        == Set(["inspect", "plan", "apply", "vm", "exec", "job", "delete"]),
                        "Unexpected tools/list: \(listed)")
            let context = try client.call("inspect", arguments: [:])
            try require(!context.isError && context.text.contains("# context"), context.text)

            let specText = #"""
            {
              "group":"hanalima-e2e-mcp",
              "defaults":{"template":"alpine","cpus":1,"memoryGiB":1,"diskGiB":10},
              "verifyOutside":"example.com",
              "networks":[{"ref":"e2e-mcp","mode":"guestOnly","cidr":"10.29.0.0/24","router":"hanalima-e2e-mgw"}],
              "vms":[
                {"ref":"hanalima-e2e-mgw","nics":[{"network":"e2e-mcp","ip":"10.29.0.1"}],"gateway":{"allow":["*"]}},
                {"ref":"hanalima-e2e-mc1","usernet":false,"bootstrapUsernet":true,"nics":[{"network":"e2e-mcp"}]},
                {"ref":"hanalima-e2e-mc2","usernet":false,"bootstrapUsernet":true,"nics":[{"network":"e2e-mcp"}]}
              ]
            }
            """#
            func plan(_ text: String) throws -> String {
                let spec = try JSONSerialization.jsonObject(with: Data(text.utf8))
                return try client.call("plan", arguments: ["spec": spec]).text
            }
            let blocked = try plan(specText.replacingOccurrences(of: #","bootstrapUsernet":true"#, with: ""))
            try require(blocked.split(separator: "\n").first?.contains("\tblocked") == true
                        && blocked.split(separator: "\n").contains { $0.hasPrefix("problem\t") && $0.contains("bootstrapUsernet") }, blocked)
            let ready = try plan(specText)
            let header = ready.split(separator: "\n").first?.split(separator: "\t") ?? []
            try require(header.count >= 2 && header[0].hasPrefix("plan ") && header[1] == "ready", ready)
            let planID = String(header[0].dropFirst("plan ".count))
            let applied = try client.call("apply", arguments: ["plan": planID, "key": UUID().uuidString])
            let built = try client.wait(applied.text, seconds: 20 * 60)
            try require(try jobHeader(built).state == .succeeded, built)
            try require(built.split(separator: "\n").contains { $0.hasPrefix("note\t") && $0.contains("verified 9 of 9") }, built)

            let executed = try client.call("exec", arguments: [
                "key": UUID().uuidString, "targets": [names[1]],
                "script": "cat /etc/alpine-release; ip route show default", "wait": 60,
            ])
            try require(try jobHeader(executed.text).state == .succeeded, executed.text)
            try require(executed.text.contains("via 10.29.0.1"), executed.text)
            let stopped = try client.call("vm", arguments: [
                "key": UUID().uuidString, "action": "stop", "group": "hanalima-e2e-mcp", "wait": 120,
            ])
            try require(try jobHeader(stopped.text).state == .succeeded, stopped.text)
            let deleted = try client.call("delete", arguments: [
                "key": UUID().uuidString, "vms": names, "networks": ["e2e-mcp"],
            ])
            let finished = try client.wait(deleted.text, seconds: 120)
            try require(try jobHeader(finished).state == .succeeded, finished)
            try require(try Set(existingVMs(limactl)).isDisjoint(with: names), "limactl still lists test VMs")
            try require(try !storedNames("networks", supportFile("networks.json")).contains("e2e-mcp"), "Network e2e-mcp remains")
            try require(try !storedNames("groups", supportFile("groups.json")).contains("hanalima-e2e-mcp"), "Test group remains")
        } catch {
            Issue.record("MCP E2E failed: \(error). App log: \(log.path)")
        }
    }
}

private struct E2EFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw E2EFailure(description: message) }
}

private struct Client {
    let helper: URL
    let home: URL
    let log: FileHandle

    func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 140) throws -> JSONValue {
        var input = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        input.append(0x0A)
        let result = try run(helper, [], input: input, environment: ProcessInfo.processInfo.environment.merging([
            "HANALIMA_MCP_HOME": home.path, "HANALIMA_MCP_NO_LAUNCH": "1",
        ]) { _, new in new }, diagnostics: log, timeout: timeout)
        try require(result.status == 0, "Helper exited \(result.status): \(result.text)")
        let lines = result.text.split(separator: "\n")
        try require(lines.count == 1, "Expected one JSON-RPC reply: \(result.text)")
        let reply = try JSONValue.parse(String(lines[0]))
        try require(reply["id"] == 1 && reply["error"] == nil && reply["result"] != nil, "Invalid JSON-RPC reply: \(result.text)")
        return reply["result"]!
    }

    func call(_ tool: String, arguments: [String: Any], timeout: TimeInterval = 140) throws -> (text: String, isError: Bool) {
        let result = try request("tools/call", params: ["name": tool, "arguments": arguments], timeout: timeout)
        guard let text = result["content"]?.arrayValue?.first?["text"]?.stringValue,
              let isError = result["isError"]?.boolValue else {
            throw E2EFailure(description: "Malformed tools/call result: \(result)")
        }
        try require(!isError, "\(tool): \(text)")
        return (text, isError)
    }

    func wait(_ initial: String, seconds: Int) throws -> String {
        let deadline = ContinuousClock.now + .seconds(seconds)
        var text = initial
        let id = try jobHeader(text).id
        while try !jobHeader(text).state.isFinished {
            let remaining = (deadline - ContinuousClock.now).components.seconds
            try require(remaining > 0, "Timed out waiting for \(id): \(text)")
            text = try call("job", arguments: ["id": id, "action": "wait", "waitSeconds": min(120, remaining)],
                            timeout: TimeInterval(min(120, remaining)) + 5).text
        }
        return text
    }
}

private func jobHeader(_ text: String) throws -> (id: String, state: JobState) {
    let columns = text.split(separator: "\n").first?.split(separator: "\t") ?? []
    guard columns.count >= 4, columns[0].hasPrefix("job "), let state = JobState(rawValue: String(columns[1])) else {
        throw E2EFailure(description: "Malformed job header: \(text)")
    }
    return (String(columns[0].dropFirst(4)), state)
}

private func supportFile(_ name: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/HanaLima/\(name)")
}

private func storedNames(_ key: String, _ url: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let value = try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
    guard let rows = value[key]?.arrayValue else { throw E2EFailure(description: "Missing \(key) array in \(url.path)") }
    return try rows.map { row in
        guard let name = row["name"]?.stringValue else { throw E2EFailure(description: "Missing name in \(url.path)") }
        return name
    }
}

private func locateLima() throws -> URL {
    let directories = ["/opt/homebrew/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
    for directory in directories {
        let url = URL(filePath: directory).appending(path: "limactl")
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    throw E2EFailure(description: "limactl is missing from /opt/homebrew/bin and PATH")
}

private func existingVMs(_ limactl: URL) throws -> [String] {
    let result = try run(limactl, ["list", "-q"])
    try require(result.status == 0, "limactl list failed: \(result.text)")
    return result.text.split(whereSeparator: \.isWhitespace).map(String.init)
}

private func stop(_ process: Process) {
    if process.isRunning { process.terminate() }
    let deadline = ContinuousClock.now + .seconds(10)
    while process.isRunning, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

private func run(_ executable: URL, _ arguments: [String], input: Data? = nil,
                 environment: [String: String] = ProcessInfo.processInfo.environment,
                 diagnostics: FileHandle? = nil, timeout: TimeInterval = 30) throws -> (status: Int32, text: String) {
    // A file avoids pipe backpressure while we poll the process with a bounded deadline.
    let output = FileManager.default.temporaryDirectory.appending(path: "hanalima-mcp-e2e-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: output) }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = handle
    process.standardError = diagnostics ?? handle
    let stdin = Pipe()
    process.standardInput = stdin
    try process.run()
    defer { if process.isRunning { stop(process) } }
    if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
    try stdin.fileHandleForWriting.close()
    let deadline = ContinuousClock.now + .seconds(timeout)
    while process.isRunning, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.05) }
    try require(!process.isRunning, "Timed out running \(executable.lastPathComponent) \(arguments)")
    process.waitUntilExit()
    return (process.terminationStatus, try String(contentsOf: output, encoding: .utf8))
}
