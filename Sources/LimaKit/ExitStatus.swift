import Foundation

public enum ExitStatus {
    /// Decodes a raw `waitpid` status (as SwiftTerm reports it, e.g. 65280) into a shell-style
    /// exit code: the exit status for normal exits, 128 + signal number for signals.
    public static func decode(waitStatus raw: Int32) -> Int32 {
        let signal = raw & 0x7f
        if signal == 0 { return (raw >> 8) & 0xff }
        return 128 + signal
    }
}
