import Foundation
import Testing
@testable import LimaKit

@Suite struct SnapshotParsingTests {
    @Test func parsesQemuImgTable() {
        let text = """
        ID      TAG               VM_SIZE                DATE        VM_CLOCK     ICOUNT
        1       s1                    0 B 2026-10-10 14:58:15  0000:00:00.000          0
        2       before upgrade    1.2 GiB 2026-10-11 09:00:01  0001:02:03.456
        """
        let list = LimaSnapshot.parseList(text)
        #expect(list.map(\.tag) == ["s1", "before upgrade"])
        #expect(list[0].number == 1)
        #expect(list[0].vmSize == "0 B")
        #expect(list[1].vmSize == "1.2 GiB")
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: list[0].date!)
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2026, 10, 10, 14, 58, 15])
        #expect(LimaSnapshot.parseList("").isEmpty)
    }

    @Test func validatesTags() {
        #expect(LimaSnapshot.isValidTag("snap-20261010-153012"))
        #expect(LimaSnapshot.isValidTag("v1.2_ok"))
        #expect(!LimaSnapshot.isValidTag(""))
        #expect(!LimaSnapshot.isValidTag("-leading"))
        #expect(!LimaSnapshot.isValidTag("has space"))
        #expect(!LimaSnapshot.isValidTag(String(repeating: "a", count: 65)))
        #expect(LimaSnapshot.isValidTag(LimaSnapshot.suggestedTag()))
    }
}

@Suite struct AutostartPathTests {
    @Test func matchesLimaLaunchAgentName() {
        #expect(LimaClient.autostartPlist(for: "dev", home: "/Users/u").path
            == "/Users/u/Library/LaunchAgents/io.lima-vm.autostart.dev.plist")
    }
}

@Suite struct InstanceDecodingTests {
    @Test func decodesNDJSONList() throws {
        let url = try #require(Bundle.module.url(forResource: "list", withExtension: "ndjson", subdirectory: "Fixtures"))
        let instances = try LimaInstance.decodeList(Data(contentsOf: url))
        #expect(instances.map(\.name) == ["default", "dev", "weird"])

        let d = instances[0]
        #expect(d.status == .running)
        #expect(d.cpus == 4)
        #expect(d.memory == Int64(4) << 30)
        #expect(d.networks?.first?.kindDescription == "vzNAT")
        #expect(d.configURL.path == "/Users/u/.lima/default/lima.yaml")

        #expect(instances[1].status == .stopped)
        #expect(instances[1].networks?.first?.kindDescription == "lima:shared")
        #expect(instances[1].additionalDisks?.first?.name == "data")
        #expect(instances[2].status == .unknown("Paused"))
    }

    @Test func emptyListDecodesToEmptyArray() throws {
        #expect(try LimaInstance.decodeList(Data()).isEmpty)
        #expect(try LimaInstance.decodeList(Data("\n".utf8)).isEmpty)
    }
}

@Suite struct WatchEventTests {
    @Test func decodesRunningEvent() throws {
        let json = #"{"instance":"default","event":{"time":"2026-10-09T15:00:01.123456789+09:00","status":{"running":true,"sshLocalPort":60022}}}"#
        let ev = try JSONDecoder().decode(WatchEvent.self, from: Data(json.utf8))
        #expect(ev.instance == "default")
        #expect(ev.event.status.running == true)
        #expect(ev.event.time != nil)
        #expect(ev.affectsStatus)
        #expect(ev.summary == "running, ssh available on port 60022")
        #expect(ev.summary(previousSSHPort: 60022) == "running")
    }

    @Test func decodesPortForwardEvent() throws {
        let json = #"{"instance":"dev","event":{"time":"2026-10-09T06:00:01Z","status":{"portForward":{"type":"forwarding","protocol":"tcp","guestAddr":"0.0.0.0:80","hostAddr":"127.0.0.1:8080"}}}}"#
        let ev = try JSONDecoder().decode(WatchEvent.self, from: Data(json.utf8))
        #expect(!ev.affectsStatus)
        #expect(ev.summary == "forwarding tcp 0.0.0.0:80 to 127.0.0.1:8080")
    }
}

@Suite struct LogEntryTests {
    @Test func parsesJSONLog() {
        let e = LogEntry.parse(#"{"level":"fatal","msg":"failed to start","error":"boom","time":"2026-10-09T15:00:00+09:00"}"#)
        #expect(e.level == .fatal)
        #expect(e.displayText == "failed to start: boom")
    }

    @Test func parsesLogfmt() {
        let e = LogEntry.parse(#"time="2026-10-09T14:57:27+09:00" level=warning msg="No instance found. Run `limactl create`.""#)
        #expect(e.level == .warning)
        #expect(e.message == "No instance found. Run `limactl create`.")
    }

    @Test func plainLineIsInfo() {
        #expect(LogEntry.parse("hello").message == "hello")
    }

    @Test func summarizePrefersErrors() {
        let stderr = """
        {"level":"info","msg":"starting"}
        {"level":"error","msg":"bad thing"}
        {"level":"info","msg":"cleanup"}
        """
        #expect(LogEntry.summarize(stderr: stderr) == "bad thing")
    }
}

@Suite struct CreateOptionsTests {
    @Test func buildsArguments() {
        let o = CreateOptions(name: "web", template: "ubuntu-24.04", cpus: 2, memoryGiB: 4, diskGiB: 30.5,
                              vmType: .vz, networks: ["vzNAT"], rosetta: true)
        #expect(o.arguments == ["create", "--name=web", "--cpus=2", "--memory=4", "--disk=30.5",
                                "--vm-type=vz", "--network=vzNAT", "--rosetta", "template:ubuntu-24.04"])
    }

    @Test(arguments: [("default", true), ("my-vm.1", true), ("a_b", true), ("-x", false),
                      ("a--b", false), ("a b", false), ("", false), ("vm.yaml", false)])
    func validatesNames(name: String, valid: Bool) {
        #expect(CreateOptions.isValidName(name) == valid)
    }
}

@Suite struct LineSplitterTests {
    @Test func splitsOnNewlinesAndCarriageReturns() {
        var s = LineSplitter()
        #expect(s.feed(Data("a\nb".utf8)) == ["a"])
        #expect(s.feed(Data("c\r\nd\r".utf8)) == ["bc", "d"])
        #expect(s.flush() == nil)
        _ = s.feed(Data("tail".utf8))
        #expect(s.flush() == "tail")
    }
}

@Suite struct ProcessRunnerTests {
    let runner = ProcessRunner(executableURL: URL(fileURLWithPath: "/bin/sh"), environment: [:])

    @Test func collectsOutput() async throws {
        let out = try await runner.run(["-c", "echo hi; echo err >&2"])
        #expect(out.stdoutString == "hi\n")
        #expect(out.stderr == "err\n")
    }

    @Test func throwsOnFailure() async {
        await #expect(throws: CommandError.self) {
            try await runner.run(["-c", "echo nope >&2; exit 3"])
        }
    }

    @Test func streamsLines() async throws {
        var lines: [OutputLine] = []
        for try await l in runner.lines(["-c", "echo one; echo two >&2; echo three"]) { lines.append(l) }
        #expect(lines.filter { if case .stdout = $0 { true } else { false } }.map(\.text) == ["one", "three"])
        #expect(lines.contains(.stderr("two")))
    }

    @Test func cancellationTerminatesProcess() async throws {
        let start = Date()
        let task = Task {
            for try await _ in runner.lines(["-c", "echo start; sleep 30"]) { }
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

@Suite struct LimactlIntegrationTests {
    @Test(.enabled(if: LimaClient.locate() != nil))
    func versionAndList() async throws {
        let client = LimaClient(limactlURL: try #require(LimaClient.locate()))
        let version = try await client.version()
        #expect(version.first?.isNumber == true)
        _ = try await client.list()
        let templates = try await client.templates()
        #expect(templates.contains { $0.name == "default" })
        #expect(!templates.contains { $0.name.hasPrefix("_") })
        // "default" and "ubuntu-lts" follow a versioned Ubuntu image.
        #expect(templates.first { $0.name == "ubuntu-lts" }?.resolvedImage?.hasPrefix("ubuntu-") == true)
    }
}

@Suite struct DownloadMonitorTests {
    @Test func cacheKeyMatchesLima() {
        // Directory observed in ~/Library/Caches/lima for this URL.
        let dir = DownloadMonitor.cacheDirectory(
            for: "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/nocloud_alpine-3.23.4-aarch64-uefi-cloudinit-r0.qcow2",
            cacheRoot: URL(fileURLWithPath: "/c"))
        #expect(dir.path == "/c/download/by-url-sha256/42202cb6b33d8ac4848f98393823bd01d6fc452156ec695b5aa87fe45001deef")
    }

    @Test func picksNewestTempFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = "https://example.com/img.qcow2"
        let dir = DownloadMonitor.cacheDirectory(for: remote, cacheRoot: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appending(path: "data.tmp.1.1")
        let new = dir.appending(path: "data.tmp.2.1")
        try Data(count: 10).write(to: old)
        try Data(count: 42).write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: old.path)
        #expect(DownloadMonitor.partialSize(for: remote, cacheRoot: root) == 42)
        #expect(DownloadMonitor.partialSize(for: "https://other", cacheRoot: root) == nil)
    }
}

@Suite struct BackgroundProcessTests {
    @Test func terminateBackgroundProcessesEndsStream() async throws {
        let runner = ProcessRunner(executableURL: URL(fileURLWithPath: "/bin/sh"), environment: [:])
        let start = Date()
        let task = Task {
            for try await _ in runner.lines(["-c", "echo up; sleep 30"], background: true) {}
        }
        try await Task.sleep(for: .milliseconds(300))
        ProcessRunner.terminateBackgroundProcesses()
        _ = await task.result
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

@Suite struct ExitStatusTests {
    @Test(arguments: [(Int32(0), Int32(0)), (65280, 255), (256, 1), (15, 143), (9, 137)])
    func decodesWaitStatus(raw: Int32, code: Int32) {
        #expect(ExitStatus.decode(waitStatus: raw) == code)
    }
}

@Suite struct CreateOptionsSetTests {
    @Test func appendsSetExpressionsBeforeTemplate() {
        let o = CreateOptions(name: "vm", template: "alpine", setExpressions: [#".networks += [{"socket":"/s"}]"#])
        #expect(o.arguments == ["create", "--name=vm", "--set", #".networks += [{"socket":"/s"}]"#, "template:alpine"])
    }
}

@Suite struct LogFileFollowerTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "hanalima-follow-\(UUID().uuidString).log")
    }

    @Test func returnsOnlyNewCompleteLines() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let f = LogFileFollower(url: url)
        #expect(f.readNewLines() == nil)

        try Data("one\ntwo\npart".utf8).write(to: url)
        #expect(f.readNewLines() == .init(reset: true, lines: ["one", "two"]))
        #expect(f.readNewLines() == .init(reset: false, lines: []))

        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("ial\r\nthree\n".utf8))
        try h.close()
        #expect(f.readNewLines() == .init(reset: false, lines: ["partial", "three"]))

        // Lima recreates the file on the next start.
        try FileManager.default.removeItem(at: url)
        try Data("fresh\n".utf8).write(to: url)
        #expect(f.readNewLines() == .init(reset: true, lines: ["fresh"]))
    }

    @Test func startsNearTheEndOfLargeFiles() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((1...1000).map { "line \($0)\n" }.joined().utf8).write(to: url)
        let chunk = try #require(LogFileFollower(url: url, initialBytes: 40).readNewLines())
        // The cut-off first line is skipped; only whole lines from the tail remain.
        #expect(chunk.reset)
        #expect(chunk.lines.last == "line 1000")
        #expect(chunk.lines.allSatisfy { $0.hasPrefix("line ") })
        #expect(chunk.lines.count < 6)
    }

    @Test func stripsANSI() {
        #expect(LogFileFollower.stripANSI("\u{1B}[1;32mOK\u{1B}[0m done\u{1B}[?25h") == "OK done")
        #expect(LogFileFollower.stripANSI("\u{1B}[=3h\u{1B}[=3hBdsDxe") == "BdsDxe")
    }
}

@Suite struct DownloadProgressTests {
    @Test func percentAndTimeLeft() {
        let url = URL(string: "https://example.com/os.img")!
        var p = DownloadProgress(remote: url, received: 450, total: 1000, bytesPerSecond: 50)
        #expect(p.percent == 45)
        #expect(p.secondsRemaining == 11)
        p.received = 999
        #expect(p.percent == 99)  // never 100 until limactl moves on
        p.total = nil
        #expect(p.percent == nil)
        #expect(p.secondsRemaining == nil)
    }

    @Test func speedOverSlidingWindow() {
        var meter = SpeedMeter(window: 8)
        #expect(meter.add(time: 0, bytes: 0) == nil)
        #expect(meter.add(time: 1, bytes: 100) == nil)  // under 2 s of samples
        #expect(meter.add(time: 2, bytes: 200) == 100)
        #expect(meter.add(time: 10, bytes: 1000) == 100)  // the 0 s sample has left the window
        #expect(meter.add(time: 11, bytes: 50) == nil)  // a new temp file: start over
    }

    @Test func contentRangeTotal() {
        #expect(DownloadMonitor.totalLength(fromContentRange: "bytes 0-0/945530880") == 945530880)
        #expect(DownloadMonitor.totalLength(fromContentRange: "bytes 0-0/*") == nil)
    }
}

@Suite struct DownloadMonitorFileTests {
    @Test func ignoresStaleTempFilesAndEndsWhenRenamed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hanalima-dl-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = "https://example.com/os.img"
        let dir = DownloadMonitor.cacheDirectory(for: remote, cacheRoot: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = dir.appending(path: "data.tmp.111.1")
        try Data(count: 10).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: stale.path)
        let now = Date(timeIntervalSinceNow: -5)
        #expect(DownloadMonitor.partialSize(for: remote, since: now, cacheRoot: root) == nil)
        try Data(count: 20).write(to: dir.appending(path: "data.tmp.222.1"))
        #expect(DownloadMonitor.partialSize(for: remote, since: now, cacheRoot: root) == 20)
        try FileManager.default.moveItem(at: dir.appending(path: "data.tmp.222.1"), to: dir.appending(path: "data"))
        #expect(DownloadMonitor.partialSize(for: remote, since: now, cacheRoot: root) == nil)
    }
}
