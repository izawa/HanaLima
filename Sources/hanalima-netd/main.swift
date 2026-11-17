// hanalima-netd: serves one HanaLima virtual network to Lima VMs.
//
// It speaks socket_vmnet's protocol (QEMU stream: each Ethernet frame prefixed by a 4-byte
// big-endian length) on a UNIX socket, which Lima uses for `networks: - socket: PATH`, and
// forwards frames to a macOS 26 vmnet network. Unlike socket_vmnet this needs no root: the
// vmnet_network APIs only require the com.apple.security.virtualization entitlement.
// Bridged networks use the legacy vmnet_start_interface API in VMNET_BRIDGED_MODE, one interface
// per VM, which also runs without root under that entitlement (macOS 27.0.1).
// Guest-only networks use no vmnet at all: netd itself switches frames between the connected VMs
// (GuestSwitch) and answers DHCP and ARP for a server address that exists nowhere else, so the
// Mac is not on the segment and the guests get no default route and no DNS.
//
// Usage:
//   hanalima-netd --network NAME            (under launchd; the socket comes from launchd)
//   hanalima-netd --network NAME --socket P (standalone, binds P itself; for development)
//   hanalima-netd --check                   (verify vmnet works, then exit)

import Foundation
import NetworkKit
import vmnet

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

func log(_ message: String) {
    print("\(Date.now.formatted(.iso8601)) \(message)")
}

func fail(_ message: String) -> Never {
    log("error: \(message)")
    exit(1)
}

// MARK: - Arguments

var networkName: String?
var standaloneSocket: String?
var standaloneControl: String?
var checkOnly = false
var idleTimeout: TimeInterval = 600
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--network": networkName = it.next()
        case "--socket": standaloneSocket = it.next()
        case "--control": standaloneControl = it.next()
        case "--idle-timeout": idleTimeout = it.next().flatMap(TimeInterval.init) ?? idleTimeout
        case "--check": checkOnly = true
        default: fail("unknown argument \(arg)")
        }
    }
}

// MARK: - vmnet network

/// Creates the vmnet network once. Returns nil (and logs) if vmnet refuses; configuration errors,
/// which no retry can fix, still exit.
func makeNetwork(mode: VirtualNetwork.Mode, gateway: String, prefixLength: Int,
                 reservations: [DHCPReservation] = [], quiet: Bool = false) -> vmnet_network_ref? {
    precondition(mode != .bridged, "bridged networks don't use vmnet_network")
    var status = vmnet_return_t.VMNET_SUCCESS
    let vmnetMode: operating_modes_t = mode == .host ? .VMNET_HOST_MODE : .VMNET_SHARED_MODE
    guard let config = vmnet_network_configuration_create(vmnetMode, &status) else {
        fail("vmnet_network_configuration_create: \(status.rawValue)")
    }
    var gw = in_addr(), mask = in_addr()
    guard inet_pton(AF_INET, gateway, &gw) == 1,
          inet_pton(AF_INET, IPv4.mask(prefixLength: prefixLength).description, &mask) == 1 else {
        fail("invalid gateway \(gateway)/\(prefixLength)")
    }
    // vmnet wants the host (gateway) address here, not the network address.
    let st = vmnet_network_configuration_set_ipv4_subnet(config, &gw, &mask)
    guard st == .VMNET_SUCCESS else { fail("set_ipv4_subnet: \(st.rawValue)") }
    for r in reservations {
        guard let mac = DHCPReservation.normalizedMAC(r.mac), let ether = ether_aton(mac) else {
            log("skipping reservation with invalid MAC \(r.mac)")
            continue
        }
        var ip = in_addr()
        guard inet_pton(AF_INET, r.ip, &ip) == 1 else {
            log("skipping reservation with invalid IP \(r.ip)")
            continue
        }
        let rs = vmnet_network_configuration_add_dhcp_reservation(config, ether, &ip)
        log("dhcp reservation \(mac) -> \(r.ip): \(rs == .VMNET_SUCCESS ? "ok" : "failed (\(rs.rawValue))")")
    }
    if let network = vmnet_network_create(config, &status) { return network }
    if status.rawValue == 1002 {
        fail("vmnet_network_create: 1002 (is the binary signed with com.apple.security.virtualization?)")
    }
    if !quiet { log("vmnet_network_create: \(status.rawValue)") }
    return nil
}

/// Runs `body` while holding the lock shared by all hanalima-netd processes. Creating a vmnet_network
/// at the same moment another helper starts a bridged interface left that subnet failing with
/// VMNET_FAILURE (1001) for minutes (a VM whose two NICs connect at once triggers it), so vmnet
/// calls that create networks or start interfaces are serialized. socket_vmnet can still collide.
func withVmnetLock<T>(_ body: () -> T) -> T {
    let fd = open(NetworkPaths.vmnetLock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
        log("cannot open \(NetworkPaths.vmnetLock.path): \(String(cString: strerror(errno))); continuing unlocked")
        return body()
    }
    defer { close(fd) }
    while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
    defer { flock(fd, LOCK_UN) }
    return body()
}

if checkOnly {
    guard makeNetwork(mode: .shared, gateway: "192.168.253.1", prefixLength: 24) != nil else { exit(1) }
    print("ok")
    exit(0)
}

guard let networkName else { fail("--network is required") }
let config: VirtualNetwork
do {
    guard let found = try NetworkStore.network(named: networkName) else {
        fail("network \(networkName) is not defined in \(NetworkPaths.configFile.path)")
    }
    config = found
} catch {
    fail("cannot read \(NetworkPaths.configFile.path): \(error)")
}
/// Owns the vmnet network. It is created when a VM connects and released when the last one
/// disconnects, rather than living as long as the process, because of how macOS 26/27 manages it:
/// - DHCP reservations and port-forwarding rules are dropped when a network's last interface
///   stops, even while the ref is held (developer.apple.com/forums/thread/847642, FB24895271).
///   Recreating the network from its configuration restores them.
/// - A network's bridge unit (bridge100, bridge101, …) is fixed at its first activation; two
///   networks activated while the other's bridge was down end up sharing one and break each other
///   (github.com/apple/container/issues/2051). A fresh network picks a unit that is free now.
///   Reusing a network after its interface stopped can also take over a legacy bridged
///   interface's bridge and remove en0's IPv4 address (FB25122122).
/// - A network created at login, before socket_vmnet's bridged mode claimed bridge100, later
///   fails to start interfaces with VMNET_FAILURE.
final class NetworkHolder: @unchecked Sendable {
    let config: VirtualNetwork
    private let lock = NSLock()
    private var network: vmnet_network_ref?

    init(config: VirtualNetwork) { self.config = config }

    /// The network, creating it if needed; nil if vmnet refused this time (see `Relay.waitForNetwork`).
    func current(quiet: Bool = false) -> vmnet_network_ref? {
        guard config.usesVmnetNetwork else { return nil }
        return lock.withLock {
            if let network { return network }
            let created = withVmnetLock {
                makeNetwork(mode: config.mode, gateway: config.gateway, prefixLength: config.prefixLength,
                            reservations: config.reservations, quiet: quiet)
            }
            guard let created else { return nil }
            log("network \(config.name) up: \(config.mode.rawValue) \(config.gateway)/\(config.prefixLength)")
            network = created
            return created
        }
    }

    /// Releases the network so the next `current()` creates a fresh one, but only if `isIdle`
    /// still holds once we have the lock (a VM may have connected in the meantime).
    func discard(if isIdle: () -> Bool = { true }) {
        lock.withLock {
            guard let network, isIdle() else { return }
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(network)).release()
            self.network = nil
            log("network \(config.name) released")
        }
    }
}

let holder = NetworkHolder(config: config)
if config.mode == .bridged { log("network \(config.name): bridged to \(config.bridgedInterface)") }

// MARK: - Guest-only switch

/// A userspace Ethernet switch for a guest-only network: learns each VM's source MACs, delivers
/// known unicast to its port, floods the rest, and answers DHCP/ARP for the server address.
/// Frames to a VM go through that VM's bounded outgoing queue (see Relay) so a VM that stops
/// reading never stalls the others.
final class GuestSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [ObjectIdentifier: Relay] = [:]
    private var table: [UInt64: ObjectIdentifier] = [:]
    /// Learned MACs per port, so a guest spraying source addresses can't grow the table forever.
    private var learnedPerPort: [ObjectIdentifier: Int] = [:]
    private static let learnLimit = 32
    private var writtenVersion = -1
    // Observation (docs/17): segment counters, disconnected ports' last counts, the capture.
    private var answered = NetworkObservation.Counter()
    private var flooded: UInt64 = 0
    private var undelivered: UInt64 = 0
    private var closedPorts: [NetworkObservation.Port] = []
    private var capture: CaptureSession?
    private var departedMACs: [ObjectIdentifier: [String]] = [:]
    /// Faults (docs/18), decided under `lock`.
    private var faults = FaultTable()
    let dhcp: GuestOnlyDHCP
    let serverMAC: [UInt8]
    let leasesFile: URL

    init(config: VirtualNetwork) {
        // A locally administered MAC for the DHCP/ARP responder, derived from the name.
        var hash: UInt32 = 2166136261
        for b in config.name.utf8 { hash = (hash ^ UInt32(b)) &* 16777619 }
        serverMAC = [0x02, 0x68, 0x6c, UInt8(hash >> 16 & 0xff), UInt8(hash >> 8 & 0xff), UInt8(hash & 0xff)]
        let subnet = config.subnet ?? IPv4Subnet(cidr: "192.168.233.0/24")!
        dhcp = GuestOnlyDHCP(subnet: subnet, serverIP: config.gatewayAddress ?? IPv4(subnet.network.value + 1),
                             serverMAC: serverMAC, reservations: config.reservations, router: config.routerAddress)
        leasesFile = NetworkPaths.leases(for: config.name)
        try? FileManager.default.removeItem(at: leasesFile)
    }

    func attach(_ relay: Relay) { lock.withLock { ports[ObjectIdentifier(relay)] = relay } }

    func detach(_ relay: Relay) {
        lock.withLock {
            let id = ObjectIdentifier(relay)
            departedMACs[id] = macs(of: id)  // the table forgets them below; `retire` needs them
            ports[id] = nil
            learnedPerPort[id] = nil
            table = table.filter { $0.value != id }
        }
    }

    private static func mac(_ frame: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<6 { v = v << 8 | UInt64(frame[offset + i]) }
        return v
    }

    /// Switches one frame that `source` sent.
    func forward(_ frame: UnsafeRawBufferPointer, from source: Relay) {
        lock.withLock { capture }?.offer(frame)  // as offered, before any checks
        guard frame.count >= 14 else { return }
        let dst = Self.mac(frame, at: 0)
        let src = Self.mac(frame, at: 6)
        let sourceID = ObjectIdentifier(source)
        // Learn first, so a VM that reconnects (new relay, same MAC) is found by its DHCP
        // traffic too, not only after its first switched frame.
        lock.withLock {
            guard src & 0x010000000000 == 0, ports[sourceID] != nil else { return }  // unicast sources of attached ports
            if let owner = table[src], owner == sourceID { return }
            let learned = learnedPerPort[sourceID, default: 0]
            guard learned < Self.learnLimit else { return }
            table[src] = sourceID
            learnedPerPort[sourceID] = learned + 1
        }
        // A blocked port's frames go nowhere, not even to the responder. Checked after learning, so
        // a fault named by MAC finds a VM that just connected (docs/18).
        if lock.withLock({ fault(for: sourceID)?.block == true }) {
            source.count(\.droppedBlocked, frame.count)
            return
        }
        if let reply = dhcp.handle(frame) {
            let (session, verdict): (CaptureSession?, FaultTable.Verdict) = lock.withLock {
                answered.add(reply.count)
                return (capture, faults.verdict(fault(for: sourceID)))
            }
            reply.withUnsafeBytes { session?.offer($0) }
            source.deliver(reply, verdict)
            writeLeasesIfChanged()
            return
        }
        if dst == Self.serverMACValue(serverMAC) { return }  // for the responder only; not switched
        let targets: [(Relay, FaultTable.Verdict)] = lock.withLock {
            if frame[0] & 1 == 0, let id = table[dst] {
                guard id != sourceID, let port = ports[id] else { return [] }
                return [(port, faults.verdict(fault(for: id)))]
            }
            flooded += 1
            let all = ports.filter { $0.key != sourceID }.sorted { $0.value.portID < $1.value.portID }
                .map { ($0.value, faults.verdict(fault(for: $0.key))) }  // each destination decided on its own
            if all.isEmpty { undelivered += 1 }
            return all
        }
        if frame[12] == 0x08, frame[13] == 0x00 || frame[13] == 0x06 { writeLeasesIfChanged() }  // a RELEASE/DECLINE answers nothing
        guard !targets.isEmpty else { return }
        let bytes = [UInt8](frame)
        for (target, verdict) in targets { target.deliver(bytes, verdict) }
    }

    // MARK: Faults (docs/18)

    /// The fault in force for a port (call with `lock` held).
    private func fault(for id: ObjectIdentifier) -> NetworkFault.Spec? {
        guard !faults.isEmpty else { return nil }
        return faults.fault(at: .now) { mac in Self.macValue(mac).map { table[$0] == id } ?? false }
    }

    private static func macValue(_ mac: String) -> UInt64? {
        let parts = mac.split(separator: ":")
        guard parts.count == 6 else { return nil }
        return parts.reduce(UInt64(0)) { v, p in v << 8 | UInt64(UInt8(p, radix: 16) ?? 0) }
    }

    var hasFaults: Bool { lock.withLock { !faults.faults(at: .now).isEmpty } }
    var faultState: [NetworkFault] { lock.withLock { faults.faults(at: .now) } }

    /// Starts a fault; a block also empties the queues of the ports it hits.
    func startFault(_ spec: NetworkFault.Spec) throws -> [NetworkFault] {
        let (fault, all): (NetworkFault, [NetworkFault]) = try lock.withLock {
            let fault = try faults.start(spec, now: .now)
            return (fault, faults.faults(at: .now))
        }
        log("fault \(fault.id) started: \(fault.spec.target) delay \(fault.spec.delayMs) ms, loss \(fault.spec.lossPercent) %, block \(fault.spec.block), \(fault.spec.seconds) s")
        purgeBlockedPorts()
        return all
    }

    func stopFault(id: String?) throws -> [NetworkFault] {
        let all: [NetworkFault] = try lock.withLock {
            let removed = try faults.stop(id: id)
            for f in removed { log("fault \(f.id) removed") }
            return faults.faults(at: .now)
        }
        purgeBlockedPorts()  // removing one fault can let another one's block take over
        return all
    }

    func expireFaults() {
        guard lock.withLock({ faults.expire(.now) }) else { return }
        log("a fault expired")
        purgeBlockedPorts()
    }

    /// Empties the queues of the ports under a block now, so nothing that waited gets through.
    /// Called whenever the faults change: a block may have started or come into force.
    private func purgeBlockedPorts() {
        let blocked = lock.withLock { ports.filter { fault(for: $0.key)?.block == true }.map(\.value) }
        for relay in blocked { relay.purgeForBlock() }
    }

    private static func serverMACValue(_ mac: [UInt8]) -> UInt64 { mac.reduce(0) { $0 << 8 | UInt64($1) } }

    // MARK: Observation (docs/17)

    /// Keeps a disconnected port's final counts, once its writer has finished (frames it
    /// discarded while closing are counted by then).
    func retire(_ relay: Relay) {
        lock.withLock {
            let id = ObjectIdentifier(relay)
            if let port = relay.portCounters(macs: departedMACs.removeValue(forKey: id) ?? [], connected: false) {
                closedPorts.insert(port, at: 0)
                closedPorts = Array(closedPorts.prefix(NetworkObservation.keepClosed))
            }
        }
    }

    /// The source MACs learned on a port (call with `lock` held).
    private func macs(of id: ObjectIdentifier) -> [String] {
        table.filter { $0.value == id }.keys.sorted().map { v in
            (0..<6).map { String(format: "%02x", UInt8(v >> (8 * (5 - $0)) & 0xff)) }.joined(separator: ":")
        }
    }

    func observation(runID: String, sequence: UInt64, uptime: Double) -> NetworkObservation {
        lock.withLock {
            let live = ports.compactMap { id, relay in relay.portCounters(macs: macs(of: id), connected: true) }
                .sorted { $0.id < $1.id }
            var o = NetworkObservation(runID: runID, sequence: sequence, sampledAt: .now, uptime: uptime, ports: live + closedPorts)
            o.answered = answered
            o.flooded = flooded
            o.undelivered = undelivered
            o.capture = capture?.snapshot
            o.faults = faults.faults(at: .now)
            o.capabilities = [NetworkObservation.faultsCapability]
            return o
        }
    }

    var captureState: NetworkObservation.Capture? { lock.withLock { capture }?.snapshot }
    var isCapturing: Bool { lock.withLock { capture }?.isRunning == true }

    /// Starts a capture of the whole segment; refused while one runs.
    func startCapture(network: String) throws -> NetworkObservation.Capture {
        let running = { (s: CaptureSession?) in s?.isRunning == true }
        if lock.withLock({ running(capture) }) { throw NetdControl.Failure(message: "a capture is already running") }
        // The file is made outside the lock: forwarding takes it for every frame.
        let session = try CaptureSession.start(network: network)
        let published: Bool = lock.withLock {
            guard !running(capture) else { return false }
            capture = session
            return true
        }
        guard published else {
            session.stop("another capture started first")
            throw NetdControl.Failure(message: "a capture is already running")
        }
        log("capture \(session.id) started")
        return session.snapshot
    }

    /// Stops the running capture (`id` nil: whichever runs) and returns its state.
    func stopCapture(id: String?) -> NetworkObservation.Capture? {
        guard let session = lock.withLock({ capture }), session.isRunning, id == nil || id == session.id else { return nil }
        session.stop("stopped")
        session.waitFinished(timeout: 5)
        return session.snapshot
    }

    func checkCaptureTime() { lock.withLock { capture }?.checkTime() }

    /// At exit: ends a running capture and gives its file a moment to be finished.
    func finishCapture() {
        guard let session = lock.withLock({ capture }), session.isRunning else { return }
        session.stop("helper exited")
        session.waitFinished(timeout: 2)
    }

    /// One writer at a time, and only when the leases changed (the snapshot and the file replace
    /// happen under the lock, so an older snapshot can't land after a newer one).
    private func writeLeasesIfChanged() {
        lock.withLock {
            let version = dhcp.stateVersion
            guard version != writtenVersion else { return }
            writtenVersion = version
            try? Data(dhcp.leaseFileText().utf8).write(to: leasesFile, options: .atomic)
        }
    }

    func shutdown() { try? FileManager.default.removeItem(at: leasesFile) }
}

let guestSwitch: GuestSwitch? = config.isGuestOnly ? GuestSwitch(config: config) : nil
if let guestSwitch {
    log("network \(config.name): guest-only switch, DHCP \(config.gateway)/\(config.prefixLength), no router, DNS for the leased names only, server MAC \(guestSwitch.serverMAC.map { String(format: "%02x", $0) }.joined(separator: ":"))")
}

// MARK: - Client registry (status file + idle exit)

final class Registry: @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var clients: [Int: NetworkDaemonStatus.Client] = [:]
    private var nextID = 1
    private(set) var lastActivity = Date.now
    let startedAt = Date.now
    /// Observation (docs/17): a fresh id per run, a sample number, and the switch's counters.
    let runID = UUID().uuidString
    private let startedClock = ContinuousClock.now
    private var sequence: UInt64 = 0
    var guestSwitch: GuestSwitch?

    init(name: String) { self.name = name }

    func add(mac: String) -> Int {
        lock.withLock {
            let id = nextID
            nextID += 1
            clients[id] = .init(id: id, vmnetMAC: mac, connectedAt: .now)
            lastActivity = .now
            writeStatus()
            return id
        }
    }

    func remove(_ id: Int) {
        lock.withLock {
            clients[id] = nil
            lastActivity = .now
            writeStatus()
        }
    }

    /// Connections still starting their interface; they count as users of the network.
    private var pending = 0
    private var relays: [ObjectIdentifier: Relay] = [:]
    private var shuttingDown = false

    func track(_ relay: Relay) { lock.withLock { relays[ObjectIdentifier(relay)] = relay } }
    func untrack(_ relay: Relay) { lock.withLock { relays[ObjectIdentifier(relay)] = nil } }

    var isShuttingDown: Bool { lock.withLock { shuttingDown } }

    /// Marks the daemon as shutting down and returns the relays to stop.
    func beginShutdown() -> [Relay] {
        lock.withLock {
            shuttingDown = true
            return Array(relays.values)
        }
    }

    func beginConnecting() { lock.withLock { pending += 1 } }
    func endConnecting() { lock.withLock { pending -= 1 } }

    /// Rewrites the status file (once a second for the counters).
    func publish() { lock.withLock { writeStatus() } }

    var isIdle: Bool { lock.withLock { clients.isEmpty && pending == 0 } && guestSwitch?.isCapturing != true && guestSwitch?.hasFaults != true }
    /// True when the only user is the caller's own in-progress connection.
    var isIdleExceptOneConnecting: Bool { lock.withLock { clients.isEmpty && pending == 1 } }
    var idleSince: Date { lock.withLock { lastActivity } }

    /// Writes the status file (call with `lock` held, or through `publish`).
    func writeStatus() {
        sequence += 1
        let elapsed = ContinuousClock.now - startedClock
        let uptime = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let observation = guestSwitch?.observation(runID: runID, sequence: sequence, uptime: uptime)
        let status = NetworkDaemonStatus(pid: getpid(), startedAt: startedAt,
                                         clients: clients.values.sorted { $0.id < $1.id }, observation: observation)
        try? status.write(for: name)
    }
}

let registry = Registry(name: config.name)
registry.guestSwitch = guestSwitch
let reservedMACs = Set(config.reservations.compactMap { DHCPReservation.normalizedMAC($0.mac) })
registry.writeStatus()

// MARK: - Per-VM relay

func writeFully(_ fd: Int32, _ ptr: UnsafeRawPointer, _ count: Int) -> Bool {
    var off = 0
    while off < count {
        let n = write(fd, ptr + off, count - off)
        if n < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            return false
        }
        off += n
    }
    return true
}

func readFully(_ fd: Int32, _ ptr: UnsafeMutableRawPointer, _ count: Int) -> Bool {
    var off = 0
    while off < count {
        let n = read(fd, ptr + off, count - off)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        off += n
    }
    return true
}

/// Relays one VM connection to its own vmnet interface on the shared network.
final class Relay: @unchecked Sendable {
    let fd: Int32
    let holder: NetworkHolder
    let registry: Registry
    /// Guest MACs with DHCP reservations; their DHCP requests get option 61 removed
    /// (see DHCPClientIDFilter) so the reservation matches.
    let reservedMACs: Set<String>
    let queue = DispatchQueue(label: "hanalima-netd.relay", qos: .userInteractive)
    private let writeLock = NSLock()
    /// Guards `iface` so the interface is stopped exactly once (disconnect vs. shutdown).
    private let ifaceLock = NSLock()
    private var iface: interface_ref?
    private var maxPacket = 1514
    private var id = 0
    /// Guest-only mode: frames for this VM wait here for the writer thread (bounded; a VM that
    /// stops reading loses frames instead of stalling the switch).
    private var outgoing: [[UInt8]] = []
    /// Frames for this VM waiting out a fault's delay (docs/18), apart from `outgoing` so its
    /// limit still means "the VM isn't reading".
    private var delayLine = DelayLine()
    private var outgoingClosed = false
    /// A wakeup for the writer is pending (one signal covers any number of frames).
    private var wakePending = false
    private var dropped = 0
    /// Guest-only: what this port saw (docs/17), under `statsLock`.
    private let statsLock = NSLock()
    private var stats: NetworkObservation.Port?
    private let outgoingReady = DispatchSemaphore(value: 0)
    private let writerDone = DispatchSemaphore(value: 0)
    private static let outgoingLimit = 512

    init(fd: Int32, holder: NetworkHolder, registry: Registry, reservedMACs: Set<String>) {
        self.fd = fd
        self.holder = holder
        self.registry = registry
        self.reservedMACs = reservedMACs
    }

    func run() {
        registry.track(self)
        defer { registry.untrack(self) }
        if let guestSwitch {
            runGuestOnly(guestSwitch)
            return
        }
        guard start() else {
            close(fd)
            return
        }
        installReader()
        pumpFromVM()
        stop()
        close(fd)
        registry.remove(id)
        // Last VM gone: release the network so the next one gets a fresh network (see NetworkHolder).
        let registry = registry
        holder.discard(if: { registry.isIdle })
    }

    /// Guest-only: no vmnet interface; the switch delivers frames to `outgoing`, a writer thread
    /// sends them, and the read loop hands the VM's frames to the switch.
    private func runGuestOnly(_ guestSwitch: GuestSwitch) {
        id = registry.add(mac: "-")
        statsLock.withLock { stats = NetworkObservation.Port(id: id, connectedAt: .now) }
        log("client \(id) connected (guest-only)")
        guestSwitch.attach(self)
        Thread.detachNewThread { self.writeOutgoing() }
        let capacity = 65536
        let buf = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buf.deallocate() }
        while true {
            var header: UInt32 = 0
            guard readFully(fd, &header, 4) else { break }
            let size = Int(UInt32(bigEndian: header))
            guard size > 0, size <= capacity, readFully(fd, buf, size) else { break }
            statsLock.withLock {
                stats?.fromGuest.add(size)
                if size < 14 { stats?.malformed += 1 }
            }
            guestSwitch.forward(UnsafeRawBufferPointer(start: buf, count: size), from: self)
        }
        // Order matters for the descriptor: detach (no new frames), close the queue, shut the
        // socket down to unblock the writer, wait for it, and only then close the number so a
        // later accept() can't hand it to a connection the old writer still touches.
        guestSwitch.detach(self)
        closeOutgoing()
        Darwin.shutdown(fd, SHUT_RDWR)
        writerDone.wait()
        guestSwitch.retire(self)
        log("client \(id) disconnected" + (dropped > 0 ? " (\(dropped) frames dropped)" : ""))
        close(fd)
        registry.remove(id)
    }

    /// This connection's number (guest-only: stable while it lasts).
    var portID: Int { id }

    /// Hands a frame for this VM over as a fault decided (docs/18): lost, blocked or (delayed) queued.
    func deliver(_ frame: [UInt8], _ verdict: FaultTable.Verdict) {
        switch verdict {
        case .pass(let delay): enqueue(frame, delay: delay)
        case .lost: count(\.droppedLoss, frame.count)
        case .blocked: count(\.droppedBlocked, frame.count)
        }
    }

    /// Queues a frame for this VM (guest-only). Drops it when the VM isn't keeping up. A frame
    /// with a delay, or any frame while delayed ones wait, goes through the delay line, so none
    /// overtakes another.
    private func enqueue(_ frame: [UInt8], delay: Duration) {
        enum Outcome { case queued, queuedQuietly, full, closed, overflow }
        let outcome: Outcome = writeLock.withLock {
            guard !outgoingClosed else { return .closed }
            if delay > .zero || !delayLine.isEmpty {
                guard delayLine.push(frame, due: .now + delay) else { return .overflow }
            } else {
                guard outgoing.count < Self.outgoingLimit else { dropped += 1; return .full }
                outgoing.append(frame)
            }
            if wakePending { return .queuedQuietly }
            wakePending = true
            return .queued
        }
        switch outcome {
        case .queuedQuietly: break
        case .queued: outgoingReady.signal()
        case .full: count(\.droppedFull, frame.count)
        case .closed: count(\.droppedClosed, frame.count)
        case .overflow: count(\.droppedOverflow, frame.count)
        }
    }

    func count(_ counter: WritableKeyPath<NetworkObservation.Port, NetworkObservation.Counter>, _ length: Int) {
        statsLock.withLock { stats?[keyPath: counter].add(length) }
    }

    /// A block started: what waits for this VM is dropped (as blocked).
    func purgeForBlock() {
        let gone: [[UInt8]] = writeLock.withLock {
            let out = outgoing + delayLine.removeAll()
            outgoing.removeAll()
            return out
        }
        statsLock.withLock { for f in gone { stats?.droppedBlocked.add(f.count) } }
    }

    /// This port's counters with `macs` (nil outside guest-only mode).
    func portCounters(macs: [String], connected: Bool) -> NetworkObservation.Port? {
        statsLock.withLock {
            guard var port = stats else { return nil }
            port.macs = macs
            port.connected = connected
            let waiting = writeLock.withLock { (count: delayLine.count, bytes: delayLine.bytes) }
            port.delayed = .init(frames: UInt64(waiting.count), bytes: UInt64(waiting.bytes))
            return port
        }
    }

    private func countDroppedClosed(_ frames: [[UInt8]]) {
        guard !frames.isEmpty else { return }
        statsLock.withLock { for f in frames { stats?.droppedClosed.add(f.count) } }
    }

    private func closeOutgoing() {
        writeLock.withLock { outgoingClosed = true }
        outgoingReady.signal()
    }

    private func writeOutgoing() {
        defer { writerDone.signal() }
        while true {
            var discarded: [[UInt8]] = []
            var closed = false
            var wake: ContinuousClock.Instant?
            let next: [UInt8]? = writeLock.withLock {
                if outgoingClosed {  // closed: drop what's left
                    closed = true
                    discarded = outgoing + delayLine.removeAll()
                    outgoing.removeAll()
                    return nil
                }
                // Delayed frames whose time came join the send queue as far as it has room;
                // the rest wait in the line (the VM may simply not have caught up yet).
                outgoing += delayLine.popDue(.now, limit: Self.outgoingLimit - outgoing.count)
                wake = delayLine.nextDue
                if outgoing.isEmpty { wakePending = false; return nil }  // about to wait: the next frame signals
                return outgoing.removeFirst()
            }
            countDroppedClosed(discarded)
            if closed { return }
            guard let next else {
                // Nothing to write: wait for a frame, or for the next delayed one's time.
                if let wake {
                    let wait = max(.zero, wake - .now)
                    _ = outgoingReady.wait(timeout: .now() + .nanoseconds(Int(wait.components.seconds) * 1_000_000_000 + Int(wait.components.attoseconds / 1_000_000_000)))
                } else {
                    outgoingReady.wait()
                }
                continue
            }
            var header = UInt32(next.count).bigEndian
            let ok = next.withUnsafeBytes { writeFully(fd, &header, 4) && writeFully(fd, $0.baseAddress!, $0.count) }
            if ok {
                statsLock.withLock { stats?.toGuest.add(next.count) }
            } else {
                // The VM went away; wake the read loop so run() finishes, and stop writing.
                countDroppedClosed([next] + writeLock.withLock { let rest = outgoing + delayLine.removeAll(); outgoing.removeAll(); return rest })
                writeLock.withLock { outgoingClosed = true }
                Darwin.shutdown(fd, SHUT_RDWR)
                return
            }
        }
    }

    private func start() -> Bool {
        registry.beginConnecting()
        defer { registry.endConnecting() }
        if startInterface() { return true }
        if holder.config.mode == .bridged { return false }
        // A network that has gone stale (see NetworkHolder) can be replaced as long as no other VM
        // is attached to it; vmnet may need a moment to free the subnet, which makeNetwork retries.
        guard registry.isIdleExceptOneConnecting else { return false }
        log("recreating network after interface start failure")
        holder.discard(if: { registry.isIdleExceptOneConnecting })
        return startInterface()
    }

    /// vmnet sometimes refuses to create a network for a while (VMNET_FAILURE: the subnet is still
    /// being released, or another vmnet client is starting). Keep trying for as long as the VM stays
    /// connected — its DHCP client keeps retrying too — discarding the frames it sends meanwhile so
    /// the socket doesn't fill up. Returns nil if the VM disconnects or the daemon shuts down.
    private func waitForNetwork() -> vmnet_network_ref? {
        if let network = holder.current() { return network }
        log("waiting for vmnet to create the network; retrying while the VM stays connected")
        let started = Date.now
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 16)
        defer { buf.deallocate() }
        var nextAttempt = Date.now.addingTimeInterval(2)
        while !registry.isShuttingDown {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = max(0, Int32(nextAttempt.timeIntervalSinceNow * 1000))
            if poll(&pfd, 1, wait) > 0 {
                // Drop one frame; a failed read means the VM went away.
                var header: UInt32 = 0
                guard readFully(fd, &header, 4) else { return nil }
                let size = Int(UInt32(bigEndian: header))
                guard size > 0, size <= 65536, readFully(fd, buf, size) else { return nil }
                continue
            }
            if let network = holder.current(quiet: true) {
                log("network created after \(Int(Date.now.timeIntervalSince(started)))s of retries")
                return network
            }
            nextAttempt = Date.now.addingTimeInterval(2)
        }
        return nil
    }

    private func startInterface() -> Bool {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var mac = "?"
        nonisolated(unsafe) var ok = false
        let completion: @Sendable (vmnet_return_t, xpc_object_t?) -> Void = { status, params in
            ok = status == .VMNET_SUCCESS
            if !ok { log("interface start failed: \(status.rawValue)") }
            if let params {
                let size = Int(xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key))
                if size > 0 { self.maxPacket = size }
                if let m = xpc_dictionary_get_string(params, vmnet_mac_address_key) { mac = String(cString: m) }
            }
            done.signal()
        }
        let bridged = holder.config.mode == .bridged
        let network = bridged ? nil : waitForNetwork()
        if !bridged && network == nil { return false }
        // Hold the lock until vmnet reports the result, so the next helper starts only afterwards.
        let (started, finished) = withVmnetLock { () -> (interface_ref?, Bool) in
            let started: interface_ref?
            if let network {
                started = vmnet_interface_start_with_network(network, xpc_dictionary_create(nil, nil, 0), queue, completion)
            } else {
                let desc = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, UInt64(operating_modes_t.VMNET_BRIDGED_MODE.rawValue))
                xpc_dictionary_set_string(desc, vmnet_shared_interface_name_key, holder.config.bridgedInterface)
                started = vmnet_start_interface(desc, queue, completion)
            }
            return (started, started != nil && done.wait(timeout: .now() + 30) == .success)
        }
        ifaceLock.withLock { iface = started }
        guard started != nil, finished, ok else {
            ifaceLock.withLock { iface = nil }
            return false
        }
        if registry.isShuttingDown {
            // Started while the daemon was terminating; don't leave it running.
            stop()
            return false
        }
        id = registry.add(mac: mac)
        log("client \(id) connected (vmnet interface \(mac))")
        return true
    }

    /// vmnet -> VM: read batches of packets when vmnet says they're available.
    private func installReader() {
        guard let iface else { return }
        let batch = 32
        let bufSize = maxPacket
        let buffers = (0..<batch).map { _ in UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16) }
        let iovs = UnsafeMutablePointer<iovec>.allocate(capacity: batch)
        let pkts = UnsafeMutablePointer<vmpktdesc>.allocate(capacity: batch)
        let fd = fd
        let writeLock = writeLock
        // Freed in stop(), after the callback has been removed on `queue`.
        nonisolated(unsafe) let cleanup = { buffers.forEach { $0.deallocate() }; iovs.deallocate(); pkts.deallocate() }
        self.freeBuffers = cleanup

        vmnet_interface_set_event_callback(iface, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue) { _, _ in
            while true {
                for i in 0..<batch {
                    iovs[i] = iovec(iov_base: buffers[i], iov_len: bufSize)
                    pkts[i] = vmpktdesc(vm_pkt_size: bufSize, vm_pkt_iov: iovs + i, vm_pkt_iovcnt: 1, vm_flags: 0)
                }
                var count = Int32(batch)
                guard vmnet_read(iface, pkts, &count) == .VMNET_SUCCESS, count > 0 else { return }
                writeLock.withLock {
                    for i in 0..<Int(count) {
                        var header = UInt32(pkts[i].vm_pkt_size).bigEndian
                        guard writeFully(fd, &header, 4), writeFully(fd, buffers[i], pkts[i].vm_pkt_size) else { return }
                    }
                }
                if count < batch { return }
            }
        }
    }

    private var freeBuffers: (() -> Void)?

    /// VM -> vmnet: blocking read loop until the VM disconnects.
    private func pumpFromVM() {
        guard iface != nil else { return }
        let capacity = 65536
        let buf = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buf.deallocate() }
        while true {
            var header: UInt32 = 0
            guard readFully(fd, &header, 4) else { break }
            let size = Int(UInt32(bigEndian: header))
            guard size > 0, size <= capacity, readFully(fd, buf, size) else { break }
            if !reservedMACs.isEmpty {
                // The filter rejects non-DHCP frames after a few byte checks, so do that first.
                let frame = UnsafeRawBufferPointer(start: buf, count: size)
                if let rewritten = DHCPClientIDFilter.strippingClientIdentifier(from: frame),
                   let mac = DHCPClientIDFilter.sourceMAC(of: frame), reservedMACs.contains(mac) {
                    rewritten.withUnsafeBytes { send($0.baseAddress!, $0.count) }
                    continue
                }
            }
            send(buf, size)
        }
    }

    private func send(_ ptr: UnsafeRawPointer, _ size: Int) {
        guard let iface else { return }
        var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: ptr), iov_len: size)
        withUnsafeMutablePointer(to: &iov) { iovPtr in
            var pkt = vmpktdesc(vm_pkt_size: size, vm_pkt_iov: iovPtr, vm_pkt_iovcnt: 1, vm_flags: 0)
            var count: Int32 = 1
            _ = vmnet_write(iface, &pkt, &count)
        }
    }

    /// Stops the vmnet interface (once). Exiting with an interface still started leaves its subnet
    /// reserved by vmnet until the Mac restarts, so every exit path must come through here.
    private func stop() {
        guard let iface = ifaceLock.withLock({ () -> interface_ref? in
            let current = self.iface
            self.iface = nil
            return current
        }) else { return }
        log("client \(id) disconnected")
        let done = DispatchSemaphore(value: 0)
        let st = vmnet_stop_interface(iface, queue) { _ in done.signal() }
        if st == .VMNET_SUCCESS { _ = done.wait(timeout: .now() + 10) }
        // The stop completion runs on `queue` after any in-flight read callback, so buffers are unused now.
        queue.sync { freeBuffers?() }
    }

    /// Used when the daemon terminates: stops the interface and wakes the VM read loop, which then
    /// finishes `run()` normally.
    func shutdown() {
        stop()
        closeOutgoing()
        Darwin.shutdown(fd, SHUT_RDWR)
    }
}

// MARK: - Listening socket

typealias LaunchActivateSocket = @convention(c) (
    UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>, UnsafeMutablePointer<Int>
) -> Int32

/// The socket launchd opened for us (`Sockets` → `name` in the plist), if any.
func launchdSocket(_ name: String = "Listener") -> Int32? {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "launch_activate_socket") else { return nil }
    let activate = unsafeBitCast(sym, to: LaunchActivateSocket.self)
    var fds: UnsafeMutablePointer<Int32>?
    var count = 0
    guard activate(name, &fds, &count) == 0, count > 0, let fds else { return nil }
    defer { free(fds) }
    return fds[0]
}

func bindSocket(_ path: String) -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { fail("socket path too long: \(path)") }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0, listen(fd, 16) == 0 else { fail("bind \(path): \(String(cString: strerror(errno)))") }
    chmod(path, 0o600)
    return fd
}

let listener: Int32
if let path = standaloneSocket {
    listener = bindSocket(path)
    log("listening on \(path)")
} else if let fd = launchdSocket() {
    listener = fd
    log("listening on launchd socket \(config.socketPath)")
} else {
    fail("no launchd socket; pass --socket PATH to run standalone")
}

let statusFile = NetworkPaths.status(for: config.name)

/// Stops every VM's interface and releases the network before exiting, so vmnet frees the subnet.
final class Terminator: Sendable {
    let registry: Registry
    let holder: NetworkHolder
    let statusFile: URL

    init(registry: Registry, holder: NetworkHolder, statusFile: URL) {
        self.registry = registry
        self.holder = holder
        self.statusFile = statusFile
    }

    func shutdownAndExit(_ reason: String, code: Int32 = 0) -> Never {
        let relays = registry.beginShutdown()
        log("\(reason); stopping \(relays.count) interface(s)")
        for relay in relays { relay.shutdown() }
        holder.discard()
        guestSwitch?.finishCapture()
        guestSwitch?.shutdown()
        try? FileManager.default.removeItem(at: statusFile)
        exit(code)
    }
}

let terminator = Terminator(registry: registry, holder: holder, statusFile: statusFile)

// Guest-only (docs/17): the control socket, and the counters in the status file once a second.
if let guestSwitch {
    let control = standaloneControl.map(bindSocket) ?? (standaloneSocket == nil ? launchdSocket("Control") : nil)
    if let control {
        let name = config.name
        Thread.detachNewThread { serveControl(control, guestSwitch: guestSwitch, network: name) }
    } else {
        log("no control socket (an older registration?): counters only")
    }
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 1)
            guestSwitch.checkCaptureTime()
            guestSwitch.expireFaults()
            registry.publish()
        }
    }
}

// Exit when idle; launchd restarts us on the next connection.
let timeout = idleTimeout
if timeout > 0 {
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 10)
            if registry.isIdle && Date.now.timeIntervalSince(registry.idleSince) > timeout {
                terminator.shutdownAndExit("idle for \(Int(timeout))s, exiting")
            }
        }
    }
}

signal(SIGPIPE, SIG_IGN)
// Signal handlers can't capture context; use DispatchSource instead. The handler must be @Sendable:
// a closure written at top level is otherwise main-actor isolated, and since the main thread sits
// in accept() below, the handler runs elsewhere and Swift's isolation check traps (SIGTRAP), which
// killed the daemon without stopping its interfaces.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    let terminator = terminator
    source.setEventHandler { @Sendable in
        terminator.shutdownAndExit("terminated by signal \(sig)")
    }
    source.resume()
    signalSources.append(source)
}

while true {
    let fd = accept(listener, nil, nil)
    if fd < 0 {
        if errno == EINTR { continue }
        terminator.shutdownAndExit("accept: \(String(cString: strerror(errno)))", code: 1)
    }
    let relay = Relay(fd: fd, holder: holder, registry: registry, reservedMACs: reservedMACs)
    Thread.detachNewThread { relay.run() }
}
