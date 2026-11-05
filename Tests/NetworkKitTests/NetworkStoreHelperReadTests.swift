import Foundation
import Testing
@testable import NetworkKit

/// `networks.json` as the helper reads it: only its own entry, so an entry of a kind this build
/// doesn't know (written by a newer app) can't take every helper down.
@Suite struct NetworkStoreHelperReadTests {
    private func file(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "networks-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func readsItsOwnEntryNextToAnUnknownKind() throws {
        let url = try file("""
        {"version": 1, "networks": [
          {"name": "demo", "mode": "shared", "gateway": "192.168.200.1", "prefixLength": 24},
          {"name": "future", "mode": "wormhole", "gateway": "10.9.8.1", "prefixLength": 24, "extra": true}
        ]}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let demo = try #require(try NetworkStore.network(named: "demo", in: url))
        #expect(demo.mode == .shared && demo.gateway == "192.168.200.1")
        #expect(try NetworkStore.network(named: "absent", in: url) == nil)
        // The unknown one fails on its own, with a message that names it.
        #expect(throws: (any Error).self) { try NetworkStore.network(named: "future", in: url) }
        do { _ = try NetworkStore.network(named: "future", in: url) } catch {
            #expect(error.localizedDescription.contains("future") && error.localizedDescription.contains("wormhole"))
        }
        // The app's full load still refuses the file as a whole.
        #expect(throws: (any Error).self) { try NetworkStore.load(from: url) }
    }

    @Test func missingFileAndMalformedFile() throws {
        #expect(try NetworkStore.network(named: "x", in: URL(filePath: "/nonexistent/networks.json")) == nil)
        let url = try file("{\"version\": 1}")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try NetworkStore.network(named: "x", in: url) }
    }
}
