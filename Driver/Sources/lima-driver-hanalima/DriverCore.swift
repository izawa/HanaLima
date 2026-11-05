import Foundation
import LimaKit

/// The driver's state for one instance, behind Lima's RPCs (see DriverService): the config
/// Lima sent, the usernet process, the VM, and the SSH forward on usernet.
///
/// A boot is a `Run`; `generation` tells callbacks and a Stop that suspended which run they
/// belong to, so a late one can't tear down a newer boot.
actor DriverCore {
    let instanceDir: URL
    private(set) var spec: InstanceSpec?

    private struct Run {
        let generation: Int
        var usernet: Process?
        var machine: VZMachine?
        var exposedLocal: String?
        /// The VM's end of the usernet socket pair, kept for the VM's lifetime (closeOnDealloc).
        var usernetHandle: FileHandle?
        /// The stream over which usernet got its end (kept open like Lima does).
        var usernetPass: FileHandle?
        /// Relays for `socket:` NICs (closing them ends the relay threads).
        var relays: [FileHandle] = []
        /// Additional disks this run locked (`in_use_by`).
        var lockedDisks: [InstanceSpec.Disk] = []
        /// `ga.sock` → the guest agent's vsock, once Lima asks for it.
        var guestAgentBridge: UnixSocketBridge?
        /// Ends when the guest stops; Start's stream waits on it.
        var stopped: AsyncStream<Error?>.Continuation?
    }

    private var run: Run?
    private var generation = 0
    /// A start or a teardown in progress (they suspend); no other start or stop meanwhile.
    private var busy = false

    init(instanceDir: URL) { self.instanceDir = instanceDir }

    // MARK: - Configure, Create, CreateDisk

    /// Fills what Lima expects the driver to fill (the vz driver's fillConfig: `mountType`,
    /// `ssh.overVsock`, `vmOpts.vz`): `limayaml.Validate` dereferences `mountType` afterwards.
    /// Also pins DNS to usernet's gateway: cidata gives drivers not named "vz" QEMU's
    /// 192.168.5.3, which gvisor's usernet doesn't serve, and then nothing in the guest resolves.
    func configure(_ data: Data) throws -> Data {
        guard var inst = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var config = inst["config"] as? [String: Any] else {
            throw DriverError("instance JSON is not an object with a config")
        }
        if config["mountType"] == nil { config["mountType"] = "virtiofs" }
        var ssh = config["ssh"] as? [String: Any] ?? [:]
        if ssh["overVsock"] == nil { ssh["overVsock"] = false }
        config["ssh"] = ssh
        if (config["dns"] as? [Any])?.isEmpty ?? true {
            config["dns"] = [Usernet.gateway]
            var resolver = config["hostResolver"] as? [String: Any] ?? [:]
            resolver["enabled"] = false
            config["hostResolver"] = resolver
        }
        var vmOpts = config["vmOpts"] as? [String: Any] ?? [:]
        if vmOpts["vz"] == nil {
            vmOpts["vz"] = ["rosetta": ["enabled": false, "binFmt": false], "diskImageFormat": "raw"]
        }
        config["vmOpts"] = vmOpts
        inst["config"] = config
        spec = try InstanceSpec(json: inst)
        return try JSONSerialization.data(withJSONObject: inst)
    }

    func validate() throws {
        let spec = try requireSpec()
        guard spec.os == "Linux" else { throw DriverError("hanalima: only Linux guests are supported, got \(spec.os)") }
        guard spec.arch == "aarch64" else { throw DriverError("hanalima: only aarch64 guests are supported, got \(spec.arch)") }
    }

    /// First-time provisioning: the machine identifier. A no-op on an existing instance.
    func create() throws {
        let spec = try requireSpec()
        _ = try VZMachine.machineIdentifier(at: spec.identifierURL)
    }

    /// `image` (what limactl downloaded; raw, from Lima's imgconv cache) becomes `disk`. Lima's
    /// core resizes it to the configured size right after.
    func createDisk() throws {
        let spec = try requireSpec()
        let fm = FileManager.default
        if fm.fileExists(atPath: spec.diskURL.path) { return }
        guard fm.fileExists(atPath: spec.imageURL.path) else { throw DriverError("neither disk nor image in \(spec.dir.path)") }
        let head = try FileHandle(forReadingFrom: spec.imageURL).read(upToCount: 4) ?? Data()
        if head == Data([0x51, 0x46, 0x49, 0xFB]) {  // "QFI\xfb"
            throw DriverError("image is qcow2; this driver takes raw images only (Lima converts them when vmOpts.vz.diskImageFormat is raw)")
        }
        try fm.moveItem(at: spec.imageURL, to: spec.diskURL)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: spec.diskURL.path)
    }

    // MARK: - Start, SSH, Stop

    /// Boots: usernet first, then the VM with its NIC on usernet. Returns once the VM runs; the
    /// returned stream yields once, when the guest stops (nil) or dies (the error).
    func start() async throws -> AsyncStream<Error?> {
        let spec = try requireSpec()
        guard run == nil, !busy else { throw DriverError("already started") }
        busy = true
        defer { busy = false }
        generation += 1
        var current = Run(generation: generation)
        do {
            try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: spec.pidURL)
            // usernet's start-up waits on its sockets (up to 15 s); not on the actor's executor.
            current.usernet = try await Task.detached { try Usernet.start(spec: spec) }.value
            let pair = try makeDatagramSocketPair()
            current.usernetPass = try sendFileDescriptor(pair.remote.fileDescriptor, toUnixSocketAt: spec.usernetFDSocket)
            try pair.remote.close()
            current.usernetHandle = pair.local
            var handles: [FileHandle?] = [pair.local]
            for nic in spec.nics {
                switch nic {
                case .socket(let path, _):
                    let relay = try connectQemuStreamSocket(path: path)
                    current.relays.append(relay)
                    handles.append(relay)
                case .vzNAT, .lima:
                    handles.append(nil)
                }
            }
            for disk in spec.disks {
                try Self.lock(disk, for: spec)
                current.lockedDisks.append(disk)
            }
            let (stream, continuation) = AsyncStream<Error?>.makeStream()
            current.stopped = continuation
            let gen = current.generation
            let vm = try VZMachine(spec: spec, networkHandles: handles) { error in
                Task { await self.guestStopped(generation: gen, error: error) }
            }
            current.machine = vm
            run = current
            try await vm.start()
            log("VM running")
            return stream
        } catch {
            run = nil
            await tearDown(current)
            throw error
        }
    }

    /// Lima's `GuestAgentConn` with `ForwardGuestAgent` false: the host agent dials `ga.sock`
    /// in the instance directory, which this bridges to the guest agent's vsock port.
    func ensureGuestAgentBridge() throws {
        let spec = try requireSpec()
        guard let current = run, let vm = current.machine else { throw DriverError("not started") }
        if current.guestAgentBridge != nil { return }
        let bridge = try UnixSocketBridge(path: spec.guestAgentSocket) {
            try vm.connectVsock(port: InstanceSpec.guestAgentVsockPort)
        }
        run?.guestAgentBridge = bridge
        log("guest agent: \(spec.guestAgentSocket) -> vsock \(InstanceSpec.guestAgentVsockPort)")
    }

    /// Lima's `in_use_by` lock on an additional disk: a symlink to the instance directory.
    private static func lock(_ disk: InstanceSpec.Disk, for spec: InstanceSpec) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: disk.image.path) else { throw DriverError("additional disk \(disk.name) has no datadisk") }
        if let owner = try? fm.destinationOfSymbolicLink(atPath: disk.lock.path) {
            guard owner == spec.dir.path else { throw DriverError("additional disk \(disk.name) is in use by \(owner)") }
            try fm.removeItem(at: disk.lock)
        }
        try fm.createSymbolicLink(atPath: disk.lock.path, withDestinationPath: spec.dir.path)
        // Only once the disk is ours: `limactl disk create` makes qcow2 (even with --format raw
        // in Lima 2.2.1); Lima's vz converts it to raw in place at the first attach, so does this.
        do {
            if try QCOW2.isQCOW2(disk.image) {
                log("converting additional disk \(disk.name) from qcow2 to raw")
                let raw = disk.dir.appendingPathComponent("datadisk.hanalima-raw.\(ProcessInfo.processInfo.processIdentifier)")
                defer { try? fm.removeItem(at: raw) }
                try QCOW2.convertToRaw(disk.image, to: raw)
                _ = try fm.replaceItemAt(disk.image, withItemAt: raw)
            }
        } catch {
            try? fm.removeItem(at: disk.lock)
            throw error
        }
    }

    /// Lima's `AdditionalSetupForSSH`: forward 127.0.0.1:<sshLocalPort> on usernet to the
    /// guest's port 22, once the guest has an address, and wait for sshd to answer.
    func waitForSSH() async throws {
        let spec = try requireSpec()
        guard spec.sshLocalPort != 0 else { return }
        guard let gen = run?.generation else { throw DriverError("not started") }
        let client = UsernetClient(socketPath: spec.usernetEndpointSocket)
        let ip = try await Usernet.resolveIP(mac: spec.macAddress, client: client)
        let local = "127.0.0.1:\(spec.sshLocalPort)"
        try await client.expose(local: local, remote: "\(ip):22")
        if run?.generation == gen { run?.exposedLocal = local }
        log("usernet: \(local) -> \(ip):22")
        // Not usernet's /extension/wait_port: on success it closes the connection without a
        // response (Lima's Go client retries silently). The forward is enough to probe.
        try await Usernet.waitForSSHBanner(port: spec.sshLocalPort, timeout: 600)
        log("guest sshd answers on \(local)")
    }

    /// Asks the guest to power off; pulls the plug after `deadline`. Returns once it's stopped.
    func stop(deadline: TimeInterval = 90) async throws {
        // A start in progress: let it finish (or fail) first.
        let waited = Date()
        while busy, run == nil, Date().timeIntervalSince(waited) < 60 { try? await Task.sleep(for: .milliseconds(200)) }
        guard let current = run, let vm = current.machine else { return }
        let gen = current.generation
        if let local = current.exposedLocal, let spec {
            try? await UsernetClient(socketPath: spec.usernetEndpointSocket).unexpose(local: local)
            run?.exposedLocal = nil
        }
        if vm.requestStop() {
            let start = Date()
            while vm.state != .stopped, Date().timeIntervalSince(start) < deadline {
                try? await Task.sleep(for: .milliseconds(500))
                if run?.generation != gen { return }  // the guest stopped and was cleaned up
            }
        }
        guard run?.generation == gen else { return }
        if vm.state != .stopped {
            log("guest didn't stop in \(Int(deadline)) s; stopping it")
            do {
                try await vm.stop()
            } catch {
                log("forced stop failed: \(error)")
                await guestStopped(generation: gen, error: error)
                throw error
            }
            // A forced stop doesn't reach the delegate.
            await guestStopped(generation: gen, error: nil)
        }
    }

    private func guestStopped(generation: Int, error: Error?) async {
        guard let current = run, current.generation == generation else { return }
        run = nil
        busy = true
        log(error.map { "guest stopped with error: \($0)" } ?? "guest stopped")
        await tearDown(current)
        busy = false
        current.stopped?.yield(error)
        current.stopped?.finish()
    }

    /// Off the actor's executor: ending usernet waits (up to 5 s), and Info must keep answering.
    private func tearDown(_ run: Run) async {
        let spec = spec
        await Task.detached {
            run.guestAgentBridge?.close()
            try? run.usernetHandle?.close()
            try? run.usernetPass?.close()
            for relay in run.relays { try? relay.close() }
            for disk in run.lockedDisks { try? FileManager.default.removeItem(at: disk.lock) }
            if let usernet = run.usernet { Usernet.terminate(usernet) }
            if let spec {
                try? FileManager.default.removeItem(at: spec.pidURL)
                try? FileManager.default.removeItem(at: spec.usernetPIDURL)
            }
        }.value
    }

    private func requireSpec() throws -> InstanceSpec {
        guard let spec else { throw DriverError("Configure must be called first") }
        return spec
    }
}

/// `limactl usernet`: Lima's user-mode network stack (gvisor-tap-vsock) as a separate process,
/// the way Lima's `lima:user-v2` networks run it. The VM's NIC is a datagram socket pair whose
/// other end is passed to usernet over `default_fd.sock`; usernet's HTTP API is on
/// `default_ep.sock`.
enum Usernet {
    static let subnet = "192.168.5.0/24"
    static let gateway = "192.168.5.2"
    static let guestIP = "192.168.5.15"

    static func start(spec: InstanceSpec) throws -> Process {
        guard let limactl = LimaClient.locate() else { throw DriverError("limactl not found") }
        let fm = FileManager.default
        // A usernet left by a killed driver would hold the sockets; its pid file would make
        // the new one refuse to start.
        if let text = try? String(contentsOf: spec.usernetPIDURL, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
            // Only if that pid is still a usernet: after a crash the number may belong to anything.
            if commandLine(of: pid).contains("limactl usernet"), kill(pid, SIGTERM) == 0 {
                let started = Date()
                while kill(pid, 0) == 0, Date().timeIntervalSince(started) < 5 { Thread.sleep(forTimeInterval: 0.1) }
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
            try? fm.removeItem(at: spec.usernetPIDURL)
        }
        for sock in [spec.usernetEndpointSocket, spec.usernetFDSocket] { try? fm.removeItem(atPath: sock) }
        fm.createFile(atPath: spec.usernetLogURL.path, contents: nil)
        // Through a shell that ends usernet when the driver is gone: Lima's `delete --force`
        // kills the driver outright, and macOS has no parent-death signal.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", watchdogScript, "usernet-watchdog", "\(ProcessInfo.processInfo.processIdentifier)",
                             limactl.path, "usernet", "--endpoint", spec.usernetEndpointSocket, "--listen", spec.usernetFDSocket,
                             "--subnet", subnet, "--leases", "\(guestIP)=\(spec.macAddress)",
                             "--pidfile", spec.usernetPIDURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: spec.usernetLogURL)
        try process.run()
        let started = Date()
        while !(fm.fileExists(atPath: spec.usernetFDSocket) && fm.fileExists(atPath: spec.usernetEndpointSocket)) {
            if !process.isRunning { throw DriverError("limactl usernet exited (\(process.terminationStatus)); see \(spec.usernetLogURL.path)") }
            if Date().timeIntervalSince(started) > 15 { terminate(process); throw DriverError("limactl usernet didn't create its sockets") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return process
    }

    /// `sh -c <script> <name> <driver pid> <command…>`: runs the command, and ends it when the
    /// driver's pid is gone or on SIGTERM.
    private static let watchdogScript = """
        parent=$1; shift
        "$@" & child=$!
        trap 'kill $child 2>/dev/null' TERM INT
        while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 1; done
        kill $child 2>/dev/null
        wait $child
        """

    private static func commandLine(of pid: Int32) -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", "\(pid)"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return "" }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }

    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let started = Date()
        while process.isRunning, Date().timeIntervalSince(started) < 5 { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// Connects to the forwarded SSH port until the guest's sshd sends its banner. usernet
    /// accepts at once and only then dials the guest, so a bare connect proves nothing.
    static func waitForSSHBanner(port: Int, timeout: TimeInterval) async throws {
        let started = Date()
        while true {
            if await Task.detached(operation: { sshBanner(port: port) }).value { return }
            if Date().timeIntervalSince(started) > timeout { throw DriverError("no SSH banner on 127.0.0.1:\(port) in \(Int(timeout)) s") }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private static func sshBanner(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = recv(fd, &buffer, buffer.count, 0)
        return n >= 4 && buffer.prefix(4).elementsEqual("SSH-".utf8)
    }

    /// The guest's address from usernet's DHCP leases (Lima polls for up to 2 minutes).
    static func resolveIP(mac: String, client: UsernetClient, timeout: TimeInterval = 120) async throws -> String {
        let started = Date()
        while true {
            if let leases = try? await client.leases(), let ip = leases.first(where: { $0.value.lowercased() == mac.lowercased() })?.key {
                return ip
            }
            if Date().timeIntervalSince(started) > timeout { throw DriverError("usernet gave the guest no address in \(Int(timeout)) s") }
            try await Task.sleep(for: .milliseconds(500))
        }
    }
}
