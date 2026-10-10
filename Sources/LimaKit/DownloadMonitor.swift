import CryptoKit
import Foundation

/// Progress of an image/archive download performed by limactl.
public struct DownloadProgress: Sendable, Equatable {
    public var remote: URL
    public var received: Int64
    public var total: Int64?

    public var fileName: String { remote.lastPathComponent }
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
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

    /// Content-Length via HEAD; nil if the server doesn't say.
    public static func contentLength(of url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let length = http.expectedContentLength
        return length > 0 ? length : nil
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
                while !Task.isCancelled {
                    if let size = partialSize(for: remote) {
                        continuation.yield(DownloadProgress(remote: url, received: size, total: total))
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
