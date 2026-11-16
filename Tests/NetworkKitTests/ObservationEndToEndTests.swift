import Foundation
import LimaKit
import Testing
@testable import NetworkKit

/// Observing a guest-only network (docs/17) with the real helper and two Alpine VMs: a capture
/// started through the control socket before the VMs boot (launchd starts the helper for it)
/// records their DHCP and a ping between them, and the status file counts each VM's frames.
/// Needs `scripts/build-app.sh` first.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct ObservationEndToEndTests {
    var network: VirtualNetwork {
        VirtualNetwork(name: "e2e-observe", mode: .guestOnly, gateway: "192.168.235.254", prefixLength: 24)
    }
    let vms = ["hanalima-e2e-obs-a", "hanalima-e2e-obs-b"]
    let agents = LaunchAgentManager()
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    static var bundledHelper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/HanaLima.app/Contents/Helpers/hanalima-netd")
    }

    @Test(.timeLimit(.minutes(15)))
    func countsAndCapturesTheSegment() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.bundledHelper.path), "run scripts/build-app.sh first")
        try HelperInstaller.installIfNeeded(from: Self.bundledHelper)
        let network = network
        var saved = try NetworkStore.load().filter { $0.name != network.name }
        let original = saved
        saved.append(network)
        try NetworkStore.save(saved)
        defer {
            agents.uninstall(network.name)
            try? NetworkStore.save(original)
        }
        try agents.install(network)
        let control = NetworkPaths.control(for: network.name).path

        // Before any VM: the control socket starts the helper.
        let started = try NetdControl.send(.init(op: .startCapture), to: control)
        let capture = try #require(started.capture)
        defer {
            for suffix in ["", ".partial", ".json"] { try? FileManager.default.removeItem(atPath: capture.file + suffix) }
        }
        #expect(throws: NetdControl.Failure.self) { try NetdControl.send(.init(op: .startCapture), to: control) }

        for vm in vms { _ = try? await drain(client.delete(vm, force: true)) }
        defer { E2ECleanup.deleteInstances(vms) }
        for vm in vms {
            _ = try await drain(client.create(CreateOptions(name: vm, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10, vmType: .vz)))
            _ = try await drain(client.edit(vm, set: [#".networks = [{"socket":"\#(network.socketPath)"}]"#]))
        }
        for vm in vms { _ = try await drain(client.start(vm)) }
        let b = try await lima0Address(vms[1])
        _ = try await lima0Address(vms[0])
        // A ping to find in the capture (busybox's ping has no -p for a pattern).
        #expect(try await sh(vms[0], "ping -c 3 -W 2 \(b) >/dev/null && echo ok") == "ok")
        try await Task.sleep(for: .seconds(2))

        let status = try #require(NetworkDaemonStatus.load(for: network.name)?.observation)
        let live = status.ports.filter(\.connected)
        #expect(live.count == 2)
        #expect(live.allSatisfy { $0.fromGuest.frames > 0 && $0.toGuest.frames > 0 })
        #expect(status.answered.frames > 0, "netd answered DHCP")
        #expect(status.capture?.id == capture.id && status.capture?.endedAt == nil)

        let stopped = try NetdControl.send(.init(op: .stopCapture, capture: capture.id), to: control)
        #expect(stopped.capture?.reason == "stopped")
        let data = try Data(contentsOf: URL(filePath: capture.file))
        #expect(!FileManager.default.fileExists(atPath: capture.file + ".partial"))
        let frames = Self.frames(in: data)
        #expect(frames.count > 10)
        #expect(frames.contains { Self.isUDP($0, port: 67) }, "a DHCP request")
        #expect(frames.contains { Self.isUDP($0, port: 68) }, "netd's DHCP answer")
        let target = b.split(separator: ".").compactMap { UInt8($0) }
        #expect(frames.contains { $0.count > 34 && $0[12] == 0x08 && $0[13] == 0x00 && $0[23] == 1 && Array($0[30..<34]) == target },
                "the ping to the other VM")
        #expect(FileManager.default.fileExists(atPath: capture.file + ".json"))

        for vm in vms { _ = try await drain(client.stop(vm)) }
    }

    /// Ethernet frames of a classic little-endian pcap file.
    static func frames(in data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        guard bytes.count >= 24 else { return [] }
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        var out: [[UInt8]] = []
        var at = 24
        while at + 16 <= bytes.count {
            let length = u32(at + 8)
            guard at + 16 + length <= bytes.count else { break }
            out.append(Array(bytes[(at + 16)..<(at + 16 + length)]))
            at += 16 + length
        }
        return out
    }

    /// IPv4 UDP to `port`.
    static func isUDP(_ f: [UInt8], port: Int) -> Bool {
        guard f.count > 42, f[12] == 0x08, f[13] == 0x00, f[23] == 17 else { return false }
        let ihl = Int(f[14] & 0x0f) * 4
        guard f.count > 14 + ihl + 4 else { return false }
        return Int(f[14 + ihl + 2]) << 8 | Int(f[14 + ihl + 3]) == port
    }

    private func lima0Address(_ vm: String) async throws -> String {
        for _ in 0..<30 {
            let out = try await sh(vm, "ip -4 -o addr show lima0 2>/dev/null")
            if let m = out.firstMatch(of: /inet (\d+\.\d+\.\d+\.\d+)/) { return String(m.1) }
            try await Task.sleep(for: .seconds(2))
        }
        throw NSError(domain: "e2e", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(vm): no address on lima0"])
    }

    private func sh(_ vm: String, _ script: String) async throws -> String {
        let out = try? await client.runner.run(["shell", vm, "sh", "-c", script])
        return (out?.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
