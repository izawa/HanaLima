import Foundation

/// Result of a finished command.
public struct CommandOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
}

/// A line emitted by a streaming command.
public enum OutputLine: Sendable, Equatable {
    case stdout(String)
    case stderr(String)

    public var text: String {
        switch self {
        case .stdout(let s), .stderr(let s): s
        }
    }
}

public struct CommandError: Error, LocalizedError, Sendable {
    public let arguments: [String]
    public let status: Int32
    public let stderr: String

    public var errorDescription: String? {
        let detail = LogEntry.summarize(stderr: stderr)
        return detail.isEmpty
            ? "limactl \(arguments.first ?? "") failed (exit \(status))"
            : detail
    }
}

/// Runs an external executable. Blocking pipe reads happen on dedicated threads so
/// stdout and stderr can never deadlock each other.
public struct ProcessRunner: Sendable {
    public let executableURL: URL
    public let environment: [String: String]
    /// Working directory for child processes (nil inherits ours).
    public let currentDirectoryURL: URL?

    public init(executableURL: URL, environment: [String: String], currentDirectoryURL: URL? = nil) {
        self.executableURL = executableURL
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
    }

    /// Runs to completion, collecting output. Throws `CommandError` on non-zero exit.
    public func run(_ arguments: [String]) async throws -> CommandOutput {
        var stdout = Data()
        var stderr = ""
        for try await chunk in chunks(arguments) {
            switch chunk {
            case .stdout(let d): stdout.append(d)
            case .stderr(let d): stderr += String(decoding: d, as: UTF8.self)
            }
        }
        return CommandOutput(status: 0, stdout: stdout, stderr: stderr)
    }

    /// Streams output line by line. `\r` is treated as a line break so progress bars
    /// show up as successive lines. Cancelling the consuming task terminates the process.
    /// Pass `background: true` for long-lived helpers (e.g. `limactl watch`) that must not
    /// outlive the app; see `ProcessRunner.terminateBackgroundProcesses()`.
    /// `input` is written to the process's stdin, then stdin is closed (nil: no stdin).
    public func lines(_ arguments: [String], background: Bool = false,
                      extraEnvironment: [String: String] = [:], input: Data? = nil) -> AsyncThrowingStream<OutputLine, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var out = LineSplitter()
                var err = LineSplitter()
                do {
                    for try await chunk in chunks(arguments, background: background,
                                                  extraEnvironment: extraEnvironment, input: input) {
                        switch chunk {
                        case .stdout(let d): out.feed(d).forEach { continuation.yield(.stdout($0)) }
                        case .stderr(let d): err.feed(d).forEach { continuation.yield(.stderr($0)) }
                        }
                    }
                    if let l = out.flush() { continuation.yield(.stdout(l)) }
                    if let l = err.flush() { continuation.yield(.stderr(l)) }
                    continuation.finish()
                } catch {
                    if let l = out.flush() { continuation.yield(.stdout(l)) }
                    if let l = err.flush() { continuation.yield(.stderr(l)) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum Chunk: Sendable {
        case stdout(Data)
        case stderr(Data)
    }

    /// Terminates every running process started with `background: true`.
    /// Call from `applicationWillTerminate`; it's synchronous and safe to call more than once.
    public static func terminateBackgroundProcesses() {
        BackgroundProcesses.shared.terminateAll()
    }

    private func chunks(_ arguments: [String], background: Bool = false,
                        extraEnvironment: [String: String] = [:], input: Data? = nil) -> AsyncThrowingStream<Chunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<Chunk, Error>.makeStream()
        let handle = ProcessHandle()
        let executableURL = executableURL
        let environment = environment.merging(extraEnvironment) { _, new in new }
        let currentDirectoryURL = currentDirectoryURL

        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
            if let currentDirectoryURL { process.currentDirectoryURL = currentDirectoryURL }
            let inPipe: Pipe? = input == nil ? nil : Pipe()
            process.standardInput = inPipe ?? FileHandle.nullDevice
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let stderrCopy = LockedData()
            do {
                try handle.launch(process)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            if let inPipe, let input {
                // Written on its own thread: a script longer than the pipe buffer would block us
                // before we read the output.
                DispatchQueue.global().async {
                    try? inPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inPipe.fileHandleForWriting.close()
                }
            }
            if background { BackgroundProcesses.shared.insert(process.processIdentifier) }
            defer { if background { BackgroundProcesses.shared.remove(process.processIdentifier) } }

            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                Self.drain(outPipe.fileHandleForReading) { continuation.yield(.stdout($0)) }
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                Self.drain(errPipe.fileHandleForReading) {
                    stderrCopy.append($0)
                    continuation.yield(.stderr($0))
                }
                group.leave()
            }
            process.waitUntilExit()
            // Grandchildren (e.g. a backgrounded ssh) can inherit the pipes and keep them open
            // long after our process is gone; don't let them hold the stream hostage.
            _ = group.wait(timeout: .now() + 1)

            let status = process.terminationStatus
            if status == 0 || handle.wasCancelled {
                continuation.finish()
            } else {
                continuation.finish(throwing: CommandError(
                    arguments: arguments,
                    status: status,
                    stderr: String(decoding: stderrCopy.data, as: UTF8.self)))
            }
        }

        continuation.onTermination = { termination in
            if case .cancelled = termination { handle.cancel() }
        }
        return stream
    }

    private static func drain(_ fh: FileHandle, _ emit: (Data) -> Void) {
        while true {
            let data = fh.availableData
            if data.isEmpty { return }
            emit(data)
        }
    }
}

/// Lets a cancellation from another thread terminate a process that may not have launched yet.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool { lock.withLock { cancelled } }

    func launch(_ process: Process) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            self.process = process
            try process.run()
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.interrupt() }
        }
    }
}

/// PIDs of long-lived helper processes to kill when the app exits.
private final class BackgroundProcesses: @unchecked Sendable {
    static let shared = BackgroundProcesses()
    private let lock = NSLock()
    private var pids: Set<pid_t> = []

    func insert(_ pid: pid_t) { lock.withLock { _ = pids.insert(pid) } }
    func remove(_ pid: pid_t) { lock.withLock { _ = pids.remove(pid) } }

    func terminateAll() {
        lock.withLock {
            for pid in pids { kill(pid, SIGTERM) }
            pids.removeAll()
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    var data: Data { lock.withLock { buffer } }
    func append(_ d: Data) { lock.withLock { buffer.append(d) } }
}

/// Splits a byte stream into lines on `\n` or `\r`, skipping empty lines.
struct LineSplitter {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let idx = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = pending[pending.startIndex..<idx]
            pending.removeSubrange(pending.startIndex...idx)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        return lines
    }

    mutating func flush() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}
