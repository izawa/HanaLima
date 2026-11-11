import Foundation
import Darwin

/// Darwin socket paths include the temporary directory, so use a short, isolated prefix.
final class TestDirectory {
    let url: URL
    var socket: String { url.appendingPathComponent("s.sock").path }

    init() throws {
        url = URL(fileURLWithPath: "/tmp/hlmcp-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
