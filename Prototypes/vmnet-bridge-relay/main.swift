// Experiment: rootless bridged networking for Lima VMs.
//
// Relays Lima's `networks: - socket:` (QEMU stream: 4-byte big-endian length + frame) to a
// legacy vmnet interface in VMNET_BRIDGED_MODE, one interface per connected VM — what
// socket_vmnet --vmnet-mode=bridged does, but without root, relying on the
// com.apple.security.virtualization entitlement.
//
// Build:
//   swiftc -O -o bridge-relay main.swift
//   codesign -s - -f --entitlements entitlements.plist bridge-relay
// Run:
//   ./bridge-relay <socket path> <interface, e.g. en0>
// Stop with Ctrl-C (or SIGTERM): every interface is stopped before exiting.

import Foundation
import vmnet

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count == 3 else { print("usage: bridge-relay <socket> <interface>"); exit(2) }
let socketPath = args[1]
let hostInterface = args[2]
print("uid \(getuid()) euid \(geteuid()); bridging to \(hostInterface)")

func writeAll(_ fd: Int32, _ ptr: UnsafeRawPointer, _ len: Int) -> Bool {
    var off = 0
    while off < len {
        let n = write(fd, ptr + off, len - off)
        if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return false }
        off += n
    }
    return true
}

func readAll(_ fd: Int32, _ ptr: UnsafeMutableRawPointer, _ len: Int) -> Bool {
    var off = 0
    while off < len {
        let n = read(fd, ptr + off, len - off)
        if n <= 0 { if n < 0 && errno == EINTR { continue }; return false }
        off += n
    }
    return true
}

/// Short description of an Ethernet frame, for logging the first frames of each direction.
func describeFrame(_ p: UnsafeRawPointer, _ len: Int) -> String {
    guard len >= 14 else { return "\(len) bytes" }
    let b = p.assumingMemoryBound(to: UInt8.self)
    let mac = { (o: Int) in (0..<6).map { String(format: "%02x", b[o + $0]) }.joined(separator: ":") }
    let type = UInt16(b[12]) << 8 | UInt16(b[13])
    var kind = String(format: "0x%04x", type)
    if type == 0x0806 { kind = "ARP" }
    if type == 0x86dd { kind = "IPv6" }
    if type == 0x0800, len >= 34 {
        let proto = b[23]
        kind = "IPv4 \(b[26]).\(b[27]).\(b[28]).\(b[29]) -> \(b[30]).\(b[31]).\(b[32]).\(b[33])"
        if proto == 17, len >= 38 {
            let sport = UInt16(b[34]) << 8 | UInt16(b[35]), dport = UInt16(b[36]) << 8 | UInt16(b[37])
            kind += " udp \(sport)->\(dport)" + ((sport == 67 || dport == 67) ? " (DHCP)" : "")
        } else if proto == 1 {
            kind += " icmp"
        }
    }
    return "\(mac(6)) -> \(mac(0)) \(kind) (\(len) bytes)"
}

final class Client: @unchecked Sendable {
    let fd: Int32
    let id: Int
    let queue: DispatchQueue
    let writeLock = NSLock()
    let stateLock = NSLock()
    private var iface: interface_ref?
    private var stopped = false
    var maxPacket = 1514
    var fromVM = 0, toVM = 0

    init(fd: Int32, id: Int) {
        self.fd = fd
        self.id = id
        queue = DispatchQueue(label: "client\(id)")
    }

    func run() {
        let desc = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, UInt64(operating_modes_t.VMNET_BRIDGED_MODE.rawValue))
        xpc_dictionary_set_string(desc, vmnet_shared_interface_name_key, hostInterface)
        let sem = DispatchSemaphore(value: 0)
        var startStatus = vmnet_return_t.VMNET_FAILURE
        let started = vmnet_start_interface(desc, queue) { st, params in
            startStatus = st
            if let params {
                self.maxPacket = Int(xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key))
                let mac = xpc_dictionary_get_string(params, vmnet_mac_address_key).map { String(cString: $0) } ?? "?"
                let mtu = xpc_dictionary_get_uint64(params, vmnet_mtu_key)
                print("client \(self.id): bridged interface status \(st.rawValue), vmnet mac \(mac), mtu \(mtu), max packet \(self.maxPacket)")
            } else {
                print("client \(self.id): bridged interface status \(st.rawValue) (no parameters)")
            }
            sem.signal()
        }
        sem.wait()
        guard startStatus == .VMNET_SUCCESS, let started else {
            print("client \(id): vmnet_start_interface failed (\(startStatus.rawValue))")
            close(fd)
            return
        }
        stateLock.withLock { iface = started }

        // vmnet -> VM
        let batch = 32
        let bufSize = maxPacket
        vmnet_interface_set_event_callback(started, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue) { _, _ in
            let bufs = (0..<batch).map { _ in UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16) }
            defer { bufs.forEach { $0.deallocate() } }
            let iovs = UnsafeMutablePointer<iovec>.allocate(capacity: batch)
            let pkts = UnsafeMutablePointer<vmpktdesc>.allocate(capacity: batch)
            defer { iovs.deallocate(); pkts.deallocate() }
            while true {
                for i in 0..<batch {
                    iovs[i] = iovec(iov_base: bufs[i], iov_len: bufSize)
                    pkts[i] = vmpktdesc(vm_pkt_size: bufSize, vm_pkt_iov: iovs + i, vm_pkt_iovcnt: 1, vm_flags: 0)
                }
                var count = Int32(batch)
                guard vmnet_read(started, pkts, &count) == .VMNET_SUCCESS, count > 0 else { return }
                self.writeLock.lock()
                for i in 0..<Int(count) {
                    let size = pkts[i].vm_pkt_size
                    if self.toVM < 10 { print("client \(self.id) to VM:   \(describeFrame(bufs[i], size))") }
                    self.toVM += 1
                    var len = UInt32(size).bigEndian
                    _ = writeAll(self.fd, &len, 4)
                    _ = writeAll(self.fd, bufs[i], size)
                }
                self.writeLock.unlock()
                if count < batch { return }
            }
        }

        // VM -> vmnet
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 16)
        defer { buf.deallocate() }
        while true {
            var len: UInt32 = 0
            guard readAll(fd, &len, 4) else { break }
            let size = Int(UInt32(bigEndian: len))
            guard size <= 65536, readAll(fd, buf, size) else { break }
            if fromVM < 10 { print("client \(id) from VM: \(describeFrame(buf, size))") }
            fromVM += 1
            var iov = iovec(iov_base: buf, iov_len: size)
            let st = withUnsafeMutablePointer(to: &iov) { iovPtr in
                var pkt = vmpktdesc(vm_pkt_size: size, vm_pkt_iov: iovPtr, vm_pkt_iovcnt: 1, vm_flags: 0)
                var count: Int32 = 1
                return vmnet_write(started, &pkt, &count)
            }
            if st != .VMNET_SUCCESS && fromVM < 20 { print("client \(id): vmnet_write status \(st.rawValue)") }
        }
        print("client \(id): disconnected (from VM \(fromVM), to VM \(toVM) frames)")
        stop()
        close(fd)
    }

    /// Stops the interface once; safe to call from any thread.
    func stop() {
        let target: interface_ref? = stateLock.withLock {
            guard !stopped else { return nil }
            stopped = true
            return iface
        }
        guard let target else { return }
        let done = DispatchSemaphore(value: 0)
        let st = vmnet_stop_interface(target, queue) { status in
            print("client \(self.id): interface stopped (status \(status.rawValue))")
            done.signal()
        }
        if st == .VMNET_SUCCESS { _ = done.wait(timeout: .now() + 10) }
    }
}

let clientsLock = NSLock()
nonisolated(unsafe) var clients: [Client] = []

let shutdown: @Sendable () -> Void = {
    print("shutting down")
    let all = clientsLock.withLock { clients }
    all.forEach { $0.stop() }
    unlink(socketPath)
    exit(0)
}
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler(handler: shutdown)
    source.resume()
    signalSources.append(source)
}

unlink(socketPath)
let server = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
}
let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard bound == 0, listen(server, 16) == 0 else { print("bind/listen: \(String(cString: strerror(errno)))"); exit(1) }
print("listening on \(socketPath)")

Thread.detachNewThread {
    var nextID = 1
    while true {
        let fd = accept(server, nil, nil)
        if fd < 0 { continue }
        let c = Client(fd: fd, id: nextID)
        nextID += 1
        clientsLock.withLock { clients.append(c) }
        Thread.detachNewThread { c.run() }
    }
}
dispatchMain()
