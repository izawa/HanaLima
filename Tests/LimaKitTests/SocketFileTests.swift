import Darwin
import Foundation
import Testing
@testable import LimaKit

/// A socket file is removed only while the path still leads to the one this process claimed.
@Suite struct SocketFileTests {
    /// Binds a unix socket at `path` and returns its descriptor.
    private func bindSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0, "bind \(path)")
        return fd
    }

    private func scratch() -> String {
        // Short: a socket path is limited to 104 bytes.
        "/tmp/hl-sf-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    }

    @Test func removesTheSocketItClaimed() throws {
        let path = scratch()
        let fd = try bindSocket(path)
        defer { close(fd) }
        let file = SocketFile(path: path)
        file.claim()
        file.remove()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func leavesASocketAnotherProcessBoundAtThePath() throws {
        let path = scratch()
        let first = try bindSocket(path)
        defer { close(first) }
        let file = SocketFile(path: path)
        file.claim()
        // The next driver takes the path over: unlinks the old file and binds its own.
        unlink(path)
        let second = try bindSocket(path)
        defer { close(second); unlink(path) }
        file.remove()
        #expect(FileManager.default.fileExists(atPath: path), "the later socket stays")
    }

    @Test func removesNothingUnclaimedOrNotASocket() throws {
        let path = scratch()
        let fd = try bindSocket(path)
        defer { close(fd); unlink(path) }
        SocketFile(path: path).remove()
        #expect(FileManager.default.fileExists(atPath: path), "never claimed")

        let plain = scratch()
        FileManager.default.createFile(atPath: plain, contents: Data())
        defer { unlink(plain) }
        let file = SocketFile(path: plain)
        file.claim()
        file.remove()
        #expect(FileManager.default.fileExists(atPath: plain), "not a socket")
    }
}
