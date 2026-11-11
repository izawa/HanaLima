import Foundation

/// Each socket connection carries exactly one request and one response.
public struct AgentRequest: Codable, Sendable {
    public let tool: String
    public let arguments: JSONValue

    public init(tool: String, arguments: JSONValue) {
        self.tool = tool
        self.arguments = arguments
    }
}

public struct AgentResponse: Codable, Sendable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

public struct ToolCallResult: Sendable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public var json: JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }
}
