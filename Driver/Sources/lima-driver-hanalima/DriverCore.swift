import Foundation
import LimaKit
import NetworkKit

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
        /// The guest's console: serialv.log and serialv.sock.
        var serial: SerialConsole?
        /// The VM's screen, when it has one.
        var window: DisplayWindow?
        /// 127.0.0.1:<sshLocalPort> → the guest's vsock port 22, when its sshd listens there.
        var sshBridge: UnixSocketBridge?
        /// AdditionalSetupForSSH in progress; Stop cancels it.
        var sshWait: Task<Void, Error>?
        /// AdditionalSetupForSSH has finished: the earliest a pause is allowed (docs/11).
        var sshSetUp = false
        /// Stop has asked the guest to power off; no pause from then on.
        var stopping = false
        /// When the current pause began.
        var pausedAt: Date?
        /// This run resumed a hibernated state instead of booting (docs/11, stage 2).
        var restored = false
        /// A hibernate in progress: a stop waits for it (a resume between the save and the power
        /// off would let the guest write the disk the saved state no longer matches).
        var hibernating = false
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
        if ssh["overVsock"] == nil { ssh["overVsock"] = (config["os"] as? String ?? "Linux") == "Linux" }
        config["ssh"] = ssh
        let usernet = ((config["vmOpts"] as? [String: Any])?["hanalima"] as? [String: Any])?["usernet"] as? Bool ?? true
        // A lima: user-v2 network as NIC 0 (Lima's first usernet) serves DNS at its own gateway.
        let limaNetworks = LimaNetworks.load(from: URL(fileURLWithPath: inst["LimaHome"] as? String ?? LimaNetworks.limaHome.path)
            .appending(path: "_config/networks.yaml"))
        let userV2Gateway = (config["networks"] as? [[String: Any]] ?? [])
            .compactMap { $0["lima"] as? String }.compactMap { limaNetworks.network(named: $0) }
            .first { $0.mode == "user-v2" }.flatMap(LimaNetworks.usernetGateway(of:))
        if usernet {
            if (config["dns"] as? [Any])?.isEmpty ?? true {
                config["dns"] = [userV2Gateway ?? Usernet.gateway]
                var resolver = config["hostResolver"] as? [String: Any] ?? [:]
                resolver["enabled"] = false
                config["hostResolver"] = resolver
            }
        } else {
            // cidata's network-config still lists eth0 (usernet's MAC); netplan must treat it as
            // optional or Ubuntu waits two minutes for it at every boot.
            var param = config["param"] as? [String: String] ?? [:]
            param["internal_netplanOptional"] = "true"
            config["param"] = param
            // Nothing in the guest can reach the host's resolver or apt: without these Lima's
            // 30-install-packages.sh (iptables for the DNS ports, newuidmap for rootless
            // containerd) and 40-install-containerd.sh fail at every boot and cloud-init ends
            // in "error".
            var resolver = config["hostResolver"] as? [String: Any] ?? [:]
            resolver["enabled"] = false
            config["hostResolver"] = resolver
            config["containerd"] = ["system": false, "user": false]
            // The resolver: with no usernet Lima would fall back to the Mac's own resolvers,
            // which the guest can't reach (and cloud-init writes them to Alpine's resolv.conf
            // at every boot, over dhcpcd's). A guest-only network's DHCP server is also its
            // DNS (`lima-<name>` only), so name the first one; nothing else is reachable anyway.
            if (config["dns"] as? [Any])?.isEmpty ?? true,
               let servers = Self.guestOnlyDNS(for: config["networks"] as? [[String: Any]] ?? []) {
                config["dns"] = servers
            }
        }
        var vmOpts = config["vmOpts"] as? [String: Any] ?? [:]
        if vmOpts["vz"] == nil {
            vmOpts["vz"] = ["rosetta": ["enabled": false, "binfmt": false], "diskImageFormat": "raw"]
        }
        config["vmOpts"] = vmOpts
        inst["config"] = config
        spec = try InstanceSpec(json: inst)
        return try JSONSerialization.data(withJSONObject: inst)
    }

    /// What this driver can't run. `limactl edit` calls this too, so switching an existing VM's
    /// `vmType` to hanalima is refused here (with the reason in lima.REJECTED.yaml) rather than
    /// at the next start.
    /// A hosted boot's spec (no Configure from Lima).
    func adopt(_ spec: InstanceSpec) { self.spec = spec }

    func validate() throws {
        let spec = try requireSpec()
        guard spec.os == "Linux" else { throw DriverError("hanalima: only Linux guests are supported, got \(spec.os)") }
        guard spec.arch == "aarch64" else { throw DriverError("hanalima: only aarch64 guests are supported, got \(spec.arch)") }
        guard spec.mounts.isEmpty || spec.mountType == "virtiofs" else {
            throw DriverError("hanalima: mountType must be virtiofs, got \(spec.mountType)")
        }
        for case .lima(let name) in spec.nics {
            throw DriverError("hanalima: network lima:\(name) is not defined in networks.yaml")
        }
        let limaNetworks = LimaNetworks.load(from: spec.limaHome.appending(path: "_config/networks.yaml"))
        for case .socketVMNet(let name, _, _) in spec.nics where !limaNetworks.socketVMNetInstalled {
            throw DriverError("hanalima: network lima:\(name) needs socket_vmnet, which isn't installed (see Lima's docs); a HanaLima network needs no root")
        }
        if !spec.usernet {
            guard spec.sshOverVsock else { throw DriverError("hanalima: without usernet (vmOpts.hanalima.usernet: false) SSH must go over vsock; set ssh.overVsock to true") }
            guard spec.sharedUsernet == nil else { throw DriverError("hanalima: a lima: user-v2 network is usernet; it can't be combined with vmOpts.hanalima.usernet: false") }
        }
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
        // Before anything touches the disks: a hibernated state either matches them or Start fails.
        let savedState = try savedStateToRestore(spec: spec)
        generation += 1
        var current = Run(generation: generation)
        do {
            try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: spec.pidURL)
            var handles: [FileHandle?] = [nil]
            if spec.usernet {
                // usernet's start-up waits on its sockets (up to 15 s); not on the actor's executor.
                // A shared user-v2 usernet is Lima's to start (it did, before Start).
                if let shared = spec.sharedUsernet {
                    log("NIC 0 on Lima's user-v2 network \(shared.name) (\(shared.fdSocket))")
                } else {
                    current.usernet = try await Task.detached { try Usernet.start(spec: spec) }.value
                }
                let pair = try makeDatagramSocketPair()
                current.usernetPass = try sendFileDescriptor(pair.remote.fileDescriptor, toUnixSocketAt: spec.usernetFDSocket)
                try pair.remote.close()
                current.usernetHandle = pair.local
                handles[0] = pair.local
            } else {
                log("usernet is off (vmOpts.hanalima.usernet: false): no NIC 0, SSH over vsock only")
            }
            for nic in spec.nics {
                switch nic {
                case .socket(let path, _), .socketVMNet(_, let path, _):
                    let relay = try connectQemuStreamSocket(path: path)
                    current.relays.append(relay)
                    handles.append(relay)
                case .userV2(_, let fdSocket, _):
                    // Like NIC 0 on usernet: the shared daemon takes one end of a socket pair.
                    let pair = try makeDatagramSocketPair()
                    current.relays.append(try sendFileDescriptor(pair.remote.fileDescriptor, toUnixSocketAt: fdSocket))
                    try pair.remote.close()
                    current.relays.append(pair.local)
                    handles.append(pair.local)
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
            let serial = try SerialConsole(logURL: spec.serialLogURL, socketPath: spec.serialSocket)
            current.serial = serial
            let vm = try VZMachine(spec: spec, networkHandles: handles, serial: serial.guestHandle) { error in
                Task { await self.guestStopped(generation: gen, error: error) }
            }
            current.machine = vm
            run = current
            if let savedState {
                try await restore(vm: vm, from: savedState, spec: spec)
                run?.restored = true
            } else {
                try await vm.start()
            }
            log("VM running")
            if let box = vm.displayMachine {
                // Like Lima's vz: the window opens with the VM. It can be hidden and reopened.
                let title = "HanaLima: \(spec.name)"
                // Under Lima closing the window only hides it; a hosted boot (rescue, installer)
                // has nothing else keeping the VM, so there closing means power off.
                let closeStops = spec.hosted != nil
                let window = await MainActor.run {
                    let w = DisplayWindow(title: title, machine: box, width: VZMachine.displayWidth, height: VZMachine.displayHeight)
                    if closeStops { w.onClose = { Task { try? await self.stop(deadline: 20) } } }
                    w.show()
                    return w
                }
                if run?.generation == gen { run?.window = window } else { await MainActor.run { window.dismiss() } }
            }
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
            // Paused (docs/11): the host agent's guest agent calls have no deadline, and one
            // hanging on a paused guest blocks `limactl stop`. The connection is closed at once
            // instead, so the call fails now. (Refusing GuestAgentConn itself would do too, but
            // Lima logs an error for each refusal, every 2 s or so.)
            guard vm.state == .running else { throw DriverError("the VM is paused") }
            return try vm.connectVsock(port: InstanceSpec.guestAgentVsockPort)
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
        guard let gen = run?.generation, let vm = run?.machine else { throw DriverError("not started") }
        guard spec.sshLocalPort != 0 else { run?.sshSetUp = true; return }
        // Cancelled by Stop (a probe would otherwise keep going until its timeout).
        let task = Task { try await self.setUpSSH(spec: spec, vm: vm, generation: gen) }
        run?.sshWait = task
        defer { if run?.generation == gen { run?.sshWait = nil } }
        try await task.value
        guard run?.generation == gen else { return }
        run?.sshSetUp = true
        if run?.restored == true {
            Task.detached { await Self.handOverInstanceID(spec: spec) }
        }
    }

    /// SSH over vsock (stage 4): a guest with systemd 256+ has sshd on vsock port 22 from early
    /// boot (systemd-ssh-generator), with no network in between; Alpine and older systemd
    /// don't. With usernet, the usernet route comes up first and vsock is then checked once and
    /// preferred if it answers (as Lima's vz does): probing vsock *during* boot unsettles the
    /// guest agent's vsock connection (seen on Alpine). Without usernet (the isolation profile)
    /// vsock is the only route and is probed until it answers.
    private func setUpSSH(spec: InstanceSpec, vm: VZMachine, generation gen: Int) async throws {
        let local = "127.0.0.1:\(spec.sshLocalPort)"
        let client = UsernetClient(socketPath: spec.usernetEndpointSocket)
        var viaVsock = false
        var usernetUp = false
        if spec.usernet {
            let ip = try await Usernet.resolveIP(mac: spec.macAddress, client: client)
            try await client.expose(local: local, remote: "\(ip):22")
            markExposed(local, generation: gen)
            log("usernet: \(local) -> \(ip):22")
            // Not usernet's /extension/wait_port: on success it closes the connection without a
            // response (Lima's Go client retries silently). The forward is probed.
            try await Usernet.waitForSSHBanner(port: spec.sshLocalPort, timeout: 600)
            log("guest sshd answers on \(local) over usernet")
            usernetUp = true
        } else {
            guard spec.sshOverVsock else { throw DriverError("without usernet SSH must go over vsock (ssh.overVsock)") }
            guard try await Self.probeVsockSSH(vm: vm, timeout: 600) else {
                throw DriverError("no sshd on the guest's vsock port 22 after 600 s; without usernet the guest needs systemd 256 or later (Ubuntu 24.10+, Fedora 41+)")
            }
            viaVsock = true
        }
        guard run?.generation == gen else { return }
        if usernetUp && !viaVsock && spec.sshOverVsock {
            // usernet came first: one more look at vsock before settling.
            viaVsock = try await Self.probeVsockSSH(vm: vm, timeout: 3)
            guard run?.generation == gen else { return }
        }
        guard viaVsock else { return }  // usernet it is; the forward is already recorded
        // Hand the port over to the bridge. The usernet forward holds it until unexposed, and
        // the handover must not end with neither route: on failure the forward comes back.
        if run?.exposedLocal == local {
            do {
                try await client.unexpose(local: local)
            } catch {
                log("keeping usernet for SSH: unexpose failed: \(error)")
                return
            }
            guard run?.generation == gen else { return }
            run?.exposedLocal = nil
        }
        do {
            let bridge = try UnixSocketBridge(tcpPort: spec.sshLocalPort) { try vm.connectVsock(port: 22) }
            if run?.generation == gen {
                run?.sshBridge = bridge
                log("ssh over vsock: \(local) -> vsock:22")
            } else {
                bridge.close()
            }
        } catch {
            log("ssh over vsock failed to listen on \(local): \(error)")
            guard usernetUp, run?.generation == gen else { throw error }
            let ip = try await Usernet.resolveIP(mac: spec.macAddress, client: client)
            try await client.expose(local: local, remote: "\(ip):22")
            await markExposed(local, generation: gen)
            log("usernet forward restored: \(local) -> \(ip):22")
        }
    }

    /// The usernet forward exists from now on (so Stop and a failed handover can remove it).
    private func markExposed(_ local: String, generation: Int) {
        if run?.generation == generation { run?.exposedLocal = local }
    }

    /// Whether the guest's vsock port 22 answers with an SSH banner, probing until `timeout`.
    private static func probeVsockSSH(vm: VZMachine, timeout: TimeInterval) async throws -> Bool {
        let started = Date()
        var attempts = 0
        while Date().timeIntervalSince(started) < timeout {
            try Task.checkCancellation()
            attempts += 1
            let answered = await Task.detached { () -> Bool in
                guard let fd = try? vm.connectVsock(port: 22) else { return false }
                defer { close(fd) }
                var tv = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var buffer = [UInt8](repeating: 0, count: 64)
                let n = recv(fd, &buffer, buffer.count, 0)
                return n >= 4 && buffer.prefix(4).elementsEqual("SSH-".utf8)
            }.value
            if answered {
                log("sshd answers on vsock port 22 (attempt \(attempts), \(Int(Date().timeIntervalSince(started))) s)")
                return true
            }
            if Date().timeIntervalSince(started) + 2 >= timeout { break }
            try await Task.sleep(for: .seconds(2))
        }
        return false
    }

    /// Asks the guest to power off; pulls the plug after `deadline`. Returns once it's stopped.
    func stop(deadline: TimeInterval = 90) async throws {
        // A start in progress: let it finish (or fail) first.
        let waited = Date()
        while busy, run == nil, Date().timeIntervalSince(waited) < 60 { try? await Task.sleep(for: .milliseconds(200)) }
        // A hibernate owns the VM until it has saved and powered off (or given up and resumed);
        // however long the save takes, a stop must not resume the guest in between.
        while run?.hibernating == true {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let current = run, let vm = current.machine else { return }
        let gen = current.generation
        run?.stopping = true
        current.sshWait?.cancel()
        if let local = current.exposedLocal, let spec {
            try? await UsernetClient(socketPath: spec.usernetEndpointSocket).unexpose(local: local)
            run?.exposedLocal = nil
        }
        if let bridge = current.sshBridge {
            await Task.detached { bridge.close() }.value
            run?.sshBridge = nil
        }
        // A paused guest can't take the power button: resume it first, so it shuts down
        // cleanly (docs/11 §5). A pause or resume in flight finishes first.
        let settling = Date()
        while [.pausing, .resuming].contains(vm.state), Date().timeIntervalSince(settling) < 10 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if vm.state == .paused {
            log("resuming the paused VM to stop it")
            do { try await vm.resume() } catch { log("resume failed: \(error)") }
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
        // The delegate's guestStopped tears the run down on its own task; return only once
        // that's done. Lima ends the host agent when Stop returns and then sends SIGTERM, and
        // an exit in the middle of the teardown leaves usernet, pid files and sockets behind.
        let tearingDown = Date()
        while run?.generation == gen || busy, Date().timeIntervalSince(tearingDown) < 30 {
            try? await Task.sleep(for: .milliseconds(100))
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
            if let window = run.window { await MainActor.run { window.dismiss() } }
            run.sshBridge?.close()
            run.serial?.close()
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

    // MARK: - HanaLima's control socket

    /// `DriverControl` requests (what Lima's interface has no call for): the VM's state, its
    /// window, a screenshot. Answered while a VM runs; before that only `status` means anything.
    func control(_ request: DriverControl.Request) async -> DriverControl.Response {
        switch request.op {
        case .status:
            let window = run?.window
            let shown = await MainActor.run { window?.isShown ?? false }
            return DriverControl.Response(ok: true, state: run?.machine?.stateName ?? "none",
                                          display: spec?.display ?? false, screenShown: shown)
        case .openScreen:
            guard let window = run?.window else {
                return .failure(spec?.display == true ? "the VM is not running" : "the VM has no display (video.display is none)")
            }
            let shown = await MainActor.run { window.show() }
            guard shown else { return .failure("the VM has stopped") }
            return DriverControl.Response(ok: true, screenShown: true)
        case .stop:
            guard run != nil else { return .failure("the VM is not running") }
            Task { try? await self.stop(deadline: 60) }
            return DriverControl.Response(ok: true, state: run?.machine?.stateName)
        case .forceStop:
            guard let vm = run?.machine else { return .failure("the VM is not running") }
            guard run?.hibernating != true else { return .failure("the VM is hibernating") }
            let gen = run?.generation
            Task {
                do {
                    try await vm.stop()
                    if let gen { await self.guestStopped(generation: gen, error: nil) }
                } catch {
                    log("forced stop failed: \(error)")  // the run stays; the VM may still be stopping
                }
            }
            return DriverControl.Response(ok: true, state: vm.stateName)
        case .pause:
            return await pause()
        case .resume:
            return await resume()
        case .hibernate:
            return await hibernate()
        case .screenshot:
            guard let window = run?.window else { return .failure("the VM has no display or is not running") }
            do {
                let png = try await MainActor.run { try window.screenshotPNG() }
                return DriverControl.Response(ok: true, screenShown: true, png: png)
            } catch {
                return .failure("\(error)")
            }
        }
    }

    // MARK: - Pause (docs/11, stage 1)

    /// VZ's pause. Only once SSH is set up (Lima's start retries SSH a limited number of times,
    /// so a pause mid-boot could fail `limactl start`) and not while stopping. Connections to the
    /// guest agent are cut and new ones closed until the resume: the host agent's calls to the
    /// guest agent have no deadline, and one hanging on a paused guest blocks `limactl stop`.
    private func pause() async -> DriverControl.Response {
        guard let current = run, let vm = current.machine else { return .failure("the VM is not running") }
        guard !busy, !current.stopping else { return .failure("the VM is starting or stopping") }
        guard current.sshSetUp else { return .failure("the VM is still booting") }
        guard vm.state == .running else { return .failure("the VM is \(vm.stateName)") }
        busy = true
        defer { busy = false }
        do {
            try await vm.pause()
        } catch {
            log("pause failed: \(error)")
            return .failure("\(error)")
        }
        await cutGuestAgentConnections()
        run?.pausedAt = Date()
        log("paused")
        return DriverControl.Response(ok: true, state: vm.stateName)
    }

    /// Connections made before a pause would hang; a new bridge closes them until the resume.
    private func cutGuestAgentConnections() async {
        guard let bridge = run?.guestAgentBridge else { return }
        run?.guestAgentBridge = nil
        await Task.detached { bridge.close() }.value
        do { try ensureGuestAgentBridge() } catch { log("guest agent bridge: \(error)") }
    }

    /// A pause at least this long ends with a link down and up on every NIC (see resume()).
    static let relinkAfterPause: TimeInterval = 60

    private func resume() async -> DriverControl.Response {
        guard let current = run, let vm = current.machine else { return .failure("the VM is not running") }
        guard !busy, !current.stopping else { return .failure("the VM is starting or stopping") }
        guard vm.state == .paused else { return .failure("the VM is \(vm.stateName)") }
        busy = true
        defer { busy = false }
        do {
            try await vm.resume()
        } catch {
            log("resume failed: \(error)")
            return .failure("\(error)")
        }
        let paused = run?.pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        run?.pausedAt = nil
        log("resumed after \(Int(paused)) s")
        // The guest's clocks stood still, so its DHCP client still trusts a lease the server
        // may have let go and handed to another VM. A link down and up makes it confirm the
        // lease (docs/11). Not after a short pause: Alpine's dhcpcd probes the address again,
        // about 5 s without routes.
        if paused >= Self.relinkAfterPause {
            await vm.relinkNetworks()
            log("relinked the NICs so the guest confirms its DHCP lease")
        }
        return DriverControl.Response(ok: true, state: vm.stateName)
    }

    // MARK: - Hibernation (docs/11, stage 2)

    /// VZ's state save: pause, write the guest's RAM and devices to `SavedState.stateName`, pull
    /// the plug. Lima sees an ordinary stop. The next Start restores the state if the VM still
    /// matches the record written beside it. On any failure before the plug is pulled the VM
    /// goes on running as before.
    private func hibernate() async -> DriverControl.Response {
        guard let spec, let current = run, let vm = current.machine else { return .failure("the VM is not running") }
        guard !busy, !current.stopping else { return .failure("the VM is starting or stopping") }
        guard current.sshSetUp else { return .failure("the VM is still booting") }
        guard vm.state == .running || vm.state == .paused else { return .failure("the VM is \(vm.stateName)") }
        if let why = vm.saveRestoreUnsupported { return .failure("this VM's configuration can't be saved: \(why)") }
        // The state file is about as large as the guest's RAM.
        let values = try? spec.dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        if let free, free < Int64(spec.memoryBytes) + (1 << 30) {
            return .failure("not enough free space: the saved state needs about \(spec.memoryBytes >> 20) MiB and 1 GiB to spare, \(free >> 20) MiB is free")
        }
        let gen = current.generation
        busy = true
        run?.hibernating = true
        defer {
            busy = false
            if run?.generation == gen { run?.hibernating = false }
        }
        let started = Date()
        let wasRunning = vm.state == .running
        if wasRunning {
            do { try await vm.pause() } catch { return .failure("pause failed: \(error)") }
            await cutGuestAgentConnections()
        }
        let fm = FileManager.default
        let partial = spec.dir.appending(path: SavedState.partialName)
        try? fm.removeItem(at: partial)
        do {
            try await vm.saveState(to: partial)
        } catch {
            try? fm.removeItem(at: partial)
            if wasRunning { do { try await vm.resume() } catch { log("resume after the failed save failed: \(error)") } }
            log("hibernate: save failed: \(error)")
            return .failure(Self.describeSaveError(error))
        }
        let saved = Date().timeIntervalSince(started)
        run?.stopping = true
        current.sshWait?.cancel()
        do {
            try await vm.stop()
        } catch {
            // Still running from the saved point on would make the state stale.
            try? fm.removeItem(at: partial)
            run?.stopping = false
            if wasRunning { try? await vm.resume() }
            log("hibernate: power off failed: \(error)")
            return .failure("the state was saved but the VM didn't power off: \(error)")
        }
        // Stamped once the VM is off and the disks closed. The record goes first: only a state
        // with a record counts (SavedState.exists).
        var outcome = DriverControl.Response(ok: true, state: "stopped")
        do {
            let size = (try fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
            try SavedState.write(try Self.stateRecord(spec: spec, size: size), instanceDir: spec.dir)
            try fm.moveItem(at: partial, to: SavedState.stateURL(instanceDir: spec.dir))
            log(String(format: "hibernated: %d MiB saved in %.2f s", size >> 20, saved))
        } catch {
            try? SavedState.discard(instanceDir: spec.dir)
            log("hibernate: recording the state failed, the VM is off without it: \(error)")
            outcome = .failure("the VM powered off but its saved state couldn't be recorded: \(error)")
        }
        busy = false
        await guestStopped(generation: gen, error: nil)
        return outcome
    }

    /// VZ's save fails with "permission denied" while the Mac's screen is locked and its Secure
    /// Enclave key doesn't exist yet: the key can only be made unlocked. Once made, saving and
    /// restoring work locked too (docs/11 3.3).
    private static func describeSaveError(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == "VZErrorDomain", e.code == 11 {
            return "saving the VM's state was denied; the Mac must be unlocked the first time (the Secure Enclave key is made then) (\(e.localizedDescription))"
        }
        return "saving the VM's state failed: \(e.localizedDescription)"
    }

    /// What the restore must find unchanged: the machine identifier (a clone gets a new one),
    /// the configuration VZ sees, and the disks and EFI variables.
    private static func stateRecord(spec: InstanceSpec, size: Int64) throws -> SavedState.Record {
        let identifier = try Data(contentsOf: spec.identifierURL).base64EncodedString()
        let configuration = [
            "cpus=\(spec.cpus)", "memory=\(spec.memoryBytes)", "display=\(spec.display)",
            "mountType=\(spec.mountType)", "rosetta=\(spec.rosetta)", "usernet=\(spec.usernet)",
            "shared=\(spec.sharedUsernet?.name ?? "")",
            "mounts=\(spec.mounts.map { "\($0.location):\($0.mountPoint):\($0.writable)" })",
            "nics=\(spec.nics.map { String(describing: $0) })",
            "disks=\(spec.disks.map(\.name))",
        ].joined(separator: "\n")
        let urls = [spec.diskURL, spec.efiURL] + spec.disks.map(\.image)
        let files = try urls.map { url in
            guard let stamp = SavedState.FileStamp(url: url, instanceDir: spec.dir) else { throw DriverError("\(url.lastPathComponent) is missing") }
            return stamp
        }
        return SavedState.Record(machineIdentifier: identifier, configuration: configuration, macAddress: spec.macAddress,
                                 files: files, savedAt: Date(), size: size)
    }

    /// The hibernated state Start should restore, nil to boot. Throws if there is one that
    /// doesn't match the VM any more: booting would throw the guest's RAM away silently, and
    /// restoring it would pair old memory with changed disks.
    private func savedStateToRestore(spec: InstanceSpec) throws -> URL? {
        guard spec.hosted == nil else { return nil }
        let fm = FileManager.default
        let dir = spec.dir
        let state = SavedState.stateURL(instanceDir: dir)
        let restoring = dir.appending(path: SavedState.restoringName)
        try? fm.removeItem(at: dir.appending(path: SavedState.partialName))
        // A restore that never finished (the driver died): the record decides below.
        if fm.fileExists(atPath: restoring.path), !fm.fileExists(atPath: state.path) {
            try fm.moveItem(at: restoring, to: state)
        }
        guard fm.fileExists(atPath: state.path) else {
            try? fm.removeItem(at: SavedState.recordURL(instanceDir: dir))
            return nil
        }
        guard let saved = SavedState.record(instanceDir: dir) else {
            throw DriverError("the hibernated state has no readable record; delete \(state.path) to boot afresh")
        }
        let current = try Self.stateRecord(spec: spec, size: saved.size)
        if saved.machineIdentifier != current.machineIdentifier {
            log("discarding a hibernated state of another identity (limactl clone and rename make a new vz-identifier, and a rename also a new MAC)")
            try SavedState.discard(instanceDir: dir)
            return nil
        }
        if let why = SavedState.mismatch(saved: saved, current: current) {
            throw DriverError("can't resume the hibernated VM: \(why). Discard the saved state to boot afresh (delete \(state.path))")
        }
        return state
    }

    /// Instead of booting: VZ restores the saved state and resumes. The state is used once: it is
    /// set aside while restoring and deleted once the guest runs, put back if the restore fails.
    private func restore(vm: VZMachine, from state: URL, spec: InstanceSpec) async throws {
        let fm = FileManager.default
        let restoring = spec.dir.appending(path: SavedState.restoringName)
        try fm.moveItem(at: state, to: restoring)
        let started = Date()
        do {
            try await vm.restoreState(from: restoring)
        } catch {
            try? fm.moveItem(at: restoring, to: state)
            log("restoring the hibernated state failed: \(error)")
            throw DriverError("restoring the hibernated state failed: \((error as NSError).localizedDescription). Discard the saved state to boot afresh (delete \(state.path))")
        }
        do {
            try await vm.resume()
        } catch {
            try? fm.moveItem(at: restoring, to: state)
            throw DriverError("the restored VM didn't resume: \(error)")
        }
        try? SavedState.discard(instanceDir: spec.dir)
        log(String(format: "resumed the hibernated state in %.2f s", Date().timeIntervalSince(started)))
        // The guest's DHCP client still holds the lease of the last run, from a usernet that is
        // gone, and its clocks stood still: a link down and up makes it ask again (docs/11).
        await vm.relinkNetworks()
        log("relinked the NICs so the guest confirms its DHCP lease")
    }

    /// Lima makes a new instance ID at every start and waits until the guest's boot scripts
    /// write it to /run/lima-ssh-ready; a restored guest still has the old one. Over SSH (with
    /// Lima's ssh.config, not its control socket) the cidata ISO is mounted afresh and Lima's
    /// per-boot script run again, as at a boot. Those scripts are written to be rerun.
    static func handOverInstanceID(spec: InstanceSpec) async {
        let script = [
            "umount /mnt/lima-cidata 2>/dev/null || true",
            // The ISO changed under the same device: no stale blocks from the last run.
            "blockdev --flushbufs /dev/disk/by-label/cidata 2>/dev/null || true",
            "sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true",
            "nohup /var/lib/cloud/scripts/per-boot/00-lima.boot.sh >>/var/log/cloud-init-output.log 2>&1 </dev/null &",
        ].joined(separator: "; ")
        let config = spec.dir.appending(path: "ssh.config").path
        let arguments = ["-F", config, "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
                         "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "lima-\(spec.name)",
                         "sudo", "sh", "-c", "'\(script)'"]
        for attempt in 1...6 {
            let status = await Task.detached { () -> Int32 in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = arguments
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                let err = Pipe()
                p.standardError = err
                guard (try? p.run()) != nil else { return -1 }
                let killer = DispatchWorkItem { p.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
                let message = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                if p.terminationStatus != 0, !message.isEmpty {
                    log("instance ID hand-over: \(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                return p.terminationStatus
            }.value
            if status == 0 {
                log("ran Lima's boot scripts again for the new instance ID (attempt \(attempt))")
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
        log("couldn't run Lima's boot scripts in the restored guest; limactl start will wait for them")
    }

    /// The DNS server (netd) of the first guest-only HanaLima network among `networks`.
    /// netd's DNS on the first guest-only network, then that network's router VM if it has one
    /// (netd refuses names it doesn't know, so the router's resolver gets the internet's).
    private static func guestOnlyDNS(for networks: [[String: Any]]) -> [String]? {
        guard let known = try? NetworkStore.load() else { return nil }
        for nic in networks {
            guard let socket = nic["socket"] as? String,
                  let network = known.first(where: { $0.socketPath == socket }), network.isGuestOnly else { continue }
            return [network.gateway] + (network.routerAddress.map { [$0.description] } ?? [])
        }
        return nil
    }

    /// For the watchdog: no VM and nothing in progress.
    var isIdle: Bool { run == nil && !busy }

    // MARK: - Snapshots

    /// `limactl snapshot` on a `hanalima` VM: the same APFS-clone snapshots as the app's
    /// snapshot tab (`DiskSnapshot`), so both see one list. Lima calls these through whichever
    /// driver process answers on the socket: the running VM's, or one it spawns for the command.
    /// The disk is only consistent while the VM is off, so a running VM is refused — here when
    /// this process has it, or by the host agent's pid when another process does.
    func snapshotCreate(tag: String) throws {
        try requireStoppedForSnapshot()
        try validateTag(tag)
        if snapshotList().contains(where: { $0.name == tag }) { throw DriverError("a snapshot named \(tag) already exists") }
        _ = try DiskSnapshot.create(instanceDir: instanceDir, name: tag)
        log("snapshot \(tag) created")
    }

    func snapshotApply(id: String) throws {
        try requireStoppedForSnapshot()
        guard let snapshot = findSnapshot(id) else { throw DriverError("no snapshot \(id)") }
        try DiskSnapshot.restore(snapshot, of: instanceDir, into: instanceDir)
        log("snapshot \(snapshot.name) (\(snapshot.id)) applied")
    }

    func snapshotDelete(id: String) throws {
        guard let snapshot = findSnapshot(id) else { throw DriverError("no snapshot \(id)") }
        try DiskSnapshot.delete(snapshot, instanceDir: instanceDir)
        log("snapshot \(snapshot.name) (\(snapshot.id)) deleted")
    }

    func snapshotList() -> [DiskSnapshot] {
        DiskSnapshot.list(instanceDir: instanceDir)
    }

    /// The table Lima 2.2 printed as is: QEMU's `info snapshots` layout, which its
    /// `limactl snapshot list --quiet` parses (the tag is the second column).
    func snapshotTable() -> String {
        let snapshots = snapshotList()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let rows = snapshots.enumerated().map { index, snapshot -> [String] in
            let size = DiskSnapshot.folder(instanceDir: instanceDir).map { allocatedSize(of: $0.appending(path: snapshot.id.uuidString)) } ?? 0
            return [String(index + 1), snapshot.name, ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .binary),
                    formatter.string(from: snapshot.createdAt), "--", "--"]
        }
        let header = ["ID", "TAG", "VM SIZE", "DATE", "VM CLOCK", "ICOUNT"]
        let widths = (0..<header.count).map { column in ([header] + rows).map { $0[column].count }.max() ?? 0 }
        func line(_ fields: [String]) -> String {
            fields.enumerated().map { $0.offset == fields.count - 1 ? $0.element : $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
        }
        return ([header] + rows).map(line).joined(separator: "\n") + "\n"
    }

    /// Lima 2.3 sends the ID that `ListSnapshots` returned (the snapshot's UUID); Lima 2.2 sent
    /// the tag in the same field. The ID wins; a tag picks the newest snapshot with that name.
    private func findSnapshot(_ idOrTag: String) -> DiskSnapshot? {
        let snapshots = DiskSnapshot.list(instanceDir: instanceDir)
        if let uuid = UUID(uuidString: idOrTag), let match = snapshots.first(where: { $0.id == uuid }) { return match }
        return snapshots.last { $0.name == idOrTag }
    }

    private func validateTag(_ tag: String) throws {
        guard !tag.isEmpty, tag.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil, !tag.contains("/") else {
            throw DriverError("the tag must be one word without spaces or slashes")
        }
    }

    private func requireStoppedForSnapshot() throws {
        if run != nil || busy { throw DriverError("stop the VM before taking or applying a snapshot") }
        let haPID = instanceDir.appending(path: "ha.pid")
        if let text = try? String(contentsOf: haPID, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0 {
            throw DriverError("stop the VM before taking or applying a snapshot (the host agent is running)")
        }
    }

    /// Blocks actually allocated under `folder` (a clone shares its blocks until the disk diverges).
    private func allocatedSize(of folder: URL) -> Int {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total = 0
        for case let item as URL in items {
            total += (try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        }
        return total
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
