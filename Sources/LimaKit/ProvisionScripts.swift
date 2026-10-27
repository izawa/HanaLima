import Foundation

/// Turns provisioning entries into one shell script that runs them in order, as root, the way
/// Lima's boot does (data files written, system scripts as root, user scripts as the user), for
/// running them in a guest right now through `sh -s`.
public enum ProvisionScripts {
    /// `mkdir`, write with a quoted heredoc (no expansion), then owner and mode.
    public static func writeFile(_ entry: ProvisionConfig) -> String {
        let path = entry.path
        var s = "mkdir -p \"$(dirname \(quote(path)))\"\n"
        s += "cat > \(quote(path)) <<'\(heredocTag(for: entry.content))'\n\(entry.content)"
        if !entry.content.hasSuffix("\n") { s += "\n" }
        s += "\(heredocTag(for: entry.content))\n"
        if let owner = entry.extraString("owner") { s += "chown \(quote(owner)) \(quote(path))\n" }
        if let permissions = entry.extraString("permissions") { s += "chmod \(quote(permissions)) \(quote(path))\n" }
        s += "echo \"wrote \(path)\"\n"
        return s
    }

    /// The whole sequence as one root script; `user` is the guest account for user-mode scripts.
    /// Stops at the first failure. Entries that only YAML can express (`yq`, `file:`) are skipped
    /// with a note.
    public static func combined(_ entries: [ProvisionConfig], user: String) -> String {
        var s = "set -e\n"
        for (i, entry) in entries.enumerated() {
            let heading = "### \(i + 1)/\(entries.count) [\(entry.mode.rawValue)] \(entry.summary)"
            s += "echo \(quote(heading))\n"
            guard entry.isEditable else {
                s += "echo \"(skipped: only Lima can run this entry)\"\n"
                continue
            }
            switch entry.mode {
            case .data:
                s += writeFile(entry)
            case .user:
                let tag = heredocTag(for: entry.script)
                s += "sudo -u \(quote(user)) -i sh -s <<'\(tag)'\n\(entry.script)\(entry.script.hasSuffix("\n") ? "" : "\n")\(tag)\n"
            default:
                let tag = heredocTag(for: entry.script)
                s += "sh -s <<'\(tag)'\n\(entry.script)\(entry.script.hasSuffix("\n") ? "" : "\n")\(tag)\n"
            }
        }
        return s
    }

    /// A heredoc delimiter that doesn't occur in `body`.
    static func heredocTag(for body: String) -> String {
        var tag = "HANALIMA_EOF"
        while body.contains(tag) { tag += "_" }
        return tag
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
