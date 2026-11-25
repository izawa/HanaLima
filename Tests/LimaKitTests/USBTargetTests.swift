import Foundation
import Testing
@testable import LimaKit

@Suite struct USBTargetTests {
    private func instance(_ root: URL, _ name: String, identifier: String?) throws -> URL {
        let dir = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let identifier { try Data(identifier.utf8).write(to: dir.appending(path: "vz-identifier")) }
        return dir
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "usbtarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func noTargetBeforeTheFirstStart() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(USBTarget(instanceDir: try instance(root, "new", identifier: nil)) == nil)
    }

    @Test func matchesOnlyTheSameFolderAndIdentity() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try instance(root, "vm", identifier: "A")
        let target = try #require(USBTarget(instanceDir: vm))
        #expect(target.matches(instanceDir: vm))
        // A clone: another folder, another identifier.
        #expect(!target.matches(instanceDir: try instance(root, "copy", identifier: "B")))
        // Made again under the same name: same folder, new identifier.
        try Data("C".utf8).write(to: vm.appending(path: "vz-identifier"))
        #expect(!target.matches(instanceDir: vm))
    }

    @Test func aSymlinkedFolderIsTheSameVM() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try instance(root, "vm", identifier: "A")
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: vm)
        let target = try #require(USBTarget(instanceDir: vm))
        #expect(target.matches(instanceDir: link))
    }

    @Test func savesLoadsAndClears() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "support/\(USBTarget.fileName)")
        #expect(USBTarget.load(from: file) == nil)
        let target = USBTarget(instanceDir: "/x", machineIdentifier: "QQ==")
        try USBTarget.save(target, to: file)
        #expect(USBTarget.load(from: file) == target)
        try USBTarget.save(nil, to: file)
        #expect(USBTarget.load(from: file) == nil)
        try USBTarget.save(nil, to: file)  // clearing twice is fine
    }

    @Test func anUnsignedFileHasNoEntitlement() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "plain")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        #expect(!USBTarget.isEntitled(executable: file))
    }
}
