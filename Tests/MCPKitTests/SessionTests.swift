import Foundation
import Testing
@testable import MCPKit

private func session() -> MCPSession {
    MCPSession { name, arguments in
        ToolCallResult(text: name + ":" + arguments.jsonString())
    }
}

private func reply(_ message: JSONValue, using session: MCPSession = session()) async throws -> JSONValue {
    let line = try #require(await session.handle(line: message.jsonString()))
    return try JSONValue.parse(line)
}

@Test(arguments: ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "future"])
func handshake(version: String) async throws {
    let response = try await reply(["jsonrpc": "2.0", "id": "init", "method": "initialize", "params": [
        "protocolVersion": .string(version), "capabilities": [:], "clientInfo": ["name": "test", "version": "1"],
    ]])
    #expect(response["id"] == "init")
    #expect(response["jsonrpc"] == "2.0")
    let result = try #require(response["result"])
    #expect(result["protocolVersion"]?.stringValue == (version == "future" ? "2025-11-25" : version))
    #expect(result["serverInfo"]?["name"]?.stringValue == ToolCatalog.serverName)
    #expect(result["serverInfo"]?["version"]?.stringValue != nil)
    #expect(result["capabilities"] == ["tools": ["listChanged": false]])
    #expect(result["instructions"]?.stringValue == ToolCatalog.instructions)
}

@Test func listAndPing() async throws {
    let list = try await reply(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
    #expect(list["result"]?["tools"] == .array(ToolCatalog.tools.map(\.json)))
    let ping = try await reply(["jsonrpc": "2.0", "id": 3, "method": "ping"])
    #expect(ping["result"] == [:])
}

@Test(arguments: [
    ("{", -32700), ("[]", -32600), ("null", -32600),
    (#"{"id":1,"method":"ping"}"#, -32600),
    (#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, -32600),
    (#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, -32600),
    (#"{"jsonrpc":"2.0","id":1,"method":5}"#, -32600),
    (#"{"jsonrpc":"2.0","id":1,"method":"nope"}"#, -32601),
    (#"{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}"#, -32602),
    (#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#, -32602),
    (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#, -32602),
    (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":2}}"#, -32602),
    (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"inspect","arguments":[]}}"#, -32602),
    (#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":2}}"#, -32602),
])
func protocolErrors(line: String, code: Int) async throws {
    let response = try JSONValue.parse(#require(await session().handle(line: line)))
    #expect(response["error"]?["code"]?.intValue == code)
    #expect(response["jsonrpc"] == "2.0")
    if code == -32700 { #expect(response["id"] == .null) }
}

@Test func notificationsAndResponsesAreSilent() async {
    for line in [
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","method":"nope"}"#,
        #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"inspect"}}"#,
        #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
        #"{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"failed"}}"#,
    ] { #expect(await session().handle(line: line) == nil) }
}

@Test func toolRouting() async throws {
    let s = session()
    let response = try await reply(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
        "name": "inspect", "arguments": ["topics": ["vms"]],
    ]], using: s)
    #expect(response["result"] == ToolCallResult(text: #"inspect:{"topics":["vms"]}"#).json)
    let defaults = try await reply(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "inspect"]], using: s)
    #expect(defaults["result"] == ToolCallResult(text: "inspect:{}").json)
    let unknown = try await reply(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "missing"]], using: s)
    #expect(unknown["result"] == ToolCallResult(text: "Unknown tool: missing", isError: true).json)
    #expect(unknown["error"] == nil)
    let failure = MCPSession { _, _ in ToolCallResult(text: "failed", isError: true) }
    let failed = try await reply(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "inspect"]], using: failure)
    #expect(failed["result"]?["isError"] == true)
    #expect(failed["result"]?["structuredContent"] == nil)
}
