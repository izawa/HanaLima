import Foundation
import NetworkKit
import Testing
@testable import LimaKit

/// HanaLima's VM driver for Lima (Driver/, docs/09): a VM created with `--vm-type=hanalima`
/// boots under Lima through `lima-driver-hanalima` (VZ in the driver's process, NIC 0 on
/// `limactl usernet`), answers over SSH with DNS, the virtiofs share, the guest agent over
/// vsock and port forwarding, has its HanaLima-network NIC, vzNAT NIC and additional disk,
/// and stops without leaving processes, pid files or disk locks behind.
///
/// Needs `scripts/build-app.sh` first (the signed driver is in the app bundle).
/// `HANALIMA_E2E_TEMPLATE` picks the guest (default alpine). A few minutes.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DriverEndToEndTests {
    let vm = "hanalima-e2e-driver"
    static let template = ProcessInfo.processInfo.environment["HANALIMA_E2E_TEMPLATE"] ?? "alpine"
    static let helpers = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/Helpers")
    /// limactl with the bundle's driver on its path.
    let client = LimaClient(limactlURL: LimaClient.locate()!,
                            environment: ProcessInfo.processInfo.environment.merging(["LIMA_DRIVERS_PATH": helpers.path]) { $1 })

    let disk = "hanalima-e2e-driver-disk"
    let network = VirtualNetwork(name: "e2e-driver", mode: .shared, gateway: "192.168.237.1", prefixLength: 24)

    @Test(.timeLimit(.minutes(15)))
    func bootsUnderLimaWithTheDriver() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "lima-driver-hanalima").path),
                     "run scripts/build-app.sh first")
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm], environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }

        // A HanaLima network (netd) for a `socket:` NIC, and a raw additional disk (the driver
        // attaches raw only; Lima's vz converts qcow2 in place, this driver doesn't).
        _ = try HelperInstaller.installIfNeeded(from: Self.helpers.appending(path: "hanalima-netd"))
        let agents = LaunchAgentManager()
        var saved = try NetworkStore.load().filter { $0.name != network.name }
        let original = saved
        saved.append(network)
        try NetworkStore.save(saved)
        defer {
            agents.uninstall(network.name)
            try? NetworkStore.save(original)
        }
        try agents.install(network)
        _ = try? await drain(client.deleteDisk(disk))
        _ = try await drain(client.createDisk(disk, size: "1GiB", format: "raw"))
        defer { E2ECleanup.deleteDisks([disk]) }

        // Create must succeed before anything else: `limactl start <missing name>` would make a
        // VM from the default template instead.
        // With the console-login example: the images put no getty (and no kernel console) on
        // hvc0, so the serial console is silent without it.
        let autologin = ProvisionExamples.consoleLogin.entries.map(\.json)
        _ = try await drain(client.create(CreateOptions(
            name: vm, template: Self.template, cpus: 2, memoryGiB: 2, diskGiB: 10, vmType: .hanalima,
            setExpressions: [#".networks = [{"socket": "\#(network.socketPath)"}, {"vzNAT": true}]"#,
                             #".additionalDisks = [{"name": "\#(disk)"}]"#,
                             ".provision = \(JSONValue.array(autologin).jsonText)"])))
        let created = try #require(try await client.list().first { $0.name == vm })
        #expect(created.vmType == "hanalima")
        let dir = URL(filePath: created.dir, directoryHint: .isDirectory)

        let started = Date.now
        do {
            _ = try await drain(client.start(vm))
        } catch {
            for name in ["driver.stderr.log", "ha.stderr.log", "hanalima-usernet.log"] {
                let text = (try? String(contentsOf: dir.appending(path: name), encoding: .utf8)) ?? ""
                print("--- \(name)\n" + text.split(separator: "\n").suffix(12).joined(separator: "\n"))
            }
            throw error
        }
        print("driver: boot \(Int(Date.now.timeIntervalSince(started))) s")
        let running = try #require(try await client.list().first { $0.name == vm })
        #expect(running.status == .running)

        // The guest: DNS through usernet's gateway (resolv.conf on Alpine, systemd-resolved on
        // Ubuntu), the home share, the guest agent.
        #expect(try await sh("{ cat /etc/resolv.conf; resolvectl status 2>/dev/null; } | grep -q 192.168.5.2 && echo ok") == "ok")
        #expect(try await sh("nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1 && echo ok") == "ok")
        #expect(try await sh("mount | grep -c virtiofs") == "1")
        #expect(try await sh("ls \(NSHomeDirectory()) >/dev/null && echo ok") == "ok")
        #expect(try await sh("ps -o args= 2>/dev/null | grep '[l]ima-guestagent' | grep -c 'vsock-port 2222'") != "0")
        // NIC 1 on the HanaLima network, NIC 2 on vzNAT, the additional disk mounted by Lima.
        #expect(try await sh("ip -4 -o addr show lima0 | grep -c 192.168.237.") == "1")
        #expect(try await sh("ip -4 -o addr show lima1 | grep -c 192.168.64.") == "1")
        // Lima's 05-lima-disks.sh partitions, formats and mounts it at the first boot. On Alpine
        // the mount sometimes fails with "/dev/vdb1: Can't lookup blockdev" (the partition's
        // node isn't there yet right after sfdisk; a guest-side race, seen under this driver in
        // about 1 boot in 4). The disk itself is attached and formatted then, so mount it by
        // hand and prove that, rather than Lima's timing.
        var mounted = try await sh("mount | grep -c '/mnt/lima-\(disk)'")
        if mounted != "1" {
            print("--- disk not mounted by Lima's boot script:\n" +
                  (try await sh("sudo grep -n -B2 -A3 'lookup blockdev\\|mkfs\\|sfdisk' /var/log/cloud-init-output.log | tail -20; cat /proc/partitions; ls -l /dev/vdb*; cat /sys/class/block/vdb1/dev; sudo dmesg | grep -i 'vdb' | tail -5")))
            // mdev -s rebuilds /dev from /sys (a stale or missing node is the suspect).
            _ = try await sh("sudo mdev -s; sudo mkdir -p /mnt/lima-\(disk) && sudo mount /dev/vdb1 /mnt/lima-\(disk)")
            mounted = try await sh("mount | grep -c '/mnt/lima-\(disk)'")
        }
        #expect(mounted == "1")
        #expect(try await sh("grep -c ' vdb1$' /proc/partitions") == "1", "the additional disk is attached and partitioned")
        let lock = Self.limaHome.appending(path: "_disks/\(disk)/in_use_by")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: lock.path) == dir.path)
        // Port forwarding (the guest agent reports the port over the forwarded ga.sock).
        // python3 where it exists (Ubuntu's image has no nc), busybox nc on Alpine.
        _ = try await sh("""
            mkdir -p /tmp/www && echo hanalima > /tmp/www/index.html
            if command -v python3 >/dev/null; then nohup python3 -m http.server 18080 -d /tmp/www >/dev/null 2>&1 &
            else nohup sh -c "while true; do printf 'HTTP/1.0 200 OK\\r\\n\\r\\nhanalima' | nc -l -p 18080; done" >/dev/null 2>&1 & fi
            """)
        let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 3; return c }())
        var forwarded = ""
        for _ in 0..<20 {
            try await Task.sleep(for: .seconds(1))
            if let data = try? await session.data(from: URL(string: "http://127.0.0.1:18080/")!).0,
               let text = String(data: data, encoding: .utf8) { forwarded = text; break }
        }
        #expect(forwarded.contains("hanalima"))

        // SSH route (stage 4): a guest with systemd 256+ (Ubuntu LTS) gets sshd on vsock port 22
        // and the driver proxies 127.0.0.1:<port> to it, leaving usernet with no forward; a guest
        // without it (Alpine) falls back to the usernet forward.
        let driverLog = (try? String(contentsOf: dir.appending(path: "driver.stderr.log"), encoding: .utf8)) ?? ""
        let vsockSSH = try await sh("ss --vsock 2>/dev/null | grep -c ':22 '")
        if try await sh("command -v systemctl >/dev/null && systemctl is-active sshd-vsock.socket") == "active" {
            #expect(driverLog.contains("ssh over vsock"), "the driver chose vsock for SSH")
            #expect(vsockSSH != "0", "the shell above came in over vsock")
            // usernet may have answered first on the first boot (both routes come up after
            // cloud-init); the driver then switches to vsock, so the forward is gone either way.
            let forwards = try await Task.detached { try UsernetClient.forwards(socketPath: dir.appending(path: "default_ep.sock").path) }.value
            #expect(forwards == "[]", "usernet keeps no SSH forward once vsock is in use: \(forwards)")
        } else {
            #expect(driverLog.contains("over usernet"), "no sshd on vsock: SSH stays on usernet")
        }

        // HanaLima's side channel (DriverControl): the state, and that this headless VM has no screen.
        let status = try await Task.detached { try DriverControl.send(DriverControl.Request(op: .status), instanceDir: dir) }.value
        #expect(status.state == "running")
        #expect(status.display == false)
        #expect(throws: DriverControl.Failure.self) {
            try DriverControl.send(DriverControl.Request(op: .openScreen), instanceDir: dir)
        }
        // The serial console both ways: the example's agetty has logged the user in on hvc0, so
        // a command typed on the socket runs there, and its output lands on the socket and in
        // serialv.log (the shell may still be starting right after the first boot).
        let serialLog = dir.appending(path: "serialv.log")
        let marker = "hanalima-serial-\(Int.random(in: 1000...9999))"
        var answer = ""
        for _ in 0..<12 {
            let got = try await Task.detached {
                try serialExchange(socketPath: dir.appending(path: DriverControl.serialSocketName).path, send: "\recho \(marker)\r", until: marker, times: 2)
            }.value
            answer = String(decoding: got, as: UTF8.self)
            if answer.components(separatedBy: marker).count >= 3 { break }  // the echoed line, then the output
            try await Task.sleep(for: .seconds(3))
        }
        #expect(answer.components(separatedBy: marker).count >= 3, "the shell on hvc0 ran the command: \(answer.suffix(200))")
        #expect(String(decoding: (try? Data(contentsOf: serialLog)) ?? Data(), as: UTF8.self).contains(marker), "serialv.log has the console too")

        let stopping = Date.now
        _ = try await drain(client.stop(vm))
        print("driver: stop \(Int(Date.now.timeIntervalSince(stopping))) s")
        let stopped = try #require(try await client.list().first { $0.name == vm })
        #expect(stopped.status == .stopped)
        for name in ["hanalima.pid", "hanalima-usernet.pid", "hanalima.drv.sock", "default_ep.sock", "default_fd.sock",
                     DriverControl.socketName, DriverControl.serialSocketName] {
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: name).path), Comment(rawValue: name))
        }
        #expect(try await processes(matching: "lima-driver-hanalima --inst-dir \(dir.path)") == 0)
        #expect(try await processes(matching: "limactl usernet --endpoint \(dir.path)") == 0)
        #expect(!FileManager.default.fileExists(atPath: lock.path), "disk lock released")
    }

    static var limaHome: URL {
        URL(filePath: ProcessInfo.processInfo.environment["LIMA_HOME"] ?? NSHomeDirectory() + "/.lima", directoryHint: .isDirectory)
    }

    private func sh(_ script: String) async throws -> String {
        let out = try? await client.runner.run(["shell", vm, "sh", "-c", script])
        if out == nil {
            print("failed: \(script.prefix(80))")
            // The first failure usually means SSH itself is gone: keep the driver's view of it.
            if !Self.dumpedLogs, let inst = try? await client.list().first(where: { $0.name == vm }) {
                Self.dumpedLogs = true
                for name in ["driver.stderr.log", "ha.stderr.log"] {
                    let text = (try? String(contentsOf: inst.instanceDir.appending(path: name), encoding: .utf8)) ?? ""
                    print("--- \(name)\n" + text.split(separator: "\n").suffix(25).joined(separator: "\n"))
                }
            }
        }
        return (out?.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    nonisolated(unsafe) private static var dumpedLogs = false

    private func processes(matching pattern: String) async throws -> Int {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self).split(separator: "\n").count
    }
}

/// usernet's `/services/forwarder/all` (its HTTP API on the endpoint socket), as raw JSON.
enum UsernetClient {
    static func forwards(socketPath: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DriverControl.Failure("socket") }
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw DriverControl.Failure("connect: \(String(cString: strerror(errno)))") }
        let request = [UInt8]("GET /services/forwarder/all HTTP/1.0\r\nHost: lima\r\n\r\n".utf8)
        _ = request.withUnsafeBytes { send(fd, $0.baseAddress, request.count, 0) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 { received.append(contentsOf: buffer[0..<n]) } else { break }
        }
        let text = String(decoding: received, as: UTF8.self)
        return text.components(separatedBy: "\r\n\r\n").dropFirst().joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Sends `send` on the console socket and collects what comes back, until `until` has shown up
/// `times` times or a few seconds pass.
private func serialExchange(socketPath: String, send: String, until: String, times: Int) throws -> Data {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DriverControl.Failure("socket") }
    defer { close(fd) }
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw DriverControl.Failure("connect: \(String(cString: strerror(errno)))") }
    let payload = [UInt8](send.utf8)
    _ = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, payload.count, 0) }
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let started = Date.now
    while Date.now.timeIntervalSince(started) < 6 {
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if n > 0 { received.append(contentsOf: buffer[0..<n]) } else { break }
        if String(decoding: received, as: UTF8.self).components(separatedBy: until).count > times { break }
    }
    return received
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
