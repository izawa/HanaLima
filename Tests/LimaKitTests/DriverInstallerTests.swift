import Foundation
import Testing
@testable import LimaKit

@Suite struct DriverInstallerTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "driverinstaller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func linksAndReplacesAnOldCopy() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appending(path: "HanaLimaDriver.app/Contents/MacOS/lima-driver-hanalima")
        try FileManager.default.createDirectory(at: driver.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("driver".utf8).write(to: driver)
        let dir = root.appending(path: "lib/lima")
        let dest = dir.appending(path: DriverInstaller.driverName)
        // What earlier versions placed: a plain copy.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("old copy".utf8).write(to: dest)

        #expect(try DriverInstaller.link(driver, in: dir) == .installed(dest))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dest.path) == driver.path)
        #expect(try DriverInstaller.link(driver, in: dir) == .upToDate(dest))
        // The app moved: the link follows the next launch.
        let moved = root.appending(path: "elsewhere/lima-driver-hanalima")
        #expect(try DriverInstaller.link(moved, in: dir) == .installed(dest))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dest.path) == moved.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [DriverInstaller.driverName])
    }

    @Test func onlyAnAppInAnApplicationsFolderPlacesIt() {
        #expect(DriverInstaller.isInApplications(URL(filePath: "/Applications/HanaLima.app/Contents/Helpers/HanaLimaDriver.app/Contents/MacOS/lima-driver-hanalima")))
        #expect(DriverInstaller.isInApplications(URL(filePath: NSHomeDirectory() + "/Applications/HanaLima.app/x")))
        #expect(!DriverInstaller.isInApplications(URL(filePath: "/Volumes/HanaLima 0.19.0/HanaLima.app/x")))
        #expect(!DriverInstaller.isInApplications(URL(filePath: "/private/var/folders/xy/T/AppTranslocation/ABC/d/HanaLima.app/x")))
        #expect(!DriverInstaller.isInApplications(URL(filePath: "/Users/someone/src/HanaLima/build/HanaLima.app/x")))
    }

    @Test func placedMeansAnExecutableInLibLima() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let limactl = root.appending(path: "bin/limactl")
        #expect(!DriverInstaller.isPlaced(limactl: limactl))
        // A copy left by an earlier version doesn't count.
        let lib = root.appending(path: "lib/lima")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: lib.appending(path: DriverInstaller.driverName))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lib.appending(path: DriverInstaller.driverName).path)
        #expect(!DriverInstaller.isPlaced(limactl: limactl))
        let driver = root.appending(path: "driver")
        try Data("#!/bin/sh\n".utf8).write(to: driver)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driver.path)
        _ = try DriverInstaller.link(driver, in: root.appending(path: "lib/lima"))
        #expect(DriverInstaller.isPlaced(limactl: limactl))
    }
}
