import Foundation

/// Reading which OS a guest runs (docs/20): a fixed script run with `limactl shell … sh -s`,
/// and the name to show from its output. The output is the guest's, so it is parsed as data
/// (os-release is never sourced) and only the marked stdout lines are used.
public enum GuestOS {
    private static let mark = "hanalima-os-"

    /// Prints `uname -s`, then the version: os-release on Linux, `sw_vers` on macOS,
    /// `freebsd-version -u` on FreeBSD. No `sudo`, no network.
    public static let script = #"""
        os=$(uname -s)
        printf 'hanalima-os-uname=%s\n' "$os"
        case "$os" in
        Darwin) v=$(sw_vers -productVersion) || exit 1; printf 'hanalima-os-version=%s\n' "$v" ;;
        FreeBSD) v=$(freebsd-version -u) || exit 1; printf 'hanalima-os-version=%s\n' "$v" ;;
        Linux)
            for f in /etc/os-release /usr/lib/os-release; do
                if [ -r "$f" ]; then head -c 8192 "$f" | sed 's/^/hanalima-os-release:/'; break; fi
            done ;;
        esac
        """#

    /// The longest name kept.
    static let maxLength = 120

    /// The name to show, from the script's stdout lines; nil when the script didn't report.
    public static func name(fromStdout lines: [String]) -> String? {
        var uname: String?
        var version: String?
        var release: [String: String] = [:]
        for line in lines where line.hasPrefix(mark) {
            let body = line.dropFirst(mark.count)
            if body.hasPrefix("uname=") {
                uname = String(body.dropFirst("uname=".count))
            } else if body.hasPrefix("version=") {
                version = String(body.dropFirst("version=".count))
            } else if body.hasPrefix("release:"), let eq = body.firstIndex(of: "=") {
                let key = body.dropFirst("release:".count)[..<eq]
                release[String(key)] = unquote(String(body[body.index(after: eq)...]))
            }
        }
        guard let uname = clean(uname) else { return nil }
        let cleanVersion = clean(version)
        let name: String? = switch uname {
        case "Linux":
            clean(release["PRETTY_NAME"])
                ?? clean(release["NAME"]).map { name in clean(release["VERSION_ID"]).map { "\(name) \($0)" } ?? name }
                ?? "Linux"
        case "Darwin": cleanVersion.map { "macOS \($0)" } ?? "macOS"
        case "FreeBSD": cleanVersion.map { "FreeBSD \($0)" } ?? "FreeBSD"
        default: uname
        }
        return name.flatMap(clean)
    }

    /// An os-release value as the shell would read it (os-release(5)): inside single quotes as
    /// is; inside double quotes `\` escapes only `\ " $ ``; unquoted, `\` escapes any character.
    static func unquote(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        if let first = v.first, first == "\"" || first == "'", v.count >= 2, v.last == first {
            let inner = v.dropFirst().dropLast()
            return first == "'" ? String(inner) : unescape(inner) { "\\\"$`".contains($0) }
        }
        return unescape(Substring(v)) { _ in true }
    }

    private static func unescape(_ text: Substring, escapable: (Character) -> Bool) -> String {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            if c == "\\", next < text.endIndex, escapable(text[next]) {
                out.append(text[next])
                i = text.index(after: next)
            } else {
                out.append(c)
                i = next
            }
        }
        return out
    }

    /// Without control characters, trimmed, at most `maxLength` characters; nil when empty.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? nil : String(kept.prefix(maxLength))
    }
}
