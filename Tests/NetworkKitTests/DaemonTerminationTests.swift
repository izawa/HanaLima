import Foundation
import Testing
@testable import NetworkKit

/// Terminating hanalima-netd while a VM is attached must stop the interface first; otherwise vmnet
/// keeps the subnet reserved until reboot and the next start fails with VMNET_FAILURE (1001).
/// Uses the entitlement-signed helper from `scripts/build-app.sh`; no VM and no en0 involvement.
/// Run with `HANALIMA_E2E=1 swift test --filter DaemonTermination`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DaemonTerminationTests {
    @Test(.timeLimit(.minutes(3)))
    func sigtermReleasesSubnet() async throws {
        let helper = NetworkEndToEndTests.bundledHelper
        try #require(FileManager.default.isExecutableFile(atPath: helper.path), "run scripts/build-app.sh first")

        // Short private support dir so the socket path fits in sockaddr_un.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "hl-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A fresh subnet per run, so a failed run that leaked its subnet can't affect the next one.
        let gateway = "10.251.\(Int.random(in: 1...254)).1"
        try NetworkStore.save([VirtualNetwork(name: "term", gateway: gateway)],
                              to: dir.appending(path: "networks.json"))
        let socket = dir.appending(path: "t.sock").path

        // First run: attach a fake VM, then SIGTERM.
        let first = try Daemon(helper: helper, supportDir: dir, socket: socket)
        let client1 = try first.connectClient(socket: socket)
        try await first.waitForLog("client 1 connected")
        first.terminate()
        let firstLog = await first.waitForExit()
        close(client1)
        #expect(firstLog.contains("stopping 1 interface(s)"), "log:\n\(firstLog)")
        #expect(firstLog.contains("client 1 disconnected"))

        // Second run on the same subnet must come up immediately.
        let second = try Daemon(helper: helper, supportDir: dir, socket: socket)
        let client2 = try second.connectClient(socket: socket)
        defer { close(client2) }
        try await second.waitForLog("client 1 connected", timeout: 10)
        second.terminate()
        let secondLog = await second.waitForExit()
        #expect(!secondLog.contains("retrying"), "log:\n\(secondLog)")
        #expect(secondLog.contains("network term released"))
    }
}

/// A hanalima-netd process in standalone (--socket) mode with captured output.
private final class Daemon: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var output = ""

    init(helper: URL, supportDir: URL, socket: String) throws {
        process.executableURL = helper
        process.arguments = ["--network", "term", "--socket", socket, "--idle-timeout", "0"]
        process.environment = ["HANALIMA_SUPPORT_DIR": supportDir.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let text = String(decoding: fh.availableData, as: UTF8.self)
            self?.lock.withLock { self?.output += text }
        }
        try process.run()
    }

    var log: String { lock.withLock { output } }

    func waitForLog(_ needle: String, timeout: Double = 20) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if log.contains(needle) { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        Issue.record("timed out waiting for \"\(needle)\"; log:\n\(log)")
        throw CancellationError()
    }

    /// Connects like a VM would (the daemon starts a vmnet interface per connection).
    func connectClient(socket path: String) throws -> Int32 {
        for _ in 0..<50 {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                Array(path.utf8CString).withUnsafeBytes { raw.copyMemory(from: $0) }
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if rc == 0 { return fd }
            close(fd)
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw POSIXError(.ECONNREFUSED)
    }

    func terminate() { process.terminate() } // SIGTERM

    func waitForExit() async -> String {
        while process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(200))
        return log
    }
}
