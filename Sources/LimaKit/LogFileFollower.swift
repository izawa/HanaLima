import Foundation

/// Follows a growing text file (`tail -F`-style): each call returns only the complete lines
/// appended since the previous call. Lima recreates `ha.stderr.log` and the serial logs on every
/// start, so a replaced or truncated file starts over (`reset` is true).
public final class LogFileFollower {
    public let url: URL
    /// On the first read (and after a reset), only this many trailing bytes are read.
    public let initialBytes: UInt64
    private var offset: UInt64 = 0
    private var fileID: (device: UInt64, inode: UInt64)?
    private var partial = Data()

    public init(url: URL, initialBytes: UInt64 = 1 << 20) {
        self.url = url
        self.initialBytes = initialBytes
    }

    public struct Chunk: Equatable, Sendable {
        /// The file was replaced or truncated (or read for the first time); drop earlier lines.
        public var reset: Bool
        public var lines: [String]
    }

    /// Lines appended since the last call. Returns `nil` if the file doesn't exist.
    public func readNewLines() -> Chunk? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            fileID = nil
            return nil
        }
        let id = ((attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                  (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        var reset = false
        if fileID == nil || fileID! != id || size < offset {
            reset = true
            fileID = id
            partial = Data()
            offset = size > initialBytes ? size - initialBytes : 0
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else {
            return Chunk(reset: reset, lines: [])
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)

        var buffer = partial + data
        var lines: [String] = []
        // When starting mid-file, the first line is cut off; skip it.
        var skipFirst = reset && offset - UInt64(data.count) > 0
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if skipFirst {
                skipFirst = false
                continue
            }
            lines.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
        partial = Data(buffer)
        return Chunk(reset: reset, lines: lines)
    }

    /// Removes ANSI escape sequences (colors, cursor movement) that serial consoles emit.
    public static func stripANSI(_ s: String) -> String {
        s.replacing(/\x1B\[[0-9;?=<>]*[ -\/]*[@-~]|\x1B[()][0-9A-Za-z]|\x1B[=>]/, with: "")
    }
}
