import Darwin
import Foundation
import MCPKit

/// The app's end of HanaLima's MCP server (docs/14 §3): `hanalima-mcp` (started by the MCP
/// client) answers `initialize` and `tools/list` itself and brings each tool call here, one per
/// connection on `~/.hanalima/agent.sock`. Listening is off unless the user turns on the setting.
@MainActor
@Observable
final class AgentHost {
    enum State: Equatable {
        case off
        case listening
        /// Another HanaLima (e.g. a development build) holds the socket.
        case otherInstance
        case failed(String)
    }

    private(set) var state: State = .off
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var server: UnixSocketServer?
    @ObservationIgnored private var lock: ListenerLock?
    @ObservationIgnored private let paths = MCPPaths.current()
    /// Jobs and the ledger of what MCP made, kept across launches.
    @ObservationIgnored let agentState: AgentState
    /// The `vm` and `job` tools' jobs and the approvals they wait for.
    let vmJobs: VMJobs
    /// `plan`, `apply` and `delete`.
    let buildJobs: BuildJobs

    init(model: AppModel) {
        self.model = model
        let paths = MCPPaths.current()
        try? paths.ensureHome()
        agentState = AgentState(url: paths.home.appendingPathComponent("agent-state.json"))
        vmJobs = VMJobs(model: model, state: agentState)
        buildJobs = BuildJobs(model: model, state: agentState)
    }

    /// At launch: points `mcp.json` at this app's helper and starts listening if the setting is on.
    func launch() {
        // Screenshot runs (DebugSnapshot) leave the user's mcp.json alone.
        guard ProcessInfo.processInfo.environment["HANALIMA_SNAPSHOT"] == nil else { return }
        writeConfigFile()
        update()
    }

    /// Follows the setting.
    func update() {
        if AppSettings.acceptsAIOperations { start() } else { stop() }
    }

    private func start() {
        guard server == nil else { return }
        do {
            try paths.ensureHome()
            guard let lock = ListenerLock.acquire(at: paths.lock) else {
                state = .otherInstance
                return
            }
            let server = UnixSocketServer(path: paths.socket.path, maxConnections: VMJobs.maxWaits * 2) { [weak self] line, peer in
                await self?.handle(line, peer: peer) ?? Self.encode(AgentResponse(text: "HanaLima is shutting down.", isError: true))
            }
            try server.start()
            self.lock = lock
            self.server = server
            state = .listening
            // A launch by hanalima-mcp may open no window, and the window is what starts the
            // model; the tools need the VM list.
            if let model { Task { await model.bootstrap() } }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        vmJobs.cancelAll()
        buildJobs.cancelAll()
        server?.stop()
        server = nil
        lock?.release()
        lock = nil
        state = .off
    }

    /// Writes `~/.hanalima/mcp.json` for the MCP client, when this app carries the helper.
    private func writeConfigFile() {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/hanalima-mcp")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }
        do {
            try paths.ensureHome()
            _ = try MCPConfigFile.update(at: paths.config, helper: helper)
        } catch {
            NSLog("HanaLima: could not write %@: %@", paths.config.path, "\(error)")
        }
    }

    // MARK: - Calls

    private func handle(_ line: Data, peer: PeerInfo) async -> Data {
        let start = Date()
        let response: AgentResponse
        if let request = try? JSONDecoder().decode(AgentRequest.self, from: line) {
            response = await call(request)
            ToolCallLog.append(ToolCallRecord(
                date: start, tool: request.tool,
                argumentBytes: request.arguments.jsonString().utf8.count,
                resultBytes: response.text.utf8.count,
                durationMs: Date().timeIntervalSince(start) * 1000,
                isError: response.isError, peerPID: peer.pid,
                peerExecutable: peer.pid.flatMap(Self.executablePath(of:))), to: paths.callLog)
        } else {
            response = AgentResponse(text: "Malformed request.", isError: true)
        }
        return Self.encode(response)
    }

    private func call(_ request: AgentRequest) async -> AgentResponse {
        guard let model else { return AgentResponse(text: "HanaLima is shutting down.", isError: true) }
        guard ToolCatalog.tool(named: request.tool) != nil else {
            return AgentResponse(text: "Unknown tool: \(request.tool)", isError: true)
        }
        // A fresh launch loads the VMs, networks and templates a moment later.
        guard await model.waitUntilBootstrapped(timeout: .seconds(20)) else {
            switch model.availability {
            case .missing: return AgentResponse(text: "Lima (limactl) is not installed on this Mac.", isError: true)
            case .failed(let message): return AgentResponse(text: "HanaLima can't run limactl: \(message)", isError: true)
            default: return AgentResponse(text: "HanaLima is still loading; try again in a few seconds.", isError: true)
            }
        }
        do {
            let text: String
            switch request.tool {
            case ToolCatalog.inspect.name: text = try InspectTool(model: model).run(request.arguments)
            case ToolCatalog.vm.name: text = try vmJobs.submit(request.arguments)
            case ToolCatalog.job.name: text = try await vmJobs.job(request.arguments)
            case ToolCatalog.plan.name: text = try buildJobs.plan(request.arguments)
            case ToolCatalog.apply.name: text = try buildJobs.apply(request.arguments)
            case ToolCatalog.delete.name: text = try buildJobs.delete(request.arguments)
            default: return AgentResponse(text: "Not available in this version: \(request.tool)", isError: true)
            }
            return AgentResponse(text: text, isError: false)
        } catch InspectTool.Failure.invalid(let message) {
            return AgentResponse(text: message, isError: true)
        } catch VMJobs.Failure.invalid(let message) {
            return AgentResponse(text: message, isError: true)
        } catch BuildJobs.Failure.invalid(let message) {
            return AgentResponse(text: message, isError: true)
        } catch {
            return AgentResponse(text: "\(error)", isError: true)
        }
    }

    nonisolated private static func encode(_ response: AgentResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data(#"{"text":"encoding failed","isError":true}"#.utf8)
    }

    /// The peer's executable, for the call log (who is driving HanaLima).
    nonisolated private static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
