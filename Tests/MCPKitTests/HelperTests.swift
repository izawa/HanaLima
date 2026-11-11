import Foundation
import Testing
@testable import MCPKit

private func runHelper(home: URL, requests: String) throws -> [JSONValue] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = root.appendingPathComponent(".build/debug/hanalima-mcp")
    var environment = ProcessInfo.processInfo.environment
    environment["HANALIMA_MCP_HOME"] = home.path
    environment["HANALIMA_MCP_NO_LAUNCH"] = "1"
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    let diagnostics = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = diagnostics
    try process.run()
    input.fileHandleForWriting.write(Data(requests.utf8))
    try input.fileHandleForWriting.close()
    let data = try #require(try output.fileHandleForReading.readToEnd())
    process.waitUntilExit()
    #expect(process.terminationReason == .exit)
    #expect(process.terminationStatus == 0)
    #expect(try (diagnostics.fileHandleForReading.readToEnd() ?? Data()).isEmpty)
    return try String(decoding: data, as: UTF8.self).split(separator: "\n").map { try JSONValue.parse(String($0)) }
}

@Test(.timeLimit(.minutes(1)))
func helperStdioAndNoLaunch() throws {
    let dir = try TestDirectory()
    let replies = try runHelper(home: dir.url, requests: """
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
    {"jsonrpc":"2.0","id":2,"method":"ping"}
    {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"inspect"}}
    {"jsonrpc":"2.0","method":"notifications/initialized"}
    
    """)
    #expect(replies.count == 3)
    #expect(replies.first { $0["id"] == 1 }?["result"]?["protocolVersion"] == "2025-11-25")
    #expect(replies.first { $0["id"] == 2 }?["result"] == [:])
    #expect(replies.first { $0["id"] == 3 }?["result"]?["isError"] == true)
    #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("agent.sock").path))
}

@Test(.timeLimit(.minutes(1)))
func helperHandlesPingDuringSlowCallAndDrainsAtEOF() throws {
    let dir = try TestDirectory()
    let server = UnixSocketServer(path: dir.url.appendingPathComponent("agent.sock").path) { line, _ in
        let request = try! JSONDecoder().decode(AgentRequest.self, from: line)
        #expect(request.tool == "inspect")
        try? await Task.sleep(for: .milliseconds(300))
        return try! JSONEncoder().encode(AgentResponse(text: "finished", isError: false))
    }
    try server.start()
    defer { server.stop() }
    let replies = try runHelper(home: dir.url, requests: """
    {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"inspect"}}
    {"jsonrpc":"2.0","id":2,"method":"ping"}
    {"jsonrpc":"2.0","method":"notifications/initialized"}
    
    """)
    #expect(replies.count == 2)
    #expect(replies.first?["id"] == 2)
    #expect(replies.last?["id"] == 1)
    #expect(replies.last?["result"] == ToolCallResult(text: "finished").json)
}
