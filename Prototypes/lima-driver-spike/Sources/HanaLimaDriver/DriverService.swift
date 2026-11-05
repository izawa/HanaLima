import Foundation
import GRPCCore
import SwiftProtobuf

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// Each Start owns a signal and an acknowledgement. Stop waits for final writes.
actor DriverState {
    private var instanceJSON = Data()
    private var starts: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var completions: [CheckedContinuation<Void, Never>] = []
    private var shuttingDown = false

    func configure(_ data: Data) { instanceJSON = data }

    func begin() -> (UUID, AsyncStream<Void>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        starts[id] = continuation
        if shuttingDown || !completions.isEmpty { continuation.finish() }
        return (id, stream)
    }

    func finished(_ id: UUID) {
        starts.removeValue(forKey: id)
        if starts.isEmpty {
            let waiters = completions
            completions.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func stop(shutdown: Bool = false) async {
        if shutdown { shuttingDown = true }
        for continuation in starts.values { continuation.finish() }
        if !starts.isEmpty {
            await withCheckedContinuation { completions.append($0) }
        }
    }
}

struct DriverService: Driver.SimpleServiceProtocol {
    let instanceDir: String
    let state: DriverState

    private func empty(_ name: String) -> Google_Protobuf_Empty {
        log("\(name) empty request")
        return .init()
    }

    func validate(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty { empty("Validate") }
    func create(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty { empty("Create") }
    func createDisk(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty { empty("CreateDisk") }
    func delete(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty { empty("Delete") }
    func additionalSetupForSSH(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty { empty("AdditionalSetupForSSH") }
    func guestAgentConn(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty { empty("GuestAgentConn") }

    /// Lima expects the driver to fill the driver-specific defaults (what the vz driver's
    /// fillConfig does): validate dereferences `mountType` afterwards. Also, cidata picks the
    /// usernet DNS (192.168.5.2) only for vmType "vz" and uses QEMU's 192.168.5.3 otherwise,
    /// which gvisor's usernet doesn't serve; an explicit `dns` (and no hostResolver) avoids that.
    func configure(request: SetConfigRequest, context: ServerContext) async throws -> SetConfigResponse {
        log("Configure instance JSON: \(request.instanceConfigJson.count) bytes")
        guard var inst = try JSONSerialization.jsonObject(with: request.instanceConfigJson) as? [String: Any],
              var config = inst["config"] as? [String: Any] else {
            throw RPCError(code: .invalidArgument, message: "instance JSON is not an object with a config")
        }
        if config["mountType"] == nil { config["mountType"] = "virtiofs" }
        var ssh = config["ssh"] as? [String: Any] ?? [:]
        if ssh["overVsock"] == nil { ssh["overVsock"] = false }
        config["ssh"] = ssh
        if (config["dns"] as? [Any])?.isEmpty ?? true {
            config["dns"] = ["192.168.5.2"]
            var resolver = config["hostResolver"] as? [String: Any] ?? [:]
            resolver["enabled"] = false
            config["hostResolver"] = resolver
        }
        var vmOpts = config["vmOpts"] as? [String: Any] ?? [:]
        if vmOpts["vz"] == nil { vmOpts["vz"] = ["rosetta": ["enabled": false, "binFmt": false], "diskImageFormat": "raw"] }
        config["vmOpts"] = vmOpts
        inst["config"] = config
        let out = try JSONSerialization.data(withJSONObject: inst)
        await state.configure(out)
        return .with { $0.instanceConfigJson = out }
    }

    func info(request: Google_Protobuf_Empty, context: ServerContext) async throws -> InfoResponse {
        log("Info empty request")
        let json: [String: Any] = [
            "name": "hanalima", "vsockPort": 0, "virtioPort": "", "instanceDir": instanceDir,
            "features": [
                "dynamicSSHAddress": false, "staticSSHPort": false,
                "skipSocketForwarding": false, "noCloudInit": false,
                "rosettaEnabled": false, "rosettaBinFmt": false,
                "supportedImageFormats": ["raw"],
            ],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return .with { $0.infoJson = bytes }
    }

    func start(request: Google_Protobuf_Empty, response: RPCWriter<StartResponse>, context: ServerContext) async throws {
        log("Start empty request")
        let (id, stopped) = await state.begin()
        do {
            try await response.write(.with { $0.success = true })
            for await _ in stopped {}
            try Task.checkCancellation()
            try await response.write(.with { $0.success = true })
            await state.finished(id)
        } catch {
            await state.finished(id)
            throw error
        }
    }

    func stop(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("Stop empty request")
        await state.stop()
        return .init()
    }

    func bootScripts(request: Google_Protobuf_Empty, context: ServerContext) async throws -> BootScriptsResponse {
        log("BootScripts empty request")
        return .init()
    }

    func sshAddress(request: Google_Protobuf_Empty, context: ServerContext) async throws -> SSHAddressResponse {
        log("SSHAddress empty request")
        return .with { $0.address = "127.0.0.1" }
    }

    func forwardGuestAgent(request: Google_Protobuf_Empty, context: ServerContext) async throws -> ForwardGuestAgentResponse {
        log("ForwardGuestAgent empty request")
        return .with { $0.shouldForward = true }
    }

    func changeDisplayPassword(request: ChangeDisplayPasswordRequest, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("ChangeDisplayPassword password: <redacted>")
        return .init()
    }

    func getDisplayConnection(request: Google_Protobuf_Empty, context: ServerContext) async throws -> GetDisplayConnectionResponse {
        log("GetDisplayConnection empty request")
        return .init()
    }

    func runGUI(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("RunGUI empty request")
        throw RPCError(code: .unimplemented, message: "GUI is not implemented by this spike")
    }

    func createSnapshot(request: CreateSnapshotRequest, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("CreateSnapshot tag: \(request.tag.debugDescription)")
        throw RPCError(code: .unimplemented, message: "Snapshots are not implemented")
    }

    func applySnapshot(request: ApplySnapshotRequest, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("ApplySnapshot tag: \(request.tag.debugDescription)")
        throw RPCError(code: .unimplemented, message: "Snapshots are not implemented")
    }

    func deleteSnapshot(request: DeleteSnapshotRequest, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("DeleteSnapshot tag: \(request.tag.debugDescription)")
        throw RPCError(code: .unimplemented, message: "Snapshots are not implemented")
    }

    func listSnapshots(request: Google_Protobuf_Empty, context: ServerContext) async throws -> ListSnapshotsResponse {
        log("ListSnapshots empty request")
        throw RPCError(code: .unimplemented, message: "Snapshots are not implemented")
    }
}
