import Foundation

/// Stateless framing lets independent requests run concurrently, including pings during a tool call.
public struct MCPSession: Sendable {
    private let callTool: @Sendable (String, JSONValue) async -> ToolCallResult
    private static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public init(callTool: @escaping @Sendable (String, JSONValue) async -> ToolCallResult) {
        self.callTool = callTool
    }

    public func handle(line: String) async -> String? {
        let message: JSONValue
        do { message = try JSONValue.parse(line) }
        catch { return self.error(-32700, "Parse error", id: .null) }
        guard let fields = message.objectValue else { return error(-32600, "Invalid Request", id: .null) }
        let id = fields["id"] ?? .null
        let validID = id.isNull || id.stringValue != nil || id.doubleValue != nil
        guard fields["jsonrpc"] == "2.0", validID else {
            return error(-32600, "Invalid Request", id: validID ? id : .null)
        }
        // Responses and notifications never receive replies (even for unknown methods).
        guard let methodValue = fields["method"] else { return nil }
        guard fields["id"] != nil else { return nil }
        guard let method = methodValue.stringValue else { return error(-32600, "Invalid Request", id: id) }
        if let params = fields["params"], params.objectValue == nil {
            return error(-32602, "Invalid params", id: id)
        }
        let params = fields["params"] ?? [:]
        let result: JSONValue
        switch method {
        case "initialize":
            guard let version = params["protocolVersion"]?.stringValue,
                  params["capabilities"]?.objectValue != nil,
                  let info = params["clientInfo"], info["name"]?.stringValue != nil,
                  info["version"]?.stringValue != nil else {
                return error(-32602, "Invalid params", id: id)
            }
            result = [
                "protocolVersion": .string(Self.versions.contains(version) ? version : Self.versions[0]),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(ToolCatalog.serverName),
                               "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")],
                "instructions": .string(ToolCatalog.instructions),
            ]
        case "ping": result = [:]
        case "tools/list":
            if let cursor = params["cursor"], cursor.stringValue == nil {
                return error(-32602, "Invalid params", id: id)
            }
            result = ["tools": .array(ToolCatalog.tools.map(\.json))]
        case "tools/call":
            guard let name = params["name"]?.stringValue,
                  params["arguments"] == nil || params["arguments"]?.objectValue != nil else {
                return error(-32602, "Invalid params", id: id)
            }
            if ToolCatalog.tool(named: name) == nil {
                result = ToolCallResult(text: "Unknown tool: \(name)", isError: true).json
            } else {
                result = await callTool(name, params["arguments"] ?? [:]).json
            }
        default: return error(-32601, "Method not found", id: id)
        }
        return JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).jsonString()
    }

    private func error(_ code: Int, _ message: String, id: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id,
                          "error": ["code": .number(Double(code)), "message": .string(message)]]).jsonString()
    }
}
