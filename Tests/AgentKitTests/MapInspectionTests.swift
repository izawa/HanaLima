import Foundation
import Testing
@testable import AgentKit
import NetworkKit

struct MapInspectionTests {
    private let lab = NetworkMap.Bus(id: "/net/lab.sock", name: "lab", kind: .guestOnly(router: "10.0.0.1", routerVM: "gw"),
                                     subnet: "10.0.0.0/24", gateway: "10.0.0.254", macOnSegment: false)
    private let demo = NetworkMap.Bus(id: "/net/demo.sock", name: "demo", kind: .nat, subnet: "192.168.200.0/24",
                                      gateway: "192.168.200.1", macOnSegment: true)

    private func row(_ name: String, _ ports: [NetworkMap.Port], usernet: Bool = false, vzNATMAC: String? = nil,
                     running: Bool = true) -> NetworkMap.Row {
        .init(kind: .vm, name: name, running: running, vmType: "hanalima", group: nil, ports: ports, usernet: usernet,
              vzNAT: vzNATMAC != nil, vzNATMAC: vzNATMAC, routerOf: [])
    }

    private func nic(_ mac: String, _ ip: String?, _ source: NetworkMap.Address.Source = .lease, interface: String? = nil) -> NetworkMap.NIC {
        .init(mac: mac, addresses: ip.map { [.init(ip: $0, source: source)] } ?? [], interface: interface)
    }

    private var map: NetworkMap {
        NetworkMap(buses: [lab, demo],
                   mac: .init(kind: .mac, name: "Mac", running: true, vmType: nil, group: nil, ports: [], usernet: false,
                              vzNAT: false, vzNATMAC: nil, routerOf: []),
                   rows: [row("gw", [.init(bus: lab.id, nics: [nic("02:00:00:00:00:01", "10.0.0.1", .reservation)])], usernet: true),
                          row("a", [.init(bus: lab.id, nics: [nic("02:00:00:00:00:02", "10.0.0.11", interface: "lima0"),
                                                              nic("02:00:00:00:00:03", "10.0.0.12", interface: "lima1")])]),
                          row("b", [.init(bus: demo.id, nics: [nic("02:00:00:00:00:04", nil)])], vzNATMAC: "02:00:00:00:00:05"),
                          row("lonely", [])])
    }

    @Test func endpointNamesTheNICOnlyWhenTheVMHasSeveralOnTheBus() {
        #expect(map.endpoint(on: lab.id, macs: ["02:00:00:00:00:01"])! == ("gw", nil))
        #expect(map.endpoint(on: lab.id, macs: ["02:00:00:00:00:03"])! == ("a", "lima1"))
        #expect(map.endpoint(on: demo.id, macs: ["02:00:00:00:00:01"]) == nil)  // that MAC is on another bus
    }

    @Test func busesWithKindRouterAndTheMac() {
        #expect(MapInspection.buses(map) == [
            "lab\tguestOnly\t10.0.0.0/24\t10.0.0.254\t10.0.0.1\tgw\tfalse",
            "demo\tshared\t192.168.200.0/24\t192.168.200.1\t-\t-\ttrue",
        ])
        #expect(MapInspection.buses(map, vms: ["b"]).count == 1)
    }

    @Test func linksPerBusAndExitWithTheLastCheck() {
        let probe = MapProbe(id: "p1", vm: "gw", bus: nil, exit: .nic0, mac: "02:00:00:00:00:09", target: .outside("1.1.1.1"))
        let record = MapCheckRecord(probes: [probe], outcomes: ["p1": .init(reached: true, reason: nil)], observed: [:], at: .now)
        let links = MapInspection.links(map, checks: ["gw": (record, true)])
        #expect(links == [
            "gw\ttrue\tlab\t1\t10.0.0.1/reservation\t-",
            "gw\ttrue\texit:nic0\t1\t-\tstale/reached",
            "a\ttrue\tlab\t2\t10.0.0.11/lease,10.0.0.12/lease\t-",
            "b\ttrue\tdemo\t1\t-\t-",
            "b\ttrue\texit:vzNAT\t1\t-\t-",
            "lonely\ttrue\t-\t0\t-\t-",
        ])
        #expect(MapInspection.links(map, checks: [:], vms: ["lonely"]) == ["lonely\ttrue\t-\t0\t-\t-"])
        // A NIC with no lease (a bridge) shows what its guest reported at the last check.
        let seen = MapCheckRecord(probes: [], outcomes: [:], observed: ["02:00:00:00:00:04": ["192.168.200.77"]], at: .now)
        #expect(MapInspection.links(map, checks: ["b": (seen, false)], vms: ["b"]).first == "b\ttrue\tdemo\t1\t192.168.200.77/observed\t-")
        #expect(MapInspection.links(map, checks: ["b": (seen, true)], vms: ["b"]).first == "b\ttrue\tdemo\t1\t192.168.200.77/observed-stale\t-")
        // A lease found only by host name doesn't hide what each NIC's guest reported.
        let twin = NetworkMap(buses: [lab], mac: map.mac, rows: [row("t", [.init(bus: lab.id, nics: [
            nic("02:00:00:00:00:21", "10.0.0.30", .leaseByName), nic("02:00:00:00:00:22", "10.0.0.30", .leaseByName)])])])
        let both = MapCheckRecord(probes: [], outcomes: [:], observed: ["02:00:00:00:00:21": ["10.0.0.30"],
                                                                         "02:00:00:00:00:22": ["10.0.0.31"]], at: .now)
        #expect(MapInspection.links(twin, checks: ["t": (both, false)]).first
                == "t\ttrue\tlab\t2\t10.0.0.30/leaseByName,10.0.0.30/observed,10.0.0.31/observed\t-")
    }

    @Test func aSharedUserV2NetworkStandingInForNIC0IsNoSeparateExit() {
        let v2 = NetworkMap.Bus(id: "lima:user-v2", name: "user-v2", kind: .lima(mode: "user-v2"), subnet: nil, gateway: nil, macOnSegment: false)
        let m = NetworkMap(buses: [v2], mac: map.mac,
                           rows: [row("u", [.init(bus: v2.id, nics: [.init(mac: nil, addresses: [])])], usernet: true)])
        #expect(MapInspection.links(m, checks: [:]) == ["u\ttrue\tuser-v2\t1\t-\t-"])
        let probe = MapProbe(id: "p1", vm: "u", bus: nil, exit: .nic0, mac: "52:55:55:00:00:01", target: .outside("1.1.1.1"))
        let record = MapCheckRecord(probes: [probe], outcomes: ["p1": .init(reached: true, reason: nil)], observed: [:], at: .now)
        #expect(MapInspection.links(m, checks: ["u": (record, false)]) == ["u\ttrue\tuser-v2\t1\t-\treached"])
    }

    @Test func aStaleResultKeepsTheMACItWasSentFrom() {
        let probe = MapProbe(id: "p1", vm: "a", bus: lab.id, exit: nil, mac: "02:00:00:00:00:03", target: .router("10.0.0.1"))
        let record = MapCheckRecord(probes: [probe], outcomes: ["p1": .init(reached: true, reason: nil)], observed: [:], at: .now)
        #expect(MapInspection.checks(map, checks: ["a": (record, true)]).first?.split(separator: "\t")[2] == "02:00:00:00:00:03")
    }

    @Test func checksPerProbeAndNotCheckedForTheRest() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let probes = [MapProbe(id: "p1", vm: "a", bus: lab.id, exit: nil, mac: "02:00:00:00:00:03", target: .router("10.0.0.1")),
                      MapProbe(id: "p2", vm: "a", bus: lab.id, exit: nil, mac: "02:00:00:00:00:03", target: .peer(vm: "gw", ip: "10.0.0.1"))]
        let record = MapCheckRecord(probes: probes, outcomes: ["p1": .init(reached: true, reason: nil),
                                                                "p2": .init(reached: false, reason: "no\treply", at: at)],
                                    observed: [:], at: at.addingTimeInterval(-60))
        let rows = MapInspection.checks(map, checks: ["a": (record, false)], vms: ["a", "b"])
        #expect(rows == [
            "a\tlab\tlima1\trouter\t10.0.0.1\treached\t2027-01-15T07:59:00Z\tfalse\t-",
            "a\tlab\tlima1\tpeer:gw\t10.0.0.1\tunverified\t2027-01-15T08:00:00Z\tfalse\tno reply",
            "b\t-\t-\t-\t-\tnotChecked\t-\t-\t-",
        ])
        #expect(MapInspection.checks(map, checks: [:]).isEmpty)  // with no ids, only VMs that were checked
        #expect(MapInspection.checks(map, checks: ["a": (record, false)], vms: []).isEmpty)  // ids given, none known
        let noTargets = MapCheckRecord(probes: [], outcomes: [:], observed: [:], at: at)
        #expect(MapInspection.checks(map, checks: ["b": (noTargets, true)]) == ["b\t-\t-\t-\t-\tnoTargets\t2027-01-15T08:00:00Z\ttrue\t-"])
    }

    @Test func observationStatesFaultsAndPorts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(MapInspection.observation(network: "lab", bus: lab.id, reading: .notRunning, map: map, now: now, ports: true).summary
                == "lab\tnotRunning\t-\t-\t-\t-\t-\t-\t-\t-\t-")
        #expect(MapInspection.observation(network: "lab", bus: lab.id, reading: .olderHelper, map: map, now: now, ports: true).summary
                .hasPrefix("lab\tolderHelper\t"))

        var o = NetworkObservation(runID: "r1", sequence: 9, sampledAt: now.addingTimeInterval(-3), uptime: 60,
                                   ports: [.init(id: 1, macs: ["02:00:00:00:00:03"], connectedAt: now),
                                           .init(id: 2, macs: [], connectedAt: now, connected: false)])
        o.ports[0].fromGuest = .init(frames: 4, bytes: 400)
        o.answered = .init(frames: 2, bytes: 684)
        o.capabilities = [NetworkObservation.faultsCapability]
        o.faults = [NetworkFault(id: "f1", spec: .init(target: "02:00:00:00:00:03", delayMs: 100, lossPercent: 0.5, seconds: 60),
                                 startedAt: now, expiresAt: now.addingTimeInterval(60)),
                    NetworkFault(id: "f2", spec: .init(target: "*", block: true, seconds: 30),
                                 startedAt: now, expiresAt: now.addingTimeInterval(30))]
        let rows = MapInspection.observation(network: "lab", bus: lab.id, reading: .sample(o), map: map, now: now, ports: false)
        #expect(rows.summary == "lab\tfresh\t2027-01-15T07:59:57Z\tr1\t60.0\t1\t2/684\t0\t0\t-\t2")
        #expect(rows.faults == ["fault\tlab\tf1\ta/lima1\tfalse\t100\t0.5\t2027-01-15T08:01:00Z",
                                "fault\tlab\tf2\t*\ttrue\t0\t0\t2027-01-15T08:00:30Z"])
        #expect(rows.ports.isEmpty)

        // Past three seconds the sample is stale; an older helper's file has no fault fields.
        o.sampledAt = now.addingTimeInterval(-3.5)
        o.capabilities = nil
        let old = MapInspection.observation(network: "lab", bus: lab.id, reading: .sample(o), map: map, now: now, ports: true)
        #expect(old.summary.hasPrefix("lab\tstale\t"))
        #expect(old.summary.hasSuffix("\tunsupported"))
        #expect(old.faults.isEmpty)
        #expect(old.ports == ["port\tlab\ta/lima1\t1\ttrue\t4/400\t0/0\t0/0\t0/0\t-\t-\t-\t-\t0",
                              "port\tlab\t-\t2\tfalse\t0/0\t0/0\t0/0\t0/0\t-\t-\t-\t-\t0"])
    }
}
