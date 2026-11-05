import Foundation
import GRPCCore
import SwiftProtobuf

/// Lima's `Driver` service (driver.proto) on top of DriverCore. Lima calls, on the start path:
/// Configure → Validate → Create → CreateDisk → Start → AdditionalSetupForSSH, and polls Info
/// from background goroutines while the VM runs (so nothing here may block on the VM).
struct DriverService: Driver.SimpleServiceProtocol {
    let core: DriverCore

    func info(request: Google_Protobuf_Empty, context: ServerContext) async throws -> InfoResponse {
        // cidata takes the Rosetta flags from here (LIMA_CIDATA_ROSETTA_ENABLED/_BINFMT).
        let spec = await core.spec
        let json: [String: Any] = [
            "name": "hanalima", "vsockPort": Int(InstanceSpec.guestAgentVsockPort), "virtioPort": "", "instanceDir": core.instanceDir.path,
            "features": [
                "dynamicSSHAddress": false, "staticSSHPort": false, "skipSocketForwarding": false,
                "noCloudInit": false, "rosettaEnabled": spec?.rosetta ?? false, "rosettaBinFmt": spec?.rosettaBinFmt ?? false,
                "supportedImageFormats": ["raw"],
            ],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return .with { $0.infoJson = bytes }
    }

    func configure(request: SetConfigRequest, context: ServerContext) async throws -> SetConfigResponse {
        log("Configure (\(request.instanceConfigJson.count) bytes)")
        let out = try await wrap { try await core.configure(request.instanceConfigJson) }
        return .with { $0.instanceConfigJson = out }
    }

    func validate(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("Validate")
        try await wrap { try await core.validate() }
        return .init()
    }

    func create(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("Create")
        try await wrap { try await core.create() }
        return .init()
    }

    func createDisk(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("CreateDisk")
        try await wrap { try await core.createDisk() }
        return .init()
    }

    /// Streams: one success once the VM runs, then a final success (or the error) when it stops.
    func start(request: Google_Protobuf_Empty, response: RPCWriter<StartResponse>, context: ServerContext) async throws {
        log("Start")
        let stopped: AsyncStream<Error?>
        do {
            stopped = try await core.start()
        } catch {
            log("Start failed: \(error)")
            try await response.write(.with { $0.success = false; $0.error = "\(error)" })
            return
        }
        try await response.write(.with { $0.success = true })
        for await error in stopped {
            if let error {
                try await response.write(.with { $0.success = false; $0.error = "\(error)" })
            }
        }
        try await response.write(.with { $0.success = true })
    }

    func additionalSetupForSSH(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("AdditionalSetupForSSH")
        try await wrap { try await core.waitForSSH() }
        return .init()
    }

    func stop(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("Stop")
        try await wrap { try await core.stop() }
        return .init()
    }

    func delete(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("Delete")
        return .init()
    }

    /// Scripts added to cidata's boot.Linux (see BootScripts).
    func bootScripts(request: Google_Protobuf_Empty, context: ServerContext) async throws -> BootScriptsResponse {
        .with { $0.scripts = BootScripts.all.mapValues { Data($0.utf8) } }
    }

    func sshAddress(request: Google_Protobuf_Empty, context: ServerContext) async throws -> SSHAddressResponse {
        .with { $0.address = "127.0.0.1" }
    }

    /// false: the guest agent is reached over vsock, bridged to `ga.sock` (see GuestAgentConn).
    func forwardGuestAgent(request: Google_Protobuf_Empty, context: ServerContext) async throws -> ForwardGuestAgentResponse {
        .with { $0.shouldForward = false }
    }

    func guestAgentConn(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("GuestAgentConn")
        try await wrap { try await core.ensureGuestAgentBridge() }
        return .init()
    }

    func changeDisplayPassword(request: ChangeDisplayPasswordRequest, context: ServerContext) async throws -> Google_Protobuf_Empty {
        .init()
    }

    func getDisplayConnection(request: Google_Protobuf_Empty, context: ServerContext) async throws -> GetDisplayConnectionResponse {
        .init()
    }

    func runGUI(request: Google_Protobuf_Empty, context: ServerContext) async throws -> Google_Protobuf_Empty {
        throw RPCError(code: .unimplemented, message: "hanalima has no GUI yet")
    }

    // `limactl snapshot`: HanaLima's APFS-clone snapshots (DiskSnapshot), shared with the app.
    func createSnapshot(request: CreateSnapshotRequest, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("CreateSnapshot \(request.tag)")
        try await wrap { try await core.snapshotCreate(tag: request.tag) }
        return .init()
    }

    func applySnapshot(request: ApplySnapshotRequest, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("ApplySnapshot \(request.tag)")
        try await wrap { try await core.snapshotApply(tag: request.tag) }
        return .init()
    }

    func deleteSnapshot(request: DeleteSnapshotRequest, context: ServerContext) async throws -> Google_Protobuf_Empty {
        log("DeleteSnapshot \(request.tag)")
        try await wrap { try await core.snapshotDelete(tag: request.tag) }
        return .init()
    }

    func listSnapshots(request: Google_Protobuf_Empty, context: ServerContext) async throws -> ListSnapshotsResponse {
        let text = await core.snapshotList()
        return .with { $0.snapshots = text }
    }

    /// Driver errors become gRPC statuses with their message (Lima logs the message).
    private func wrap<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let error as RPCError { throw error } catch {
            log("error: \(error)")
            throw RPCError(code: .internalError, message: "\(error)")
        }
    }
}
