import Foundation
import Testing
@testable import LimaKit

struct InstanceRenameTests {
    private func instance(name: String = "vm", dir: URL, protected: Bool? = nil, os: String = "Linux",
                          networks: [NetworkAttachment] = []) -> LimaInstance {
        var inst = try! JSONDecoder().decode(LimaInstance.self, from: Data("""
            {"name": "\(name)", "status": "Stopped", "dir": "\(dir.path)"}
            """.utf8))
        inst.protected = protected
        inst.config = .object(["os": .string(os)])
        inst.networks = networks
        return inst
    }

    private func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "rename-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home.appending(path: "vm"), withIntermediateDirectories: true)
        try "networks: []\n".write(to: home.appending(path: "vm/lima.yaml"), atomically: true, encoding: .utf8)
        return home
    }

    @Test func writesOnlyTheMACsLimaMadeUp() throws {
        let raw: [JSONValue] = [
            .object(["socket": .string("/net/a.sock")]),
            .object(["vzNAT": .bool(true), "macAddress": .string("52:55:55:00:00:02")]),
            .object(["lima": .string("user-v2")]),
        ]
        let used = [
            NetworkAttachment(socket: "/net/a.sock", macAddress: "52:55:55:00:00:01"),
            NetworkAttachment(vzNAT: true, macAddress: "52:55:55:00:00:02"),
            NetworkAttachment(lima: "user-v2", macAddress: "52:55:55:00:00:03"),
        ]
        #expect(InstanceRename.pinExpressions(raw: raw, effective: used) == [
            #".networks[0].macAddress = "52:55:55:00:00:01""#,
            #".networks[2].macAddress = "52:55:55:00:00:03""#,
        ])
    }

    @Test func refusesNetworksThatDontLineUp() {
        let used = [NetworkAttachment(socket: "/net/a.sock", macAddress: "52:55:55:00:00:01")]
        #expect(InstanceRename.pinExpressions(raw: [], effective: used) == nil)  // from a base template
        #expect(InstanceRename.pinExpressions(raw: [.object(["socket": .string("/net/b.sock")])], effective: used) == nil)
        #expect(InstanceRename.pinExpressions(raw: [], effective: []) == [])
    }

    @Test func checksTheNewName() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: "taken"), withIntermediateDirectories: true)
        let inst = instance(dir: home.appending(path: "vm", directoryHint: .isDirectory))
        #expect(InstanceRename.nameProblem("ok-name", for: inst) == nil)
        #expect(InstanceRename.nameProblem("bad name", for: inst) == .invalid)
        #expect(InstanceRename.nameProblem("VM", for: inst) == .caseOnly)
        #expect(InstanceRename.nameProblem("vm", for: inst) == .taken("vm"))
        #expect(InstanceRename.nameProblem("Taken", for: inst) == .taken("Taken"))  // case-insensitive volume
        #expect(InstanceRename.nameProblem(String(repeating: "a", count: 76), for: inst) == .tooLong)
    }

    @Test func refusesWhatLimaWouldBreak() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appending(path: "vm", directoryHint: .isDirectory)
        #expect(InstanceRename.blocker(of: instance(dir: dir)) == nil)
        #expect(InstanceRename.blocker(of: instance(dir: dir, protected: true)) == .protected)
        #expect(InstanceRename.blocker(of: instance(dir: dir, os: "Darwin")) == .macOSGuest)
        #expect(InstanceRename.blocker(of: instance(dir: dir, networks: [NetworkAttachment(vzNAT: true, macAddress: "52:55:55:00:00:01")]))
                == .networksOutsideConfig)
        for url in [SavedState.stateURL(instanceDir: dir), SavedState.recordURL(instanceDir: dir)] { try Data().write(to: url) }
        #expect(InstanceRename.blocker(of: instance(dir: dir)) == .hibernated)
        for url in [SavedState.stateURL(instanceDir: dir), SavedState.recordURL(instanceDir: dir)] { try FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: dir.appending(path: "tpm"), withIntermediateDirectories: true)
        #expect(InstanceRename.blocker(of: instance(dir: dir)) == .subfolder("tpm"))
    }
}
