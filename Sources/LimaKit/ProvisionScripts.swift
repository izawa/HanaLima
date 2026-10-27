import Foundation

/// Turns provisioning entries into one shell script that runs them in order the way Lima's boot
/// does (data files written with owner and mode, system scripts as root, user scripts as the
/// user), for running them in a guest right now through `limactl shell … sh -s` as the user.
/// Lima's template fields (`{{.User}}`, `{{.Home}}`, `{{.UID}}`, `{{.Name}}`, `{{.Hostname}}`) are
/// expanded in the guest, so the result matches what the boot would have run.
public enum ProvisionScripts {
    /// The whole sequence as one script for the VM's user (root steps go through `sudo`, which
    /// Lima sets up without a password). Stops at the first failure. Entries that only YAML can
    /// express (`yq`, `file:`) are skipped with a note.
    public static func combined(_ entries: [ProvisionConfig], instanceName: String) -> String {
        var s = """
        set -e
        HL_USER=$(id -un); HL_HOME=$HOME; HL_UID=$(id -u); HL_NAME=\(quote(instanceName)); HL_HOST=$(hostname)
        hl_expand() { sed -e "s|{{\\.User}}|$HL_USER|g" -e "s|{{\\.Home}}|$HL_HOME|g" -e "s|{{\\.UID}}|$HL_UID|g" -e "s|{{\\.Name}}|$HL_NAME|g" -e "s|{{\\.Hostname}}|$HL_HOST|g"; }
        hl_mkdir() { [ -d "$1" ] && return 0; hl_mkdir "$(dirname "$1")" "$2"; sudo -- mkdir "$1"; [ -n "$2" ] && sudo -- chown "$2" "$1"; }
        HL_TMP=$(mktemp -d); trap 'rm -rf "$HL_TMP"' EXIT

        """
        for (i, entry) in entries.enumerated() {
            let heading = "### \(i + 1)/\(entries.count) [\(entry.mode.rawValue)] \(entry.summary)"
            s += "echo \(quote(heading))\n"
            guard entry.isEditable else {
                s += "echo '(skipped: only Lima can run this entry)'\n"
                continue
            }
            switch entry.mode {
            case .data:
                s += writeFile(entry)
            case .user:
                s += heredoc(entry.script, into: "$HL_TMP/script") + "sh \"$HL_TMP/script\"\n"
            default:
                s += heredoc(entry.script, into: "$HL_TMP/script") + "sudo -- sh \"$HL_TMP/script\"\n"
            }
        }
        return s
    }

    /// Writes the content to a temp file through a quoted heredoc (no expansion), then installs
    /// it as root at the expanded path, with owner and mode as Lima would.
    static func writeFile(_ entry: ProvisionConfig) -> String {
        var s = heredoc(entry.content, into: "$HL_TMP/data")
        s += "HL_PATH=$(printf %s \(quote(entry.path)) | hl_expand)\n"
        // Missing parent folders get the file's owner (cloud-init would leave them to root).
        let owner = entry.extraString("owner").map { "\"$(printf %s \(quote($0)) | hl_expand)\"" } ?? "''"
        s += "HL_OWNER=\(owner)\n"
        s += "hl_mkdir \"$(dirname \"$HL_PATH\")\" \"$HL_OWNER\"\n"
        s += "sudo -- cp \"$HL_TMP/data\" \"$HL_PATH\"\n"
        s += "[ -n \"$HL_OWNER\" ] && sudo -- chown \"$HL_OWNER\" \"$HL_PATH\"\n"
        if let permissions = entry.extraString("permissions") {
            s += "sudo -- chmod \(quote(permissions)) \"$HL_PATH\"\n"
        }
        s += "echo \"wrote $HL_PATH\"\n"
        return s
    }

    /// `hl_expand > <file> <<'TAG' … TAG`.
    static func heredoc(_ body: String, into file: String) -> String {
        let tag = heredocTag(for: body)
        return "hl_expand > \"\(file)\" <<'\(tag)'\n\(body)\(body.hasSuffix("\n") ? "" : "\n")\(tag)\n"
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
