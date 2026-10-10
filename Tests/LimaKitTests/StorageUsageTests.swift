import Foundation
import Testing
@testable import LimaKit

@Suite struct StorageUsageTests {
    @Test func measuresLimaHomeAndCache() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hanalima-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "lima")
        let cache = root.appending(path: "cache")
        func write(_ url: URL, bytes: Int) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }
        try write(home.appending(path: "vm1/disk"), bytes: 300_000)
        try write(home.appending(path: "_config/user"), bytes: 10)
        try write(home.appending(path: "stray-file"), bytes: 10)  // not a directory: ignored
        let entry = cache.appending(path: "download/by-url-sha256/abc")
        try write(entry.appending(path: "data"), bytes: 200_000)
        try write(entry.appending(path: "imgconv/raw"), bytes: 100_000)
        try "https://example.com/images/os-1.0-arm64.img\n".write(to: entry.appending(path: "url"), atomically: true, encoding: .utf8)
        try write(cache.appending(path: "download/by-url-sha256/no-url/data"), bytes: 10)  // incomplete: ignored

        let report = StorageReport.measure(limaHome: home, cacheRoot: cache)
        #expect(report.limaItems.map(\.name) == ["vm1", "_config"])
        #expect(report.limaItems[0].size >= 300_000)
        #expect(report.downloads.count == 1)
        #expect(report.downloads[0].fileName == "os-1.0-arm64.img")
        #expect(report.downloads[0].size >= 300_000)  // data plus the converted copy
        #expect(report.cacheTotal == report.downloads[0].size)
    }
}
