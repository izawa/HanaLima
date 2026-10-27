import Foundation

/// One-shot provisioning on top of Lima's run-at-every-boot scripts: the user's script is wrapped
/// so that it runs once and leaves a stamp, and later boots exit at once. Only the body is edited;
/// the wrapper is fixed text, so it can be recognized and the body taken out again. A new id (a
/// new stamp) makes it run once more. A failure leaves no stamp, so the next boot retries.
///
/// Stamps: `/var/lib/hanalima/once/<id>.done` for root scripts, `$HOME/.local/state/hanalima/once/`
/// for user scripts (both on the VM's disk, so a copy inherits them and a restored snapshot reverts them).
public enum ProvisionOnce {
    static let marker = "# hanalima: once "

    public static func stampDirectory(for mode: ProvisionConfig.Mode) -> String {
        mode == .user ? "$HOME/.local/state/hanalima/once" : "/var/lib/hanalima/once"
    }

    /// Modes the wrapper applies to (the others run too early, or aren't scripts).
    public static func supports(_ mode: ProvisionConfig.Mode) -> Bool { mode == .system || mode == .user }

    public static func newID() -> String { UUID().uuidString.lowercased() }

    static let defaultShebang = "#!/bin/sh"

    /// The wrapped script. The body runs in a subshell, so its own `exit` doesn't skip the stamp.
    /// The body's `#!` line (if any) becomes the wrapper's, so the script keeps its interpreter.
    public static func wrap(body: String, mode: ProvisionConfig.Mode, id: String) -> String {
        var b = body
        var shebang = defaultShebang
        if b.hasPrefix("#!") {
            let parts = b.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            shebang = String(parts[0])
            b = parts.count > 1 ? String(parts[1]) : ""
        }
        if !b.hasSuffix("\n") { b += "\n" }
        return """
        \(shebang)
        \(marker)\(id)
        # Runs the part between the markers once; the stamp marks it done. Edit it in HanaLima.
        HL_STAMP="\(stampDirectory(for: mode))/\(id).done"
        [ -e "$HL_STAMP" ] && exit 0
        hl_once() {
        # hanalima: body-begin
        \(b)# hanalima: body-end
        }
        (hl_once) && mkdir -p "$(dirname "$HL_STAMP")" && touch "$HL_STAMP"

        """
    }

    /// The id and the body of a wrapped script, or nil for a plain script.
    public static func parse(_ script: String) -> (id: String, body: String)? {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1, lines[1].hasPrefix(marker) else { return nil }
        let id = String(lines[1].dropFirst(marker.count))
        guard let begin = lines.firstIndex(of: "# hanalima: body-begin"),
              let end = lines.lastIndex(of: "# hanalima: body-end"), begin < end else { return nil }
        let shebang = lines[0] == defaultShebang ? "" : lines[0] + "\n"
        return (id, shebang + lines[(begin + 1)..<end].joined(separator: "\n") + "\n")
    }
}

public extension ProvisionConfig {
    /// For a one-shot entry, its stamp id.
    var onceID: String? { mode.isScript ? ProvisionOnce.parse(script)?.id : nil }

    /// The script as the user wrote it (the body of a one-shot entry).
    var scriptBody: String { ProvisionOnce.parse(script)?.body ?? script }
}
