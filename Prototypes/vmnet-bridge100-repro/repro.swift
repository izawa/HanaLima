// Minimal reproduction: a legacy bridged vmnet interface and a macOS 26 vmnet_network end up on
// the same kernel bridge (bridge100); whichever is activated later breaks the other.
//
// Build:
//   swiftc -O -o repro repro.swift
//   codesign -s - -f --entitlements entitlements.plist repro
// Run (two terminals; each mode keeps its interface up until Ctrl-C):
//   ./repro bridged en0                   # legacy API, VMNET_BRIDGED_MODE (worked without root on macOS 27.0.1 when signed as above)
//   ./repro network 192.168.240.1         # macOS 26 API, shared mode, custom subnet
//   ./repro network-cycle 192.168.240.1   # same, but Enter stops / restarts the interface on the
//                                         # SAME vmnet_network object (as a long-lived helper would)
// Observe with: ifconfig bridge100; ifconfig en0 | grep 'inet '

import Foundation
import vmnet

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let queue = DispatchQueue(label: "repro")

func describe(_ params: xpc_object_t?) -> String {
    guard let params else { return "" }
    let mac = xpc_dictionary_get_string(params, vmnet_mac_address_key).map { String(cString: $0) } ?? "?"
    return "vmnet mac \(mac)"
}

/// Waits for Ctrl-C, then stops the interface before exiting. Exiting with the interface still
/// started leaves its subnet reserved by vmnet until the Mac restarts (vmnet_network_create then
/// fails with VMNET_FAILURE for that subnet).
func waitForCtrlC(stopping iface: interface_ref) -> Never {
    print("interface is up; press Ctrl-C to stop")
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        let done = DispatchSemaphore(value: 0)
        let st = vmnet_stop_interface(iface, queue) { status in
            print("interface stopped: status \(status.rawValue)")
            done.signal()
        }
        if st == .VMNET_SUCCESS { _ = done.wait(timeout: .now() + 10) }
        exit(0)
    }
    source.resume()
    dispatchMain()
}

switch args.dropFirst().first {
case "bridged":
    guard args.count == 3 else { print("usage: ./repro bridged <interface>"); exit(2) }
    let desc = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, UInt64(operating_modes_t.VMNET_BRIDGED_MODE.rawValue))
    xpc_dictionary_set_string(desc, vmnet_shared_interface_name_key, args[2])
    let done = DispatchSemaphore(value: 0)
    let iface = vmnet_start_interface(desc, queue) { status, params in
        print("legacy bridged interface on \(args[2]): status \(status.rawValue) \(describe(params))")
        done.signal()
    }
    done.wait()
    guard let iface else { print("vmnet_start_interface returned NULL"); exit(1) }
    waitForCtrlC(stopping: iface)

case "network":
    guard args.count == 3 else { print("usage: ./repro network <gateway, e.g. 192.168.240.1>"); exit(2) }
    var status = vmnet_return_t.VMNET_SUCCESS
    guard let config = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
        print("vmnet_network_configuration_create: \(status.rawValue)"); exit(1)
    }
    var gw = in_addr(), mask = in_addr()
    inet_pton(AF_INET, args[2], &gw)
    inet_pton(AF_INET, "255.255.255.0", &mask)
    print("set_ipv4_subnet: \(vmnet_network_configuration_set_ipv4_subnet(config, &gw, &mask).rawValue)")
    guard let network = vmnet_network_create(config, &status) else {
        print("vmnet_network_create: \(status.rawValue)"); exit(1)
    }
    let done = DispatchSemaphore(value: 0)
    let iface = vmnet_interface_start_with_network(network, xpc_dictionary_create(nil, nil, 0), queue) { status, params in
        print("vmnet_network interface: status \(status.rawValue) \(describe(params))")
        done.signal()
    }
    done.wait()
    guard let iface else { print("vmnet_interface_start_with_network returned NULL"); exit(1) }
    waitForCtrlC(stopping: iface)

case "network-cycle":
    // Like "network", but keeps the vmnet_network object and lets Enter stop and restart its
    // interface. While stopped, the network's bridge is torn down; on restart the network reuses
    // the bridge unit it was given at first activation (cf. apple/container#2051), even if a
    // legacy bridged interface has claimed that unit in the meantime.
    guard args.count == 3 else { print("usage: ./repro network-cycle <gateway>"); exit(2) }
    var status = vmnet_return_t.VMNET_SUCCESS
    guard let config = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
        print("vmnet_network_configuration_create: \(status.rawValue)"); exit(1)
    }
    var gw = in_addr(), mask = in_addr()
    inet_pton(AF_INET, args[2], &gw)
    inet_pton(AF_INET, "255.255.255.0", &mask)
    print("set_ipv4_subnet: \(vmnet_network_configuration_set_ipv4_subnet(config, &gw, &mask).rawValue)")
    guard let network = vmnet_network_create(config, &status) else {
        print("vmnet_network_create: \(status.rawValue)"); exit(1)
    }
    let lock = NSLock()
    nonisolated(unsafe) var current: interface_ref?

    func startInterface() {
        let done = DispatchSemaphore(value: 0)
        let iface = vmnet_interface_start_with_network(network, xpc_dictionary_create(nil, nil, 0), queue) { status, params in
            print("vmnet_network interface started: status \(status.rawValue) \(describe(params))")
            done.signal()
        }
        done.wait()
        lock.withLock { current = iface }
    }

    func stopInterface() {
        guard let iface = lock.withLock({ () -> interface_ref? in let i = current; current = nil; return i }) else { return }
        let done = DispatchSemaphore(value: 0)
        let st = vmnet_stop_interface(iface, queue) { status in
            print("interface stopped (network object kept): status \(status.rawValue)")
            done.signal()
        }
        if st == .VMNET_SUCCESS { _ = done.wait(timeout: .now() + 10) }
    }

    startInterface()
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        stopInterface()
        exit(0)
    }
    source.resume()
    Thread.detachNewThread {
        while true {
            let running = lock.withLock { current != nil }
            print(running ? "press Enter to STOP the interface (Ctrl-C to quit)"
                          : "press Enter to START the interface again on the same network (Ctrl-C to quit)")
            guard readLine() != nil else { return }
            if lock.withLock({ current != nil }) { stopInterface() } else { startInterface() }
        }
    }
    dispatchMain()

default:
    print("usage: ./repro bridged <interface> | ./repro network <gateway> | ./repro network-cycle <gateway>")
    exit(2)
}
