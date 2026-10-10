import Foundation

/// A snapshot from `limactl snapshot list` (QEMU only; Lima 2.2's VZ driver doesn't implement them).
///
/// Snapshots are qcow2 internal snapshots of the instance's main disk. With the VM stopped Lima
/// uses `qemu-img snapshot`, which works reliably; with it running Lima sends HMP `savevm`, which
/// QEMU refuses while a 9p share is mounted — and limactl still exits 0. A failed `loadvm` also
/// leaves the VM paused in `restore-vm`. HanaLima therefore only offers snapshots while stopped.
public struct LimaSnapshot: Hashable, Sendable, Identifiable {
    public var id: String { tag }
    public var number: Int
    public var tag: String
    /// RAM state size as qemu-img prints it ("0 B" for disk-only snapshots).
    public var vmSize: String
    public var date: Date?

    public init(number: Int, tag: String, vmSize: String = "0 B", date: Date? = nil) {
        self.number = number
        self.tag = tag
        self.vmSize = vmSize
        self.date = date
    }

    /// Parses the qemu-img style table:
    /// `ID  TAG  VM_SIZE  DATE  VM_CLOCK  [ICOUNT]`
    public static func parseList(_ text: String) -> [LimaSnapshot] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let m = line.wholeMatch(of:
                /\s*(\d+)\s+(.+?)\s+(\d+(?:\.\d+)?\s*[KMGTP]?i?B)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+\S+(?:\s+\S+)?\s*/),
                  let number = Int(m.1) else { return nil }
            return LimaSnapshot(number: number, tag: String(m.2), vmSize: String(m.3),
                                date: formatter.date(from: String(m.4)))
        }
    }

    /// Tags HanaLima creates: letters, digits, `.`, `_`, `-`; up to 64 characters.
    public static func isValidTag(_ tag: String) -> Bool {
        tag.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) != nil
    }

    /// e.g. "snap-20261010-153012".
    public static func suggestedTag(at date: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "'snap-'yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
