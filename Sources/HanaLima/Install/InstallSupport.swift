import Foundation
import LimaKit
import NetworkKit

/// Creating a VM from an installer ISO (docs/07): what `limactl create` gets, and what HanaLima
/// keeps around for it.
enum InstallSupport {
    /// A 1 MiB image for `limactl create`, so Lima makes a blank disk of the requested size.
    /// Only `create` reads it; start, edit, list and clone work without it.
    static var placeholderImage: URL {
        NetworkPaths.supportDirectory.appending(path: "installer/placeholder.raw")
    }

    static func ensurePlaceholderImage() throws {
        let url = placeholderImage
        if FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1 << 20).write(to: url)
    }

    /// `--set` expressions: the placeholder as the image (VZ, arm64), and no containerd (Lima's
    /// boot script installing nerdctl into an arbitrary installed OS is untested).
    static var createExpressions: [String] {
        [#".images = [{"location": "\#(placeholderImage.path)", "arch": "aarch64"}]"#,
         #".containerd = {"system": false, "user": false}"#]
    }

    /// "ubuntu-26.04-live-server-arm64.iso" → "ubuntu-26.04": the name up to the first word
    /// that isn't a version, as a valid instance name.
    static func suggestedName(for iso: URL) -> String {
        let stem = iso.deletingPathExtension().lastPathComponent.lowercased()
        var parts: [String] = []
        for part in stem.split(separator: "-") {
            let s = String(part)
            if !parts.isEmpty, s.first?.isNumber != true { break }
            parts.append(s)
        }
        let name = parts.joined(separator: "-")
        return CreateOptions.isValidName(name) ? name : "custom"
    }
}

struct InstallRequest: Identifiable, Equatable {
    let name: String
    var id: String { name }
}

extension AppModel {
    func pendingInstall(_ name: String) -> InstanceMetadata.PendingInstall? {
        metadata[name]?.pendingInstall
    }
}
