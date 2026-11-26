import Foundation
import Testing
@testable import LimaKit

@Suite struct USBRoutesTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "usbroutes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let vm1 = USBTarget(instanceDir: "/vm1", machineIdentifier: "AQ==")
    private let vm2 = USBTarget(instanceDir: "/vm2", machineIdentifier: "Ag==")
    private let stick = USBDeviceIdentity(vendor: 0x8564, product: 0x1000, serial: "13AS", locationID: 1)
    private let camera = USBDeviceIdentity(vendor: 0x0c45, product: 0x6366, serial: "SN0001", locationID: 2)

    // MARK: File

    @Test func nothingSavedHoldsEverything() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let routes = try USBRoutes.load(support: dir).get()
        #expect(routes == USBRoutes())
        #expect(routes.decision(for: stick, among: [stick]) == .hold(.noDefault))
    }

    @Test func theOldTargetIsTheDefaultRouteUntilSaved() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appending(path: USBTarget.fileName)
        try USBTarget.save(vm1, to: old)
        #expect(try USBRoutes.load(support: dir).get().defaultRoute == vm1)
        var routes = try USBRoutes.load(support: dir).get()
        routes.rules = [.init(match: stick.serialMatch!, destination: vm2)]
        let saved = try routes.save(support: dir)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try USBRoutes.load(support: dir).get() == saved)
        #expect(saved.defaultRoute == vm1)
    }

    @Test func theNewTableWinsOverAnOldFileLeftBehind() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = try USBRoutes(defaultRoute: vm2).save(support: dir)
        try USBTarget.save(vm1, to: dir.appending(path: USBTarget.fileName))
        #expect(try USBRoutes.load(support: dir).get() == saved)
    }

    @Test func eachSaveHasANewRevision() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try USBRoutes().save(support: dir)
        let b = try USBRoutes().save(support: dir)
        #expect(!a.revision.isEmpty && a.revision != b.revision)
    }

    @Test func aBrokenOrNewerTableDoesNotFallBack() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try USBTarget.save(vm1, to: dir.appending(path: USBTarget.fileName))
        let file = dir.appending(path: USBRoutes.fileName)
        try Data("{".utf8).write(to: file)
        #expect(throws: USBRoutes.LoadError.self) { try USBRoutes.load(support: dir).get() }
        try Data(#"{"version": 2, "revision": "x", "rules": []}"#.utf8).write(to: file)
        #expect(USBRoutes.load(support: dir) == .failure(.unknownVersion(2)))
    }

    @Test func rulesNeedOneKeyAndNoTwins() throws {
        let both = USBRoutes.Match(vendor: 1, product: 2, serial: "s", locationID: 3)
        #expect(throws: USBRoutes.LoadError.self) { try USBRoutes(rules: [.init(match: both, destination: vm1)]).validate() }
        let empty = USBRoutes.Match(vendor: 1, product: 2, serial: "")
        #expect(throws: USBRoutes.LoadError.self) { try USBRoutes(rules: [.init(match: empty, destination: vm1)]).validate() }
        let twins = USBRoutes(rules: [.init(match: stick.serialMatch!, destination: vm1), .init(match: stick.serialMatch!, destination: vm2)])
        #expect(throws: USBRoutes.LoadError.self) { try twins.validate() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: USBRoutes.LoadError.self) { try twins.save(support: dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: USBRoutes.fileName).path))
    }

    // MARK: Decision

    @Test func serialThenPortThenDefault() {
        var routes = USBRoutes(defaultRoute: vm1)
        #expect(routes.decision(for: stick, among: [stick]) == .send(vm1, by: .defaultRoute))
        routes.rules = [.init(match: stick.portMatch!, destination: vm2)]
        #expect(routes.decision(for: stick, among: [stick]) == .send(vm2, by: .port))
        routes.rules.append(.init(match: stick.serialMatch!, destination: vm1))
        #expect(routes.decision(for: stick, among: [stick]) == .send(vm1, by: .serial))
        // Another device is untouched by the stick's rules.
        #expect(routes.decision(for: camera, among: [stick, camera]) == .send(vm1, by: .defaultRoute))
    }

    @Test func aRuleThatMatchesTwoDevicesHoldsBoth() {
        let twin = USBDeviceIdentity(vendor: camera.vendor, product: camera.product, serial: "SN0001", locationID: 9)
        let routes = USBRoutes(defaultRoute: vm1, rules: [.init(match: camera.serialMatch!, destination: vm2)])
        #expect(routes.decision(for: camera, among: [camera, twin]) == .hold(.duplicate))
        #expect(routes.decision(for: twin, among: [camera, twin]) == .hold(.duplicate))
        // By port, each goes its own way.
        let byPort = USBRoutes(rules: [.init(match: camera.portMatch!, destination: vm1), .init(match: twin.portMatch!, destination: vm2)])
        #expect(byPort.decision(for: camera, among: [camera, twin]) == .send(vm1, by: .port))
        #expect(byPort.decision(for: twin, among: [camera, twin]) == .send(vm2, by: .port))
    }

    @Test func anUnreadableDeviceIsHeldOnlyIfARuleMayBeAboutIt() {
        let unread = USBDeviceIdentity(vendor: stick.vendor, product: stick.product, readable: false)
        let routes = USBRoutes(defaultRoute: vm1, rules: [.init(match: stick.serialMatch!, destination: vm2)])
        #expect(routes.decision(for: unread, among: [unread]) == .hold(.unreadable))
        let other = USBDeviceIdentity(vendor: 1, product: 2, readable: false)
        #expect(routes.decision(for: other, among: [other]) == .send(vm1, by: .defaultRoute))
    }

    @Test func noSerialIsNotUnreadable() {
        let yubikey = USBDeviceIdentity(vendor: 0x1050, product: 0x0402, locationID: 7)
        let routes = USBRoutes(rules: [.init(match: yubikey.portMatch!, destination: vm2)])
        #expect(routes.decision(for: yubikey, among: [yubikey]) == .send(vm2, by: .port))
    }

    @Test func descriptorIDs() {
        var d = [UInt8](repeating: 0, count: 18)
        d[8] = 0x64; d[9] = 0x85; d[10] = 0x00; d[11] = 0x10
        #expect(USBDeviceIdentity.ids(descriptor: d)! == (0x8564, 0x1000))
        #expect(USBDeviceIdentity.ids(descriptor: [1, 2]) == nil)
    }
}
