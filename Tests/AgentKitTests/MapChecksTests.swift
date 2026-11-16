import Foundation
import Testing
@testable import AgentKit
import LimaKit
import NetworkKit

struct MapChecksTests {
    private func row(_ name: String, _ ports: [NetworkMap.Port], usernet: Bool = true, vzNATMAC: String? = nil) -> NetworkMap.Row {
        .init(kind: .vm, name: name, running: true, vmType: "hanalima", group: nil, ports: ports, usernet: usernet,
              vzNAT: vzNATMAC != nil, vzNATMAC: vzNATMAC, routerOf: [])
    }
    private func port(_ bus: String, _ mac: String, _ ips: [String]) -> NetworkMap.Port {
        .init(bus: bus, nics: [.init(mac: mac, addresses: ips.map { .init(ip: $0, source: .lease) })])
    }
    private let nat = NetworkMap.Bus(id: "nat", name: "demo", kind: .nat, subnet: nil, gateway: "192.168.200.1", macOnSegment: true)
    private let lab = NetworkMap.Bus(id: "lab", name: "lab", kind: .guestOnly(router: "10.0.0.1", routerVM: "gw"),
                                     subnet: nil, gateway: "10.0.0.254", macOnSegment: false)
    private let lan = NetworkMap.Bus(id: "lan", name: "lan", kind: .bridged(interface: "en0"), subnet: nil, gateway: nil, macOnSegment: true)

    private var map: NetworkMap {
        NetworkMap(buses: [nat, lab, lan],
                   mac: .init(kind: .mac, name: "Mac", running: true, vmType: nil, group: nil, ports: [], usernet: false,
                              vzNAT: false, vzNATMAC: nil, routerOf: []),
                   rows: [row("gw", [port("lab", "02:00:00:00:00:01", ["10.0.0.1"])]),
                          row("a", [port("lab", "02:00:00:00:00:02", ["10.0.0.11"]), port("nat", "02:00:00:00:00:03", ["192.168.200.10"]),
                                    port("lan", "02:00:00:00:00:04", [])], usernet: false),
                          row("b", [port("lab", "02:00:00:00:00:05", ["10.0.0.12", "10.0.0.99"])], vzNATMAC: "02:00:00:00:00:06")])
    }

    @Test func plansProbesPerNIC() {
        let plans = MapChecks.plan(map, vms: ["gw", "a", "b"], outside: "1.1.1.1") { _ in "02:00:00:00:00:aa" }
        // The router pings no router; its peer is the next VM with one address on lab (b has two).
        #expect(plans["gw"]?.map(\.target) == [.peer(vm: "a", ip: "10.0.0.11"), .outside("1.1.1.1")])
        #expect(plans["gw"]?.last?.exit == .nic0)
        let a = plans["a"] ?? []
        // gw is both the router and the next peer: pinged once.
        #expect(a.filter { $0.bus == "lab" }.map(\.target) == [.router("10.0.0.1"), .outside("1.1.1.1")])
        #expect(a.filter { $0.bus == "nat" }.map(\.target) == [.gateway("192.168.200.1")])  // no other VM on demo
        #expect(!a.contains { $0.bus == "lan" })  // bridges: nothing to ping
        #expect(!a.contains { $0.exit == .nic0 })  // isolated
        #expect(plans["b"]?.contains { $0.exit == .vzNAT } == true)
        #expect(Set(a.map(\.id)).count == a.count)
    }

    @Test func aPeerNeedsAnAddressTiedToItsNIC() {
        var m = map
        // a's lab address came from a lease found by name only: not a peer anyone pings.
        m.rows[1].ports[0].nics[0].addresses = [.init(ip: "10.0.0.11", source: .leaseByName)]
        let plans = MapChecks.plan(m, vms: ["gw"], outside: nil) { _ in nil }
        #expect(plans["gw"] == nil)
    }

    @Test func scopesAndNoOutsideWithoutAnAddress() {
        let plans = MapChecks.plan(map, vms: ["a"], bus: "nat", outside: "1.1.1.1") { _ in nil }
        #expect(plans["a"]?.map(\.target) == [.gateway("192.168.200.1")])
        let none = MapChecks.plan(map, vms: ["gw"], outside: nil) { _ in "02:00:00:00:00:aa" }
        #expect(none["gw"]?.contains { $0.exit != nil } == false)
    }

    @Test func statesPerNIC() {
        let p = [MapProbe(id: "p1", vm: "a", bus: "lab", mac: "m1", target: .router("10.0.0.1")),
                 MapProbe(id: "p2", vm: "a", bus: "lab", mac: "m1", target: .peer(vm: "gw", ip: "10.0.0.1")),
                 MapProbe(id: "p3", vm: "a", bus: "lab", mac: "m2", target: .router("10.0.0.1"))]
        func rec(_ ok: [String]) -> MapCheckRecord {
            .init(probes: p, outcomes: Dictionary(uniqueKeysWithValues: p.map { ($0.id, .init(reached: ok.contains($0.id), reason: nil)) }),
                  observed: [:], at: .now)
        }
        #expect(MapChecks.state(bus: "lab", in: rec(["p1", "p2", "p3"])) == .reached)
        #expect(MapChecks.state(bus: "lab", in: rec(["p1", "p3"])) == .partial(reached: 1, of: 2))
        #expect(MapChecks.state(bus: "lab", in: rec([])) == .unverified)
        #expect(MapChecks.state(bus: "nat", in: rec(["p1"])) == .configOnly)
        #expect(MapChecks.state(bus: "lab", in: nil) == .configOnly)
    }

    /// Runs the generated script with a fake /sys/class/net and stub ip and ping.
    @Test func scriptBindsPingsToTheNIC() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sys = dir.appendingPathComponent("net"), bin = dir.appendingPathComponent("bin")
        for (iface, mac) in [("eth0", "02:00:00:00:00:aa"), ("lima0", "02:00:00:00:00:02")] {
            try FileManager.default.createDirectory(at: sys.appendingPathComponent(iface), withIntermediateDirectories: true)
            try (mac + "\n").write(to: sys.appendingPathComponent("\(iface)/address"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stubs = [
            // ping succeeds only through lima0.
            "ping": "#!/bin/sh\n[ \"$2\" = lima0 ]\n",
            "ip": "#!/bin/sh\n[ \"$6\" = lima0 ] && echo '3: lima0    inet 10.0.0.11/24 brd 10.0.0.255 scope global lima0'\nexit 0\n",
        ]
        for (name, body) in stubs {
            let f = bin.appendingPathComponent(name)
            try body.write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.path)
        }
        let probes = [MapProbe(id: "p1", vm: "a", bus: "lab", mac: "02:00:00:00:00:02", target: .router("10.0.0.1")),
                      MapProbe(id: "p2", vm: "a", exit: .nic0, mac: "02:00:00:00:00:aa", target: .outside("1.1.1.1")),
                      MapProbe(id: "p3", vm: "a", bus: "lab", mac: "02:00:00:00:00:ff", target: .router("10.0.0.1"))]
        let script = MapChecks.script(probes: probes, macs: ["02:00:00:00:00:02", "02:00:00:00:00:aa"])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["PATH": bin.path + ":/usr/bin:/bin", "HLSYS": sys.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let record = MapChecks.record(probes: probes, output: text, runError: nil, at: .now)
        #expect(record.outcomes["p1"]?.reached == true)
        #expect(record.outcomes["p2"]?.reason == "no reply" && record.outcomes["p2"]?.reached == false)
        #expect(record.outcomes["p3"]?.reason == "no NIC with this MAC")
        #expect(record.observed == ["02:00:00:00:00:02": ["10.0.0.11"]])
        let failed = MapChecks.record(probes: probes, output: text, runError: "timed out", at: .now)
        #expect(failed.outcomes.values.allSatisfy { !$0.reached } && failed.observed.isEmpty)
    }
}
