import Darwin
import Dispatch
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import NIOCore
import NIOPosix

@main
struct HanaLimaDriver {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--inspect-status"] {
                try inspectStatus()
            } else if args.count == 2, args[0] == "--inst-dir" {
                try await serve(instanceDir: args[1])
            } else {
                throw DriverError("Usage: lima-driver-hanalima --inst-dir <dir> | --inspect-status")
            }
        } catch {
            log("error: \(error)")
            exit(1)
        }
    }

    static func inspectStatus() throws {
        // Go encodes []byte as a base64 JSON string. Preserve the decoded bytes.
        guard let line = readLine() else { throw DriverError("Expected a JSON string on stdin") }
        let encoded = try JSONDecoder().decode(String.self, from: Data(line.utf8))
        guard let bytes = Data(base64Encoded: encoded) else { throw DriverError("Invalid base64 status") }
        let output = try JSONEncoder().encode(bytes.base64EncodedString())
        FileHandle.standardOutput.write(output + Data([10]))
    }

    static func serve(instanceDir: String) async throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: instanceDir, withIntermediateDirectories: true)
        let path = URL(fileURLWithPath: instanceDir).appendingPathComponent("hanalima.drv.sock").path
        // Do not accidentally delete a regular file at the socket location.
        var attributes = stat()
        if lstat(path, &attributes) == 0 {
            guard attributes.st_mode & S_IFMT == S_IFSOCK else {
                throw DriverError("Refusing to remove non-socket at \(path)")
            }
            try fm.removeItem(atPath: path)
        } else if errno != ENOENT {
            throw DriverError("Cannot inspect socket path: errno \(errno)")
        }
        defer { try? fm.removeItem(atPath: path) }

        let state = DriverState()
        let service = DriverService(instanceDir: instanceDir, state: state)
        // A client that connects and closes at once (Lima probes the socket that way) makes the
        // NIO transport throw NIOFcntlFailedError on the accepted socket, which ends serve().
        // Keep listening by making a fresh server until a shutdown is requested.
        let lifecycle = ServerLifecycle()

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

        log("Serving Driver on \(path)")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while await !lifecycle.isShuttingDown {
                    var config = HTTP2ServerTransport.Posix.Config.defaults
                    config.channelDebuggingCallbacks.onBindTCPListener = { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(AcceptErrorFilter())
                        }
                    }
                    let server = GRPCServer(
                        transport: .http2NIOPosix(address: .unixDomainSocket(path: path), transportSecurity: .plaintext,
                                                  config: config),
                        services: [service]
                    )
                    await lifecycle.set(server)
                    do {
                        try await server.serve()
                        break
                    } catch {
                        if await lifecycle.isShuttingDown { break }
                        log("server transport error: \(error); listening again")
                        unlink(path)
                    }
                }
            }
            group.addTask {
                for await _ in signals {
                    log("Shutdown requested")
                    // End Start streams before draining the transport.
                    await state.stop(shutdown: true)
                    await lifecycle.shutDown()
                    break
                }
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}

/// On the listening channel: a peer that connects and closes at once (Lima probes the socket that
/// way) makes NIO's accept fail with NIOFcntlFailedError on Darwin. NIO keeps the listener open,
/// but the error would still end the transport's accept loop; swallow it here instead.
final class AcceptErrorFilter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if error is NIOFcntlFailedError {
            log("ignored an accept-side error (peer closed at once)")
            return
        }
        context.fireErrorCaught(error)
    }
}

/// The server currently listening, and whether a shutdown was requested.
actor ServerLifecycle {
    private var server: GRPCServer<HTTP2ServerTransport.Posix>?
    private(set) var isShuttingDown = false
    func set(_ s: GRPCServer<HTTP2ServerTransport.Posix>) { server = s }
    func shutDown() {
        isShuttingDown = true
        server?.beginGracefulShutdown()
    }
}

struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
