import Foundation
import Darwin
import Testing
@testable import MCPKit

private func connectRaw(_ path: String) throws -> Int32 {
    var address = try UnixSocketIO.address(path)
    let fd = try UnixSocketIO.socket()
    guard UnixSocketIO.withAddress(&address, { Darwin.connect(fd, $0, $1) }) == 0 else {
        let code = errno
        close(fd)
        throw UnixSocketError.system(code)
    }
    return fd
}

@Test func socketRoundTrip() throws {
    let dir = try TestDirectory()
    let server = UnixSocketServer(path: dir.socket) { line, peer in
        #expect(peer.uid == getuid())
        #expect(peer.pid == getpid())
        let request = try! JSONDecoder().decode(AgentRequest.self, from: line)
        #expect(request.tool == "inspect")
        return try! JSONEncoder().encode(AgentResponse(text: request.arguments.jsonString(), isError: false))
    }
    try server.start()
    defer { server.stop() }
    let input = try JSONEncoder().encode(AgentRequest(tool: "inspect", arguments: ["value": "日本語"]))
    let data = try UnixSocketClient.request(path: dir.socket, line: input, timeout: 2)
    let response = try JSONDecoder().decode(AgentResponse.self, from: data)
    #expect(response.text == #"{"value":"日本語"}"#)
    #expect(!response.isError)
    let mode = try FileManager.default.attributesOfItem(atPath: dir.socket)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    server.stop()
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: dir.socket))
    try server.start()
}

@Test func oversizedRequestAndFirstNewline() throws {
    let dir = try TestDirectory()
    let server = UnixSocketServer(path: dir.socket, maxRequestBytes: 4) { line, _ in line }
    try server.start()
    defer { server.stop() }
    #expect(throws: UnixSocketError.connectionLost) {
        try UnixSocketClient.request(path: dir.socket, line: Data("12345".utf8), timeout: 2)
    }
    let boundary = try UnixSocketClient.request(path: dir.socket, line: Data("1234".utf8), timeout: 2)
    #expect(boundary == Data("1234".utf8))
    let first = try UnixSocketClient.request(path: dir.socket, line: Data("ok\nignored".utf8), timeout: 2)
    #expect(first == Data("ok".utf8))
}

@Test func staleSocketAndInUse() throws {
    let dir = try TestDirectory()
    var address = try UnixSocketIO.address(dir.socket)
    let fd = try UnixSocketIO.socket()
    #expect(UnixSocketIO.withAddress(&address, { Darwin.bind(fd, $0, $1) }) == 0)
    close(fd)
    let server = UnixSocketServer(path: dir.socket) { line, _ in line }
    try server.start()
    defer { server.stop() }
    let other = UnixSocketServer(path: dir.socket) { line, _ in line }
    #expect(throws: UnixSocketError.inUse) { try other.start() }
    other.stop()
    #expect(try UnixSocketClient.request(path: dir.socket, line: Data("live".utf8), timeout: 2) == Data("live".utf8))
    #expect(throws: UnixSocketError.inUse) { try server.start() }
}

@Test func socketPathAndNotListening() throws {
    let long = "/tmp/" + String(repeating: "x", count: 99)
    let server = UnixSocketServer(path: long) { line, _ in line }
    #expect(throws: UnixSocketError.pathTooLong) { try server.start() }
    #expect(throws: UnixSocketError.pathTooLong) {
        try UnixSocketClient.request(path: long, line: Data(), timeout: 1)
    }
    let dir = try TestDirectory()
    #expect(throws: UnixSocketError.notListening) {
        try UnixSocketClient.request(path: dir.socket, line: Data(), timeout: 1)
    }
    var address = try UnixSocketIO.address(dir.socket)
    let fd = try UnixSocketIO.socket()
    defer { close(fd) }
    #expect(UnixSocketIO.withAddress(&address, { Darwin.bind(fd, $0, $1) }) == 0)
    #expect(throws: UnixSocketError.notListening) {
        try UnixSocketClient.request(path: dir.socket, line: Data(), timeout: 1)
    }
}

@Test func socketTimeoutAndLostConnection() throws {
    let dir = try TestDirectory()
    let server = UnixSocketServer(path: dir.socket) { _, _ in
        try? await Task.sleep(for: .milliseconds(150))
        return Data("late".utf8)
    }
    try server.start()
    defer { server.stop() }
    #expect(throws: UnixSocketError.timeout) {
        try UnixSocketClient.request(path: dir.socket, line: Data("slow".utf8), timeout: 0.02)
    }
    // The delayed write runs after the client has closed, exercising SO_NOSIGPIPE in the app.
    Thread.sleep(forTimeInterval: 0.2)
    let fd = try connectRaw(dir.socket)
    try UnixSocketIO.write(Data("partial".utf8), to: fd)
    server.stop()
    #expect(throws: UnixSocketError.connectionLost) { try UnixSocketIO.readLine(from: fd) }
    close(fd)
}

@Test func refusesExcessConnections() throws {
    let dir = try TestDirectory()
    let accepted = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let server = UnixSocketServer(path: dir.socket, maxConnections: 1) { line, _ in
        accepted.signal()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { @Sendable in
                release.wait()
                continuation.resume()
            }
        }
        return line
    }
    try server.start()
    defer { release.signal(); server.stop() }
    let first = try connectRaw(dir.socket)
    defer { close(first) }
    try UnixSocketIO.write(Data("first\n".utf8), to: first)
    #expect(accepted.wait(timeout: .now() + 2) == .success)
    #expect(throws: UnixSocketError.connectionLost) {
        try UnixSocketClient.request(path: dir.socket, line: Data("second".utf8), timeout: 2)
    }
}
