// PoC: rootless socket_vmnet replacement on macOS 26 vmnet_network APIs.
// usage: hanalima-net <socket> <shared|host> <gateway> <netmask>
import Foundation
import vmnet

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count == 5 else { print("usage: hanalima-net <socket> <shared|host> <gateway> <netmask>"); exit(2) }
let socketPath = args[1]
let mode: operating_modes_t = args[2] == "host" ? .VMNET_HOST_MODE : .VMNET_SHARED_MODE

var status = vmnet_return_t.VMNET_SUCCESS
guard let cfg = vmnet_network_configuration_create(mode, &status) else { fatalError("config \(status.rawValue)") }
var gw = in_addr(), mask = in_addr()
inet_pton(AF_INET, args[3], &gw); inet_pton(AF_INET, args[4], &mask)
precondition(vmnet_network_configuration_set_ipv4_subnet(cfg, &gw, &mask) == .VMNET_SUCCESS)
guard let network = vmnet_network_create(cfg, &status) else { fatalError("network_create \(status.rawValue)") }
print("network up: \(args[2]) \(args[3])/\(args[4])")

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

final class Client {
    let fd: Int32
    let id: Int
    let network: vmnet_network_ref
    var iface: interface_ref?
    var maxPacket = 1514
    let queue: DispatchQueue
    let writeLock = NSLock()
    init(fd: Int32, id: Int, network: vmnet_network_ref) { self.fd = fd; self.id = id; self.network = network; queue = DispatchQueue(label: "client\(id)") }

    func run() {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        iface = vmnet_interface_start_with_network(network, xpc_dictionary_create(nil, nil, 0), queue) { st, params in
            ok = st == .VMNET_SUCCESS
            if let params {
                self.maxPacket = Int(xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key))
                let mac = xpc_dictionary_get_string(params, vmnet_mac_address_key).map { String(cString: $0) } ?? "?"
                print("client \(self.id): interface started (vmnet mac \(mac))")
            }
            sem.signal()
        }
        sem.wait()
        guard ok, let iface else { print("client \(id): interface start failed"); close(fd); return }

        // vmnet -> VM
        let batch = 32
        let bufSize = maxPacket
        vmnet_interface_set_event_callback(iface, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue) { _, _ in
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
                guard vmnet_read(iface, pkts, &count) == .VMNET_SUCCESS, count > 0 else { return }
                self.writeLock.lock()
                for i in 0..<Int(count) {
                    var len = UInt32(pkts[i].vm_pkt_size).bigEndian
                    _ = writeAll(self.fd, &len, 4)
                    _ = writeAll(self.fd, bufs[i], pkts[i].vm_pkt_size)
                }
                self.writeLock.unlock()
                if count < batch { return }
            }
        }

        // VM -> vmnet
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 16)
        defer { buf.deallocate() }
        var sent = 0
        while true {
            var len: UInt32 = 0
            guard readAll(fd, &len, 4) else { break }
            let size = Int(UInt32(bigEndian: len))
            guard size <= 65536, readAll(fd, buf, size) else { break }
            var iov = iovec(iov_base: buf, iov_len: size)
            var pkt = vmpktdesc(vm_pkt_size: size, vm_pkt_iov: &iov, vm_pkt_iovcnt: 1, vm_flags: 0)
            var count: Int32 = 1
            _ = vmnet_write(iface, &pkt, &count)
            sent += 1
        }
        print("client \(id): disconnected after \(sent) packets from VM")
        let done = DispatchSemaphore(value: 0)
        _ = vmnet_stop_interface(iface, queue) { _ in done.signal() }
        done.wait()
        close(fd)
    }
}

unlink(socketPath)
let server = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    _ = socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
}
let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard bound == 0, listen(server, 16) == 0 else { fatalError("bind/listen: \(String(cString: strerror(errno)))") }
print("listening on \(socketPath)")
var nextID = 1
while true {
    let fd = accept(server, nil, nil)
    if fd < 0 { continue }
    let c = Client(fd: fd, id: nextID, network: network); nextID += 1
    Thread { c.run() }.start()
}
