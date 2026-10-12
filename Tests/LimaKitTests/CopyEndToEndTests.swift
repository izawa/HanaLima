import Foundation
import Testing
@testable import LimaKit

/// Copies a real VM the way HanaLima does (`limactl clone`, then `InstanceCopy.finish`) and boots
/// the copy. Run with `HANALIMA_E2E=1 swift test --filter CopyEndToEnd`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct CopyEndToEndTests {
    let vm = "hanalima-e2e-copysrc"
    let copy = "hanalima-e2e-copy"
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(15)))
    func copyBootsWithTheSameDataAndNewIdentity() async throws {
        for name in [vm, copy] { _ = try? await drain(client.delete(name, force: true)) }
        defer { Task { [client, vm, copy] in for name in [vm, copy] { _ = try? await drain(client.delete(name, force: true)) } } }

        // A hand-set MAC on the second NIC must not be copied.
        let mac = "52:55:55:e2:e0:01"
        _ = try await drain(client.create(CreateOptions(
            name: vm, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10, vmType: .vz, mountNone: true,
            setExpressions: [#".networks = [{"vzNAT": true, "macAddress": "\#(mac)"}]"#])))
        _ = try await drain(client.start(vm))
        _ = try await client.runner.run(["shell", vm, "sudo", "sh", "-c", "echo original > /root/marker && sync"])
        _ = try await drain(client.stop(vm))
        let source = try #require(try await client.list().first { $0.name == vm })
        let sourceDir = URL(filePath: source.dir, directoryHint: .isDirectory)
        let records = InstanceMetadata.reconcile([(vm, sourceDir)])
        let config = try String(contentsOf: sourceDir.appending(path: "lima.yaml"), encoding: .utf8)

        let started = Date.now
        _ = try await drain(client.clone(vm, as: copy, set: InstanceCopy.cloneExpressions(sourceConfig: config)))
        let copyDir = sourceDir.deletingLastPathComponent().appending(path: copy, directoryHint: .isDirectory)
        let record = try await InstanceCopy.finish(copyDir: copyDir, name: copy, source: records[vm],
                                                   sourceName: vm, note: "e2e") { _ in }
        #expect(Date.now.timeIntervalSince(started) < 30)  // an APFS clone, not a byte copy
        #expect(record.parent?.id == records[vm]?.id)
        #expect(InstanceMetadata.load(instanceDir: copyDir) == record)
        #expect(StorageReport.allocatedSize(of: copyDir.appending(path: "ha.stderr.log")) == 0)

        let listed = try await client.list()
        let copied = try #require(listed.first { $0.name == copy })
        let macs = { (i: LimaInstance) in (i.networks ?? []).compactMap(\.macAddress) }
        #expect(macs(source).contains(mac))
        #expect(!macs(copied).contains(mac))
        #expect(!(try String(contentsOf: copyDir.appending(path: "lima.yaml"), encoding: .utf8)).contains(mac))

        _ = try await drain(client.start(copy))
        let out = try await client.runner.run(["shell", copy, "sh", "-c", "hostname; sudo cat /root/marker"]).stdoutString
        #expect(out.contains("lima-\(copy)"))
        #expect(out.contains("original"))
        _ = try await client.runner.run(["shell", copy, "sudo", "sh", "-c", "echo changed > /root/marker && sync"])
        _ = try await drain(client.stop(copy))

        // The original is untouched by the copy's writes.
        _ = try await drain(client.start(vm))
        let back = try await client.runner.run(["shell", vm, "sudo", "cat", "/root/marker"]).stdoutString
        #expect(back.contains("original"))
        _ = try await drain(client.stop(vm))
        for name in [vm, copy] { _ = try await drain(client.delete(name, force: true)) }
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
