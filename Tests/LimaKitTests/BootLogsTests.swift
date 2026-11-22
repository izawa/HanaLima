import Foundation
import Testing
@testable import LimaKit

struct BootLogsTests {
    private func folder(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bootlogs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: dir.appending(path: name), atomically: true, encoding: .utf8) }
        return dir
    }

    @Test func picksWarningsEventsAndTheConsole() throws {
        let dir = try folder([
            "ha.stderr.log": """
            {"level":"info","msg":"Starting the instance","time":"2026-11-22T10:00:00+09:00"}
            {"level":"warning","msg":"Waiting for SSH","time":"2026-11-22T10:00:01+09:00"}
            {"level":"fatal","msg":"did not receive an event","error":"timeout","time":"2026-11-22T10:10:00+09:00"}
            """,
            "ha.stdout.log": """
            {"time":"2026-11-22T10:00:02+09:00","status":{"requirementProgress":{"step":1,"total":5,"description":"ssh","done":false}}}
            {"time":"2026-11-22T10:00:03+09:00","status":{"cloudInitProgress":{"logLine":"Cloud-init v. 24 running"}}}
            {"time":"2026-11-22T10:10:00+09:00","status":{"errors":["boot failed"],"exiting":true}}
            """,
            "serialv.log": "\u{1B}[0;32m[  OK  ]\u{1B}[0m Started\tsshd\n\nsshd: no hostkeys available\n",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = BootLogs.excerpt(instanceDir: dir, vmType: "hanalima")
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains("  [warning] Waiting for SSH"))
        #expect(lines.contains("  [fatal] did not receive an event: timeout"))
        #expect(!text.contains("Starting the instance"))  // info is left out
        #expect(lines.contains("  cloud-init: Cloud-init v. 24 running"))
        #expect(lines.contains("  error: boot failed"))
        #expect(lines.contains("  requirement 1/5: ssh"))
        #expect(lines.contains { $0.hasPrefix("== serialv.log (modified ") })
        #expect(lines.contains("  [  OK  ] Started sshd"))  // ANSI gone, the tab a space
        #expect(lines.contains("  sshd: no hostkeys available"))
    }

    @Test func missingFilesAndLinksAreSaidNotRead() throws {
        let dir = try folder(["elsewhere": "secret\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "ha.stderr.log"), withDestinationURL: dir.appending(path: "elsewhere"))
        let text = BootLogs.excerpt(instanceDir: dir, vmType: "qemu")
        #expect(text.contains("== ha.stderr.log: missing"))
        #expect(text.contains("== ha.stdout.log: missing"))
        #expect(text.contains("== serial.log: missing"))  // QEMU's first console
        #expect(!text.contains("secret"))
    }

    @Test func aConsoleWithOnlyEscapesIsPassedOver() throws {
        let dir = try folder(["serialv.log": "\u{1B}[2J\u{1B}[H\n   \n", "serial.log": "Kernel panic - not syncing\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = BootLogs.excerpt(instanceDir: dir, vmType: "vz")
        #expect(text.contains("== serial.log (modified ") && text.contains("  Kernel panic - not syncing"))
    }

    @Test func theWindowKeepsAWholeFirstLine() throws {
        // 64-byte lines: the window starts right after a newline, so its first line is whole.
        let text = (1...1000).map { String(format: "L%04d", $0) + String(repeating: "z", count: 58) }.joined(separator: "\n") + "\n"
        let dir = try folder(["ha.stderr.log": text, "cut.log": text + String(repeating: "w", count: 31) + "\n",
                              "one.log": String(repeating: "q", count: 40_000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let whole = try #require(BootLogs.tail(dir.appending(path: "ha.stderr.log"))?.lines)
        #expect(whole.count == BootLogs.fileBytes / 64)
        #expect(whole.first?.hasPrefix("L0489") == true)
        // 32 more bytes at the end move the window to mid-line: the cut piece of line 489 is left out.
        let cut = try #require(BootLogs.tail(dir.appending(path: "cut.log"))?.lines)
        #expect(cut.first?.hasPrefix("L0490") == true)
        // A window inside one long line holds no whole line.
        #expect(BootLogs.tail(dir.appending(path: "one.log"))?.lines == [])
    }

    @Test func boundsEachLineAndEachSource() throws {
        let long = String(repeating: "x", count: 2_000)
        let many = (1...200).map { "line \($0) " + String(repeating: "y", count: 60) }.joined(separator: "\n")
        let dir = try folder(["serialv.log": long + "\n" + many + "\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BootLogs.flatten(long).utf8.count <= BootLogs.lineBytes)
        let console = BootLogs.excerpt(instanceDir: dir, vmType: nil).split(separator: "\n").drop { !$0.hasPrefix("== serialv.log") }
        #expect(console.dropFirst().joined(separator: "\n").utf8.count <= BootLogs.sourceBytes)
        #expect(console.last.map(String.init) == "  line 200 " + String(repeating: "y", count: 60))  // the newest kept
    }
}
