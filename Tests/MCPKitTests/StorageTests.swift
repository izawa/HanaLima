import Foundation
import Darwin
import Testing
@testable import MCPKit

@Test func listenerLockExclusivity() throws {
    let dir = try TestDirectory()
    let path = dir.url.appendingPathComponent("lock")
    let first = try #require(ListenerLock.acquire(at: path))
    #expect(ListenerLock.acquire(at: path) == nil)
    first.release()
    first.release()
    var second = ListenerLock.acquire(at: path)
    #expect(second != nil)
    second = nil
    let third = try #require(ListenerLock.acquire(at: path))
    third.release()
}

@Suite(.serialized)
struct PathsTests {
    @Test func overrideAndPermissions() throws {
        let dir = try TestDirectory()
        let old = getenv("HANALIMA_MCP_HOME").map { String(cString: $0) }
        setenv("HANALIMA_MCP_HOME", dir.url.appendingPathComponent("home").path, 1)
        defer {
            if let old { setenv("HANALIMA_MCP_HOME", old, 1) }
            else { unsetenv("HANALIMA_MCP_HOME") }
        }
        let paths = MCPPaths.current()
        #expect(paths.home.path == dir.url.appendingPathComponent("home").path)
        #expect(paths.socket.lastPathComponent == "agent.sock")
        #expect(paths.config.lastPathComponent == "mcp.json")
        #expect(paths.lock.lastPathComponent == "agent.lock")
        #expect(paths.callLog.lastPathComponent == "calls.jsonl")
        try paths.ensureHome()
        #expect(try permissions(paths.home) == 0o700)
        chmod(paths.home.path, 0o755)
        try paths.ensureHome()
        #expect(try permissions(paths.home) == 0o700)
    }
}

private func permissions(_ url: URL) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

private func readJSON(_ url: URL) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

@Test func configMissingMalformedAndUnreadable() throws {
    let dir = try TestDirectory()
    let url = dir.url.appendingPathComponent("config")
    let helper = dir.url.appendingPathComponent("helper")
    #expect(try MCPConfigFile.update(at: url, helper: helper))
    #expect(try readJSON(url) == ["mcpServers": ["hanalima": ["command": .string(helper.path), "args": []]]])
    #expect(try permissions(url) == 0o600)
    let before = try Data(contentsOf: url)
    #expect(try !MCPConfigFile.update(at: url, helper: helper))
    #expect(try Data(contentsOf: url) == before)
    try Data("not JSON".utf8).write(to: url)
    #expect(try MCPConfigFile.update(at: url, helper: helper))
    // A dangling symlink is an unreadable config; the atomic rename replaces it.
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: dir.url.appendingPathComponent("absent").path)
    #expect(try MCPConfigFile.update(at: url, helper: helper))
    #expect(try permissions(url) == 0o600)
}

@Test(arguments: ["bundle", "existing", "missing", "same", "absentCommand"])
func configCommandRules(kind: String) throws {
    let dir = try TestDirectory()
    let url = dir.url.appendingPathComponent("config")
    let helper = dir.url.appendingPathComponent("New.app/Contents/Helpers/hanalima-mcp")
    let old: URL
    switch kind {
    case "bundle": old = dir.url.appendingPathComponent("Old.app/Contents/Helpers/hanalima-mcp")
    case "same": old = helper
    default: old = dir.url.appendingPathComponent("custom-helper")
    }
    if kind == "bundle" || kind == "existing" {
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: old)
    }
    var entry: JSONValue = ["command": .string(old.path), "args": ["custom"], "extra": true]
    if kind == "absentCommand" { entry = ["args": ["custom"], "extra": true] }
    let original: JSONValue = ["other": ["retained": 42], "mcpServers": [
        "other-server": ["command": "/elsewhere", "args": ["x"]], "hanalima": entry,
    ]]
    try Data(original.jsonString().utf8).write(to: url)
    chmod(url.path, 0o644)
    let changed = try MCPConfigFile.update(at: url, helper: helper)
    #expect(changed == (kind != "existing" && kind != "same"))
    let actual = try readJSON(url)
    #expect(actual["other"] == original["other"])
    #expect(actual["mcpServers"]?["other-server"] == original["mcpServers"]?["other-server"])
    #expect(actual["mcpServers"]?["hanalima"]?["args"] == ["custom"])
    #expect(actual["mcpServers"]?["hanalima"]?["extra"] == true)
    #expect(actual["mcpServers"]?["hanalima"]?["command"]?.stringValue == (changed ? helper.path : old.path))
    #expect(try permissions(url) == (changed ? 0o600 : 0o644))
}

@Test func callLogContainsMetadataOnly() throws {
    let dir = try TestDirectory()
    let url = dir.url.appendingPathComponent("calls")
    let record = ToolCallRecord(date: Date(timeIntervalSince1970: 1_000), tool: "inspect", argumentBytes: 12,
                               resultBytes: 34, durationMs: 5.5, isError: false,
                               peerPID: getpid(), peerExecutable: "/test/helper")
    DispatchQueue.concurrentPerform(iterations: 20) { _ in ToolCallLog.append(record, to: url) }
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 20)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    for line in lines {
        let decoded = try decoder.decode(ToolCallRecord.self, from: Data(line.utf8))
        #expect(decoded.date == record.date)
        #expect(decoded.peerPID == getpid())
        #expect(decoded.peerExecutable == "/test/helper")
        #expect(decoded.argumentBytes == 12)
        #expect(decoded.resultBytes == 34)
        #expect(decoded.durationMs == 5.5)
        let json = try JSONValue.parse(String(line))
        #expect(Set(json.objectValue!.keys) == Set(["date", "tool", "argumentBytes", "resultBytes", "durationMs", "isError", "peerPID", "peerExecutable"]))
    }
    #expect(try permissions(url) == 0o600)
    ToolCallLog.append(record, to: dir.url.appendingPathComponent("missing/log"))
}

@Test func configPreservesLargeIntegers() throws {
    let dir = try TestDirectory()
    let url = dir.url.appendingPathComponent("config")
    try Data(#"{"other":9007199254740993,"mcpServers":{"hanalima":{"command":"/missing-helper"}}}"#.utf8).write(to: url)
    #expect(try MCPConfigFile.update(at: url, helper: dir.url.appendingPathComponent("helper")))
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect((object?["other"] as? NSNumber)?.stringValue == "9007199254740993")
}
