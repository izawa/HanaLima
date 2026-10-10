import CryptoKit
import Foundation

/// Progress of an image/archive download performed by limactl.
public struct DownloadProgress: Sendable, Equatable {
    public var remote: URL
    public var received: Int64
    public var total: Int64?
    /// Recent average, once a few seconds of samples exist.
    public var bytesPerSecond: Double?

    public init(remote: URL, received: Int64, total: Int64?, bytesPerSecond: Double? = nil) {
        self.remote = remote
        self.received = received
        self.total = total
        self.bytesPerSecond = bytesPerSecond
    }

    public var fileName: String { remote.lastPathComponent }
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    /// Whole percent, never 100 before the download is really done.
    public var percent: Int? {
        fraction.map { min(99, Int(($0 * 100).rounded(.down))) }
    }

    /// Estimated seconds left at the recent speed.
    public var secondsRemaining: Double? {
        guard let total, let speed = bytesPerSecond, speed > 0, total > received else { return nil }
        return Double(total - received) / speed
    }
}

/// Download speed over a sliding window, so a short stall or burst doesn't swing the estimate.
struct SpeedMeter {
    var window: Double = 8
    private var samples: [(time: Double, bytes: Int64)] = []

    init(window: Double = 8) { self.window = window }

    mutating func add(time: Double, bytes: Int64) -> Double? {
        // A smaller size means a new temp file (retry): start over.
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }
        samples.append((time, bytes))
        samples.removeAll { time - $0.time > window }
        guard let first = samples.first, time - first.time >= 2 else { return nil }
        return Double(bytes - first.bytes) / (time - first.time)
    }
}

/// limactl prints no download progress when stdout isn't a TTY, so we infer it from the
/// partially written cache file: `<cache>/download/by-url-sha256/<sha256(url)>/data.tmp.<pid>.<n>`
/// (see `pkg/downloader` in Lima).
public enum DownloadMonitor {
    public static var cacheRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Caches")
        return base.appending(path: "lima")
    }

    public static func cacheDirectory(for remote: String, cacheRoot: URL = cacheRoot) -> URL {
        let key = SHA256.hash(data: Data(remote.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheRoot.appending(path: "download/by-url-sha256/\(key)")
    }

    /// Size of the most recently modified temp file for `remote`, if a download is in progress.
    public static func partialSize(for remote: String, cacheRoot: URL = cacheRoot) -> Int64? {
        let dir = cacheDirectory(for: remote, cacheRoot: cacheRoot)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys) else { return nil }
        let temps = files.filter { $0.lastPathComponent.hasPrefix("data.tmp.") }
            .compactMap { url -> (Date, Int64)? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      let date = v.contentModificationDate, let size = v.fileSize else { return nil }
                return (date, Int64(size))
            }
        return temps.max { $0.0 < $1.0 }?.1
    }

    /// Content-Length via HEAD, or, for servers that refuse HEAD, the total in the
    /// `Content-Range` of a one-byte GET. Nil if the server doesn't say.
    public static func contentLength(of url: URL) async -> Int64? {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 15
        if let (_, response) = try? await URLSession.shared.data(for: head),
           let http = response as? HTTPURLResponse, http.statusCode == 200, http.expectedContentLength > 0 {
            return http.expectedContentLength
        }
        var range = URLRequest(url: url)
        range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        range.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: range),
              let http = response as? HTTPURLResponse, http.statusCode == 206,
              let header = http.value(forHTTPHeaderField: "Content-Range") else { return nil }
        return totalLength(fromContentRange: header)
    }

    /// "bytes 0-0/945530880" → 945530880 ("*" means unknown).
    static func totalLength(fromContentRange header: String) -> Int64? {
        guard let total = header.split(separator: "/").last.flatMap({ Int64($0) }), total > 0 else { return nil }
        return total
    }

    /// Emits progress about once a second until the consuming task is cancelled.
    public static func progress(for remote: String, interval: Duration = .seconds(1)) -> AsyncStream<DownloadProgress> {
        AsyncStream { continuation in
            let task = Task {
                guard let url = URL(string: remote), ["http", "https"].contains(url.scheme) else {
                    continuation.finish()
                    return
                }
                let total = await contentLength(of: url)
                var meter = SpeedMeter()
                let clock = ContinuousClock()
                let start = clock.now
                while !Task.isCancelled {
                    if let size = partialSize(for: remote) {
                        let elapsed = start.duration(to: clock.now) / .seconds(1)
                        let speed = meter.add(time: elapsed, bytes: size)
                        continuation.yield(DownloadProgress(remote: url, received: size, total: total,
                                                            bytesPerSecond: speed))
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
