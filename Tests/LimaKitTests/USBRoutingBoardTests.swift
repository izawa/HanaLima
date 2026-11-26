import Foundation
import Testing
@testable import LimaKit

@Suite struct USBRoutingBoardTests {
    private let vm1 = USBTarget(instanceDir: "/vm1", machineIdentifier: "AQ==")
    private let vm2 = USBTarget(instanceDir: "/vm2", machineIdentifier: "Ag==")
    private func name(_ target: USBTarget) -> String? { ["/vm1": "vm1", "/vm2": "vm2"][target.instanceDir] }

    private func device(_ id: String, _ identity: USBDeviceIdentity, _ state: USBRoutingStatus.State = .observed,
                        error: String? = nil) -> USBRoutingStatus.Device {
        USBRoutingStatus.Device(registryID: id, identity: identity, destination: nil, rule: nil, hold: nil, state: state, error: error)
    }
    private func status(_ devices: USBRoutingStatus.Device...) -> USBRoutingStatus {
        USBRoutingStatus(me: nil, revision: "r", error: nil, devices: devices)
    }

    private let stick = USBDeviceIdentity(vendor: 0x8564, product: 0x1000, serial: "13AS", locationID: 0x0321_4400, name: "Stick")
    private let disk = USBDeviceIdentity(vendor: 0x04bb, product: 0x1031, serial: "2608", locationID: 0x0321_4100, name: "Disk")

    // MARK: rows

    @Test func oneRowPerDeviceWithTheVMThatHoldsIt() {
        let rows = USBRoutingBoard.rows([
            "vm1": status(device("a", stick, .observed), device("b", disk, .attached)),
            "vm2": status(device("a", stick, .attached), device("b", disk, .observed, error: "attaching: busy")),
        ])
        #expect(rows.map(\.id) == ["b", "a"])  // by name: Disk, Stick
        #expect(rows.first { $0.id == "a" }?.holder == "vm2")
        #expect(rows.first { $0.id == "b" }?.holder == "vm1")
        #expect(rows.first { $0.id == "b" }?.device.state == .attached)
        #expect(rows.first { $0.id == "b" }?.errors == ["vm2: attaching: busy"])
    }

    @Test func aDeviceNoOneHoldsHasNoHolder() {
        let rows = USBRoutingBoard.rows(["vm1": status(device("a", stick)), "vm2": status(device("a", stick))])
        #expect(rows.count == 1 && rows[0].holder == nil)
    }

    // MARK: absentRules

    @Test func rulesForDevicesNotConnected() {
        let gone = USBRoutes.Match(vendor: 1, product: 2, serial: "x")
        let routes = USBRoutes(rules: [.init(match: stick.serialMatch!, destination: vm1), .init(match: gone, destination: vm2),
                                       .init(match: disk.portMatch!, destination: vm2)])
        let rows = [USBDeviceRow(device: device("a", stick)), USBDeviceRow(device: device("b", disk))]
        #expect(USBRoutingBoard.absentRules(routes, rows: rows).map(\.match) == [gone])
    }

    // MARK: takenAway

    @Test func onlyAttachedDevicesSentElsewhereAreTakenAway() {
        let rows = [USBDeviceRow(device: device("a", stick, .attached), holder: "vm1"),
                    USBDeviceRow(device: device("b", disk, .attached), holder: "vm2"),
                    USBDeviceRow(device: device("c", USBDeviceIdentity(vendor: 9, product: 9, serial: "z"), .waiting), holder: "vm1")]
        // The stick stays on vm1, the disk goes to the default (none), the waiting one isn't attached.
        let routes = USBRoutes(rules: [.init(match: stick.serialMatch!, destination: vm1)])
        #expect(USBRoutingBoard.takenAway(by: routes, rows: rows, name: name).map(\.id) == ["b"])
        // Sending the stick to vm2 takes it away too.
        let moved = USBRoutes(rules: [.init(match: stick.serialMatch!, destination: vm2), .init(match: disk.serialMatch!, destination: vm2)])
        #expect(USBRoutingBoard.takenAway(by: moved, rows: rows, name: name).map(\.id) == ["a"])
    }

    // MARK: find

    @Test func findsTheDeviceEnumeratedAgain() {
        let chosen = USBDeviceRow(device: device("old", stick))
        var again = stick
        again.locationID = 0x0311_4400
        #expect(USBRoutingBoard.find(chosen, in: [USBDeviceRow(device: device("old", stick))])?.id == "old")
        #expect(USBRoutingBoard.find(chosen, in: [USBDeviceRow(device: device("new", again))])?.id == "new")
        // Two with the same key: can't tell which.
        let twins = [USBDeviceRow(device: device("n1", stick)), USBDeviceRow(device: device("n2", stick))]
        #expect(USBRoutingBoard.find(chosen, in: twins) == nil)
        #expect(USBRoutingBoard.find(chosen, in: [USBDeviceRow(device: device("x", disk))]) == nil)
    }

    // MARK: route

    @Test func routingADeviceReplacesItsRules() throws {
        let row = USBDeviceRow(device: device("a", stick))
        var routes = USBRoutes(rules: [.init(match: stick.portMatch!, destination: vm1)])
        routes = try USBRoutingBoard.route(routes, device: row, among: [row], to: vm2, bySerial: true)
        #expect(routes.rules == [.init(match: stick.serialMatch!, destination: vm2)])
        routes = try USBRoutingBoard.route(routes, device: row, among: [row], to: nil, bySerial: true)
        #expect(routes.rules.isEmpty)
    }

    @Test func aSharedSerialRuleBecomesPortRulesForEveryDevice() throws {
        let a = USBDeviceIdentity(vendor: 0x0c45, product: 0x6366, serial: "SN0001", locationID: 0x0321_4100)
        let b = USBDeviceIdentity(vendor: 0x0c45, product: 0x6366, serial: "SN0001", locationID: 0x0321_4200)
        let rows = [USBDeviceRow(device: device("a", a)), USBDeviceRow(device: device("b", b))]
        let routes = USBRoutes(rules: [.init(match: a.serialMatch!, destination: vm1)])
        let routed = try USBRoutingBoard.route(routes, device: rows[0], among: rows, to: vm2, bySerial: false)
        #expect(Set(routed.rules.map(\.match)) == [a.portMatch!, b.portMatch!])
        #expect(routed.rules.first { $0.match == a.portMatch }?.destination == vm2)
        #expect(routed.rules.first { $0.match == b.portMatch }?.destination == vm1)  // keeps the shared rule's VM
    }

    @Test func aSharedSerialRuleStaysIfATwinHasNoPortOfItsOwn() {
        let a = USBDeviceIdentity(vendor: 1, product: 2, serial: "S", locationID: 0x0321_4100)
        let noPort = USBDeviceIdentity(vendor: 1, product: 2, serial: "S")
        let samePort = USBDeviceIdentity(vendor: 1, product: 2, serial: "S", locationID: 0x0321_4100)
        let routes = USBRoutes(rules: [.init(match: a.serialMatch!, destination: vm1)])
        for twin in [noPort, samePort] {
            let rows = [USBDeviceRow(device: device("a", a)), USBDeviceRow(device: device("t", twin))]
            #expect(throws: USBRoutingBoard.Refusal.twinsWithoutPorts) {
                try USBRoutingBoard.route(routes, device: rows[0], among: rows, to: vm2, bySerial: false)
            }
        }
    }

    @Test func withoutASharedRuleOtherDevicesAreLeftAlone() throws {
        let a = USBDeviceIdentity(vendor: 1, product: 2, serial: "S", locationID: 0x0321_4100)
        let noPort = USBDeviceIdentity(vendor: 1, product: 2, serial: "S")
        let rows = [USBDeviceRow(device: device("a", a)), USBDeviceRow(device: device("t", noPort))]
        let routed = try USBRoutingBoard.route(USBRoutes(), device: rows[0], among: rows, to: vm2, bySerial: false)
        #expect(routed.rules == [.init(match: a.portMatch!, destination: vm2)])
    }
}
