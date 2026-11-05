import Foundation
import Darwin

private func netError(_ message: String) -> NSError {
    NSError(domain: "UsernetClient", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func netSystemError(_ operation: String, errno code: Int32 = errno) -> NSError {
    netError("\(operation): \(String(cString: strerror(code))) (errno \(code))")
}

private func netAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw netError("Invalid or overlong Unix socket path")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}

private func netConfigure(_ fd: Int32, timeout: Int) throws {
    var enabled: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, 4) == 0 else {
        throw netSystemError("setsockopt(SO_NOSIGPIPE)")
    }
    var interval = timeval(tv_sec: timeout, tv_usec: 0)
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
        guard setsockopt(fd, SOL_SOCKET, option, &interval, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw netSystemError("setsockopt(timeout)")
        }
    }
}

private func netWrite(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw netSystemError("send", errno: count < 0 ? errno : EPIPE) }
            offset += count
        }
    }
}

private func netRead(_ fd: Int32) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: 8192)
    var count: Int
    repeat { count = recv(fd, &buffer, buffer.count, 0) } while count < 0 && errno == EINTR
    guard count >= 0 else { throw netSystemError("recv") }
    return Data(buffer.prefix(count))
}

private struct NetMessage {
    let firstLine: String
    let headers: [String: String]
    let body: Data
}

private func netReadMessage(_ fd: Int32, response: Bool) throws -> NetMessage {
    let separator = Data("\r\n\r\n".utf8)
    var data = Data()
    var headerRange: Range<Data.Index>?
    while headerRange == nil {
        let next = try netRead(fd)
        guard !next.isEmpty else { throw netError("EOF before HTTP headers") }
        data.append(next)
        headerRange = data.range(of: separator)
        guard (headerRange?.lowerBound ?? data.count) <= 65536 else { throw netError("HTTP headers too large") }
    }
    let range = headerRange!
    guard let headerText = String(data: data[..<range.lowerBound], encoding: .utf8) else {
        throw netError("Invalid HTTP headers")
    }
    let lines = headerText.components(separatedBy: "\r\n")
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { throw netError("Malformed HTTP header") }
        let key = line[..<colon].lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if key == "content-length", let existing = headers[key], existing != value {
            throw netError("Conflicting Content-Length headers")
        }
        headers[key] = value
    }
    if let transfer = headers["transfer-encoding"], transfer.lowercased() != "identity" {
        throw netError("Unsupported HTTP Transfer-Encoding: \(transfer)")
    }
    var body = Data(data[range.upperBound...])
    if let lengthText = headers["content-length"] {
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(lengthText) else { throw netError("Invalid Content-Length") }
        while body.count < length {
            let next = try netRead(fd)
            guard !next.isEmpty else { throw netError("EOF before Content-Length bytes") }
            body.append(next)
        }
        body = Data(body.prefix(length))
    } else if response {
        while true {
            let next = try netRead(fd)
            if next.isEmpty { break }
            body.append(next)
        }
    }
    return NetMessage(firstLine: lines[0], headers: headers, body: body)
}

// Dispatch workers keep blocking system calls off Swift's cooperative pool.
private func netBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            do { continuation.resume(returning: try work()) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

struct UsernetClient: Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data
    }

    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func get(_ path: String, readTimeoutSeconds: Int = 30) async throws -> Response {
        try await request(method: "GET", path: path, body: nil, timeout: readTimeoutSeconds)
    }

    func post(_ path: String, json: [String: Any]) async throws -> Response {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await request(method: "POST", path: path, body: body, timeout: 30)
    }

    private func request(method: String, path: String, body: Data?, timeout: Int) async throws -> Response {
        guard path.hasPrefix("/"), path.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), timeout > 0 else {
            throw netError("Invalid HTTP request path or timeout")
        }
        return try await netBlocking { [socketPath] in
            var address = try netAddress(socketPath)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw netSystemError("socket") }
            defer { close(fd) }
            try netConfigure(fd, timeout: timeout)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw netSystemError("connect to \(socketPath)") }
            var head = "\(method) \(path) HTTP/1.1\r\nHost: lima\r\nConnection: close\r\n"
            if let body { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
            var wire = Data((head + "\r\n").utf8)
            if let body { wire.append(body) }
            try netWrite(fd, wire)
            let message = try netReadMessage(fd, response: true)
            let status = message.firstLine.split(separator: " ", omittingEmptySubsequences: true)
            guard status.count >= 2, status[0] == "HTTP/1.1" || status[0] == "HTTP/1.0",
                  status[1].count == 3, let code = Int(status[1]), (100...599).contains(code) else {
                throw netError("Invalid HTTP status line: \(message.firstLine)")
            }
            return Response(statusCode: code, body: message.body)
        }
    }

    private func requireOK(_ response: Response) throws {
        guard response.statusCode == 200 else {
            throw netError("HTTP \(response.statusCode): \(String(decoding: response.body, as: UTF8.self))")
        }
    }

    func leases() async throws -> [String: String] {
        let response = try await get("/services/dhcp/leases")
        try requireOK(response)
        return try JSONDecoder().decode([String: String].self, from: response.body)
    }

    func expose(local: String, remote: String, protocol: String = "tcp") async throws {
        let response = try await post("/services/forwarder/expose", json: ["local": local, "remote": remote, "protocol": `protocol`])
        try requireOK(response)
    }

    func unexpose(local: String, protocol: String = "tcp") async throws {
        let response = try await post("/services/forwarder/unexpose", json: ["local": local, "protocol": `protocol`])
        try requireOK(response)
    }

    func waitPort(ip: String, port: Int, timeoutSeconds: Int) async throws {
        guard (1...65535).contains(port), timeoutSeconds >= 0, timeoutSeconds <= Int.max - 5 else {
            throw netError("Invalid port or timeout")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = ip.addingPercentEncoding(withAllowedCharacters: allowed) else { throw netError("Invalid IP address") }
        let response = try await get("/extension/wait_port?ip=\(encoded)&port=\(port)&timeout=\(timeoutSeconds)", readTimeoutSeconds: timeoutSeconds + 5)
        try requireOK(response)
    }

    func addDNS(zone: [String: Any]) async throws {
        let response = try await post("/services/dns/add", json: zone)
        try requireOK(response)
    }
}

func usernetClientSelfTest() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("s").path
    var address = try netAddress(path)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw netSystemError("self-test socket") }
    defer { close(listener) }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0 else { throw netSystemError("self-test bind") }
    guard listen(listener, 4) == 0 else { throw netSystemError("self-test listen") }
    async let server: Void = netBlocking {
        for index in 0..<3 {
            var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&readiness, 1, 5000) > 0 else { throw netError("Self-test accept timed out") }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { throw netSystemError("self-test accept") }
            defer { close(fd) }
            try netConfigure(fd, timeout: 5)
            let request = try netReadMessage(fd, response: false)
            guard request.headers["host"] == "lima", request.headers["connection"] == "close" else {
                throw netError("Self-test missing HTTP headers")
            }
            let body: String
            switch index {
            case 0:
                guard request.firstLine == "GET /services/dhcp/leases HTTP/1.1" else { throw netError("Self-test leases request mismatch") }
                body = "{\"192.168.5.15\":\"52:55:55:00:00:01\"}"
            case 1:
                guard request.firstLine == "POST /services/forwarder/expose HTTP/1.1",
                      request.headers["content-type"] == "application/json",
                      let json = try JSONSerialization.jsonObject(with: request.body) as? [String: String],
                      json == ["local": "127.0.0.1:8080", "remote": "192.168.5.15:80", "protocol": "tcp"] else {
                    throw netError("Self-test expose request mismatch")
                }
                body = "{}"
            default:
                guard request.firstLine == "GET /extension/wait_port?ip=192.168.5.15&port=80&timeout=2 HTTP/1.1" else {
                    throw netError("Self-test waitPort request mismatch")
                }
                Thread.sleep(forTimeInterval: 0.3)
                body = "{}"
            }
            // Exercise both Content-Length framing and EOF framing.
            let length = index == 2 ? "" : "Content-Length: \(body.utf8.count)\r\n"
            let headers = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/json\r\n\(length)\r\n"
            try netWrite(fd, Data(headers.utf8))
            try netWrite(fd, Data(body.utf8))
        }
    }
    let client = UsernetClient(socketPath: path)
    let leases = try await client.leases()
    guard leases == ["192.168.5.15": "52:55:55:00:00:01"] else { throw netError("Self-test leases mismatch") }
    try await client.expose(local: "127.0.0.1:8080", remote: "192.168.5.15:80")
    let clock = ContinuousClock()
    let start = clock.now
    try await client.waitPort(ip: "192.168.5.15", port: 80, timeoutSeconds: 2)
    guard start.duration(to: clock.now) >= .milliseconds(250) else { throw netError("Self-test waitPort returned too early") }
    try await server
}
