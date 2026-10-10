// hanalima-netd: serves one HanaLima virtual network to Lima VMs.
//
// It speaks socket_vmnet's protocol (QEMU stream: each Ethernet frame prefixed by a 4-byte
// big-endian length) on a UNIX socket, which Lima uses for `networks: - socket: PATH`, and
// forwards frames to a macOS 26 vmnet network. Unlike socket_vmnet this needs no root: the
// vmnet_network APIs only require the com.apple.security.virtualization entitlement.
// Bridged networks use the legacy vmnet_start_interface API in VMNET_BRIDGED_MODE, one interface
// per VM, which also runs without root under that entitlement (macOS 27.0.1).
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
var checkOnly = false
var idleTimeout: TimeInterval = 600
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--network": networkName = it.next()
        case "--socket": standaloneSocket = it.next()
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
        if config.mode == .bridged { return nil }
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

// MARK: - Client registry (status file + idle exit)

final class Registry: @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var clients: [Int: NetworkDaemonStatus.Client] = [:]
    private var nextID = 1
    private(set) var lastActivity = Date.now
    let startedAt = Date.now

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

    var isIdle: Bool { lock.withLock { clients.isEmpty && pending == 0 } }
    /// True when the only user is the caller's own in-progress connection.
    var isIdleExceptOneConnecting: Bool { lock.withLock { clients.isEmpty && pending == 1 } }
    var idleSince: Date { lock.withLock { lastActivity } }

    func writeStatus() {
        let status = NetworkDaemonStatus(pid: getpid(), startedAt: startedAt,
                                         clients: clients.values.sorted { $0.id < $1.id })
        try? status.write(for: name)
    }
}

let registry = Registry(name: config.name)
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

    init(fd: Int32, holder: NetworkHolder, registry: Registry, reservedMACs: Set<String>) {
        self.fd = fd
        self.holder = holder
        self.registry = registry
        self.reservedMACs = reservedMACs
    }

    func run() {
        registry.track(self)
        defer { registry.untrack(self) }
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
        Darwin.shutdown(fd, SHUT_RDWR)
    }
}

// MARK: - Listening socket

typealias LaunchActivateSocket = @convention(c) (
    UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>, UnsafeMutablePointer<Int>
) -> Int32

/// The socket launchd opened for us (`Sockets` → `Listener` in the plist), if any.
func launchdSocket() -> Int32? {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "launch_activate_socket") else { return nil }
    let activate = unsafeBitCast(sym, to: LaunchActivateSocket.self)
    var fds: UnsafeMutablePointer<Int32>?
    var count = 0
    guard activate("Listener", &fds, &count) == 0, count > 0, let fds else { return nil }
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
        try? FileManager.default.removeItem(at: statusFile)
        exit(code)
    }
}

let terminator = Terminator(registry: registry, holder: holder, statusFile: statusFile)

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
