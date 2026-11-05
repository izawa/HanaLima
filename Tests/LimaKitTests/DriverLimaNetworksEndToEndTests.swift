import Foundation
import Testing
@testable import LimaKit

/// Lima's own `lima:` networks on HanaLima's driver (docs/09, item 2). user-v2 is Lima's shared
/// usernet (no root): as the instance's first usernet network it takes NIC 0's place, Lima
/// starts the shared daemon under `_networks/user-v2/` before Start, and SSH, DHCP and DNS go
/// through it. socket_vmnet networks (`lima:shared` …) use the same stream relay as `socket:`
/// at `<varRun>/socket_vmnet.<name>`; they need root-started daemons, so they're not exercised here.
///
/// Needs `scripts/build-app.sh` first. Alpine, one boot.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DriverLimaNetworksEndToEndTests {
    let vm = "hanalima-e2e-userv2"
    static let helpers = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/Helpers")
    let client = LimaClient(limactlURL: LimaClient.locate()!,
                            environment: ProcessInfo.processInfo.environment.merging(["LIMA_DRIVERS_PATH": helpers.path]) { $1 })

    @Test(.timeLimit(.minutes(10)))
    func userV2NetworkIsNIC0() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "lima-driver-hanalima").path),
                     "run scripts/build-app.sh first")
        let networks = LimaNetworks.load()
        try #require(networks.network(named: "user-v2") != nil, "networks.yaml defines user-v2")
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm], environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }
        _ = try await drain(client.create(CreateOptions(name: vm, template: "alpine", cpus: 2, memoryGiB: 2, diskGiB: 10, vmType: .hanalima,
                                                        setExpressions: [#".networks = [{"lima": "user-v2"}]"#])))
        let created = try #require(try await client.list().first { $0.name == vm })
        let dir = URL(filePath: created.dir, directoryHint: .isDirectory)
        let started = Date.now
        _ = try await drain(client.start(vm))
        print("user-v2: boot \(Int(Date.now.timeIntervalSince(started))) s")
        let log = (try? String(contentsOf: dir.appending(path: "driver.stderr.log"), encoding: .utf8)) ?? ""
        #expect(log.contains("NIC 0 on Lima's user-v2 network user-v2"))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "default_ep.sock").path), "no per-instance usernet")
        #expect(FileManager.default.fileExists(atPath: LimaNetworks.usernetSocket(limaHome: LimaNetworks.limaHome, network: "user-v2", kind: "ep")))
        // The guest sits on the shared network: an address from its subnet, DNS at its gateway.
        let gateway = LimaNetworks.usernetGateway(of: networks.network(named: "user-v2")!)!
        let subnetPrefix = gateway.split(separator: ".").prefix(3).joined(separator: ".") + "."
        #expect(try await sh("ip -4 -o addr show eth0 | grep -c '\(subnetPrefix)'") == "1")
        #expect(try await sh("grep -c '\(gateway)' /etc/resolv.conf") == "1")
        #expect(try await sh("nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1 && echo ok") == "ok")
        #expect(try await sh("ping -c1 -W2 \(gateway) >/dev/null 2>&1 && echo ok") == "ok")
        _ = try await drain(client.stop(vm))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "hanalima.pid").path))
    }

    private func sh(_ script: String) async throws -> String {
        let out = try? await client.runner.run(["shell", vm, "sh", "-c", script])
        if out == nil { print("failed: \(script.prefix(80))") }
        return (out?.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
