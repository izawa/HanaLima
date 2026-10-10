import Foundation
import vmnet

func check(_ what: String, _ st: vmnet_return_t) {
    print("\(what): \(st == .VMNET_SUCCESS ? "OK" : "FAILED (\(st.rawValue))")")
}

var status = vmnet_return_t.VMNET_SUCCESS
let mode: operating_modes_t = CommandLine.arguments.contains("host") ? .VMNET_HOST_MODE : .VMNET_SHARED_MODE
guard let cfg = vmnet_network_configuration_create(mode, &status) else {
    check("configuration_create", status); exit(1)
}
check("configuration_create(\(mode == .VMNET_HOST_MODE ? "host" : "shared"))", status)

var subnet = in_addr(), mask = in_addr()
inet_pton(AF_INET, "192.168.200.1", &subnet)
inet_pton(AF_INET, "255.255.255.0", &mask)
if CommandLine.arguments.contains("subnet") { check("set_ipv4_subnet 192.168.200.1/24", vmnet_network_configuration_set_ipv4_subnet(cfg, &subnet, &mask)) }

guard let net = vmnet_network_create(cfg, &status) else { check("network_create", status); exit(1) }
check("network_create", status)
var s = in_addr(), m = in_addr()
vmnet_network_get_ipv4_subnet(net, &s, &m)
print("  subnet:", String(cString: inet_ntoa(s)), String(cString: inet_ntoa(m)))

let ser = vmnet_network_copy_serialization(net, &status)
check("copy_serialization (cross-process sharing)", status)
_ = ser

let desc = xpc_dictionary_create(nil, nil, 0)
let q = DispatchQueue(label: "vmnet")
let sem = DispatchSemaphore(value: 0)
var ifaces: [interface_ref] = []
for i in 1...2 {
    let iface = vmnet_interface_start_with_network(net, desc, q) { st, params in
        check("interface_start #\(i)", st)
        if let params {
            let mac = xpc_dictionary_get_string(params, vmnet_mac_address_key).map { String(cString: $0) } ?? "?"
            let mtu = xpc_dictionary_get_uint64(params, vmnet_mtu_key)
            let maxPkt = xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key)
            print("  mac=\(mac) mtu=\(mtu) maxPacket=\(maxPkt)")
        }
        sem.signal()
    }
    if let iface { ifaces.append(iface) } else { print("interface_start #\(i): returned NULL") ; sem.signal() }
    _ = sem.wait(timeout: .now() + 10)
}
// Show the host-side bridge interface vmnet created.
let p = Process(); p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig"); p.arguments = ["-a"]
let pipe = Pipe(); p.standardOutput = pipe; try p.run(); p.waitUntilExit()
let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
for line in out.split(separator: "\n") where line.contains("192.168.200.") { print("  host:", line.trimmingCharacters(in: .whitespaces)) }
for iface in ifaces {
    let st = vmnet_stop_interface(iface, q) { st in check("stop_interface", st); sem.signal() }
    check("stop_interface request", st)
    _ = sem.wait(timeout: .now() + 5)
}
