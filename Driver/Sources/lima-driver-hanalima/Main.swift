import AppKit
import Darwin
import Dispatch
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import LimaKit
import NIOCore
import NIOPosix

/// `lima-driver-hanalima --inst-dir <dir>`: serve Lima's Driver gRPC on `<dir>/hanalima.drv.sock`
/// until SIGTERM, and HanaLima's own requests on `<dir>/hanalima-ctl.sock`. `--inspect-status`:
/// echo the instance JSON Lima pipes in (the status is left to Lima's own pid-file checks, as
/// the vz driver does). `--smoke <dir>`: boot the instance in `<dir>` without Lima, wait for its
/// address on usernet, power it off (development aid).
///
/// `--hosted <dir> --cpus N --memory BYTES [--iso P] [--boot-image P] [--helper P] [--seed P]
/// [--no-cidata] [--headless] [--serial-log NAME]`: a boot outside Lima on the instance's own
/// files (the rescue boot, the installer; docs/07), with a window unless headless and the
/// control socket for HanaLima; exits when the guest stops.
///
/// The main thread runs AppKit (the VM's window lives in this process, see DisplayWindow);
/// the servers and the VM run on other threads and end the process with `exit`.
@main
struct LimaDriverHanaLima {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--inspect-status"] {
            do { try inspectStatus() } catch { log("error: \(error)"); exit(1) }
            return
        }
        // Headless until a window is shown (DisplayWindow switches the policy).
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task.detached {
            do {
                if args.count == 2, args[0] == "--inst-dir" {
                    try await serve(instanceDir: args[1])
                } else if args.first == "--hosted" {
                    try await hosted(Array(args.dropFirst()))
                } else if args.count == 2, args[0] == "--smoke" {
                    try await smoke(instanceDir: args[1])
                } else {
                    throw DriverError("usage: lima-driver-hanalima --inst-dir <dir> | --inspect-status | --smoke <dir>")
                }
                exit(0)
            } catch {
                log("error: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    /// Go encodes the instance as a []byte in JSON (base64 in a string); answer the same way.
    static func inspectStatus() throws {
        guard let line = readLine() else { throw DriverError("expected a JSON string on stdin") }
        let encoded = try JSONDecoder().decode(String.self, from: Data(line.utf8))
        guard let bytes = Data(base64Encoded: encoded) else { throw DriverError("stdin is not base64") }
        FileHandle.standardOutput.write(try JSONEncoder().encode(bytes.base64EncodedString()) + Data([10]))
    }

    static func serve(instanceDir: String) async throws {
        let path = URL(fileURLWithPath: instanceDir).appendingPathComponent("hanalima.drv.sock").path
        var st = stat()
        if lstat(path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK else { throw DriverError("refusing to remove a non-socket at \(path)") }
            unlink(path)
        }
        defer { unlink(path) }

        let core = DriverCore(instanceDir: URL(fileURLWithPath: instanceDir, isDirectory: true))
        let service = DriverService(core: core)
        var config = HTTP2ServerTransport.Posix.Config.defaults
        config.channelDebuggingCallbacks.onBindTCPListener = { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(AcceptErrorFilter())
            }
        }
        let server = GRPCServer(
            transport: .http2NIOPosix(address: .unixDomainSocket(path: path), transportSecurity: .plaintext, config: config),
            services: [service]
        )
        let control = try ControlServer(path: URL(fileURLWithPath: instanceDir).appendingPathComponent(DriverControl.socketName).path) {
            await core.control($0)
        }
        defer { control.close() }

        let (signals, continuation) = AsyncStream<Void>.makeStream()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { continuation.yield(()) }
            source.resume()
            return source
        }
        defer {
            for source in sources { source.cancel() }
            continuation.finish()
        }

        log("serving on \(path)")
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await server.serve() }
                // No "exit when the parent is gone": the process that spawns the driver is
                // `limactl start` itself (Prepare), and the host agent then reuses the running
                // server, so the parent exits while the VM must go on.
                group.addTask {
                    for await _ in signals {
                        log("shutdown requested")
                        try? await core.stop()
                        server.beginGracefulShutdown()
                        break
                    }
                }
                // Don't outlive the Lima process that spawned us when there is no VM to keep:
                // the host agent SIGTERMs the driver as it exits (once that signal was lost),
                // and `limactl snapshot` on a stopped VM spawns a driver it never stops. A VM
                // that is running stays up (its parent, `limactl start`, exits by design).
                group.addTask {
                    var orphaned = 0
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(5))
                        guard await core.isIdle, getppid() == 1 else { orphaned = 0; continue }
                        orphaned += 1
                        if orphaned >= 3 {
                            log("the Lima process that started the driver is gone and no VM is running; exiting")
                            server.beginGracefulShutdown()
                            break
                        }
                    }
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            // The server died under a running VM: don't leave usernet and the pid files behind.
            log("server failed: \(error)")
            try? await core.stop()
            throw error
        }
    }

    static func hosted(_ args: [String]) async throws {
        guard let dirArg = args.first else { throw DriverError("--hosted needs the instance directory") }
        let dir = URL(fileURLWithPath: dirArg, isDirectory: true)
        var cpus = 2
        var memory: UInt64 = 4 << 30
        var display = true
        var options = InstanceSpec.Hosted()
        var it = args.dropFirst().makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw DriverError("\(flag) needs a value") }
            return v
        }
        while let arg = it.next() {
            switch arg {
            case "--cpus": cpus = Int(try value(arg)) ?? cpus
            case "--memory": memory = UInt64(try value(arg)) ?? memory
            case "--iso": options.iso = URL(fileURLWithPath: try value(arg))
            case "--boot-image": options.bootImage = URL(fileURLWithPath: try value(arg))
            case "--helper": options.helper = URL(fileURLWithPath: try value(arg))
            case "--seed": options.seed = URL(fileURLWithPath: try value(arg))
            case "--no-cidata": options.cidata = false
            case "--headless": display = false
            case "--serial-log": options.serialLog = try value(arg)
            default: throw DriverError("unknown option \(arg)")
            }
        }
        // One hosted boot per instance: an exclusive lock held for the process's lifetime, taken
        // before anything (sockets, usernet, pid file) is created or replaced.
        let lockPath = dir.appendingPathComponent("hanalima-hosted.lock").path
        let lockFD = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw DriverError("cannot open \(lockPath): \(String(cString: strerror(errno)))") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw DriverError("a hosted boot of \(dir.lastPathComponent) is already running" + (DriverControl.hostedPID(instanceDir: dir).map { " (pid \($0))" } ?? ""))
        }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        let core = DriverCore(instanceDir: dir)
        await core.adopt(InstanceSpec(hostedDir: dir, cpus: cpus, memoryBytes: memory, display: display, hosted: options))
        let control = try ControlServer(path: dir.appendingPathComponent(DriverControl.socketName).path) { await core.control($0) }
        defer { control.close() }
        let (signals, continuation) = AsyncStream<Void>.makeStream()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { continuation.yield(()) }
            source.resume()
            return source
        }
        defer { for source in sources { source.cancel() } }
        log("hosted boot of \(dir.lastPathComponent): \(cpus) cpus, \(memory >> 20) MiB, display \(display), iso \(options.iso?.lastPathComponent ?? "-")")
        let stopped = try await core.start()
        let signalTask = Task {
            for await _ in signals {
                log("terminated by signal; powering off")
                try? await core.stop(deadline: 20)
                break
            }
        }
        defer { signalTask.cancel() }
        for await error in stopped {
            if let error { throw error }
        }
        log("hosted boot ended")
    }

    static func smoke(instanceDir: String) async throws {
        let dir = URL(fileURLWithPath: instanceDir, isDirectory: true)
        let core = DriverCore(instanceDir: dir)
        // The instance JSON as limactl prints it, for the config.
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/limactl")
        list.arguments = ["list", "--format", "json", dir.lastPathComponent]
        let pipe = Pipe()
        list.standardOutput = pipe
        try list.run()
        let json = pipe.fileHandleForReading.readDataToEndOfFile()
        list.waitUntilExit()
        _ = try await core.configure(json)
        try await core.validate()
        try await core.create()
        try await core.createDisk()
        let stopped = try await core.start()
        guard let spec = await core.spec else { return }
        do {
            let client = UsernetClient(socketPath: spec.usernetEndpointSocket)
            let ip = try await Usernet.resolveIP(mac: spec.macAddress, client: client)
            let port = 60022
            try await client.expose(local: "127.0.0.1:\(port)", remote: "\(ip):22")
            log("smoke: guest has \(ip); waiting for its sshd on 127.0.0.1:\(port)")
            try await Usernet.waitForSSHBanner(port: port, timeout: 180)
            log("smoke: sshd answers; powering off")
        } catch {
            log("smoke: \(error); powering off")
        }
        try await core.stop()
        for await error in stopped { if let error { log("smoke: \(error)") } }
        log("smoke: done")
    }
}

/// On the listening channel: a peer that connects and closes at once (Lima probes the socket
/// that way) makes NIO's accept throw NIOFcntlFailedError on Darwin. NIO keeps the listener
/// open, but the error would end the transport's accept loop; swallow it here instead.
final class AcceptErrorFilter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if error is NIOFcntlFailedError { return }
        context.fireErrorCaught(error)
    }
}
