import Foundation
import Darwin
import MCPKit

/// Runtime closures live outside top-level main-actor isolation because I/O runs on worker threads.
private final class HelperRuntime: Sendable {
    private let outputLock = NSLock()

    func run() {
        let session = MCPSession { @Sendable name, arguments in
            // Socket operations may block for minutes; never occupy a cooperative executor thread.
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { @Sendable in
                    continuation.resume(returning: Self.callTool(name, arguments: arguments))
                }
            }
        }
        let pending = DispatchGroup()
        while let line = readLine() {
            pending.enter()
            Task.detached { @Sendable [self] in
                defer { pending.leave() }
                if let reply = await session.handle(line: line) {
                    outputLock.withLock {
                        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
                    }
                }
            }
        }
        pending.wait()
    }

    private static func callTool(_ name: String, arguments: JSONValue) -> ToolCallResult {
        do {
            let request = try JSONEncoder().encode(AgentRequest(tool: name, arguments: arguments))
            let response: Data
            do {
                response = try UnixSocketClient.request(path: MCPPaths.current().socket.path, line: request, timeout: 600)
            } catch UnixSocketError.notListening {
                return try launchAndRetry(request)
            }
            return try decode(response)
        } catch UnixSocketError.connectionLost {
            return ToolCallResult(text: "The connection to HanaLima was lost; whether the call took effect is unknown.", isError: true)
        } catch {
            return ToolCallResult(text: "HanaLima request failed: \(error)", isError: true)
        }
    }

    private static func decode(_ data: Data) throws -> ToolCallResult {
        let response = try JSONDecoder().decode(AgentResponse.self, from: data)
        return ToolCallResult(text: response.text, isError: response.isError)
    }

    private static func launchAndRetry(_ request: Data) throws -> ToolCallResult {
        let enabled = CFPreferencesCopyAppValue("acceptAIOperations" as CFString,
                                                "org.izawa.HanaLima" as CFString) as? Bool ?? false
        guard enabled else {
            return ToolCallResult(text: "HanaLima is not accepting AI operations. Ask the user to turn on “Accept Operations from AI” in HanaLima’s settings.", isError: true)
        }
        guard ProcessInfo.processInfo.environment["HANALIMA_MCP_NO_LAUNCH"] != "1",
              let app = containingApp() else {
            return ToolCallResult(text: "Start HanaLima to accept AI operations, then try again.", isError: true)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "--env", "HANALIMA_MCP_LAUNCH=1", app.path]
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            do {
                let response = try UnixSocketClient.request(path: MCPPaths.current().socket.path, line: request, timeout: 600)
                return try decode(response)
            } catch UnixSocketError.notListening {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        return ToolCallResult(text: "HanaLima did not start accepting within 15 s; try again.", isError: true)
    }

    private static func containingApp() -> URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let executable = URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath()
        let helpers = executable.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard executable.lastPathComponent == "hanalima-mcp", helpers.lastPathComponent == "Helpers",
              contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
        return app
    }
}

HelperRuntime().run()
