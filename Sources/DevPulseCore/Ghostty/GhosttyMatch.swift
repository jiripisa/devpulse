import Darwin
import Foundation

/// One terminal surface as Ghostty's scripting dictionary reports it (`terminal` class:
/// `id`, `tty`, `pid` of the foreground process, `working directory`).
public struct GhosttyTerminal: Sendable, Equatable {
    public var id: String
    public var tty: String?
    public var pid: Int?
    public var workingDirectory: String?

    public init(id: String, tty: String?, pid: Int?, workingDirectory: String?) {
        self.id = id
        self.tty = tty
        self.pid = pid
        self.workingDirectory = workingDirectory
    }
}

/// Picks the Ghostty terminal that runs a Claude Code session.
public enum GhosttyMatch {
    /// In order of reliability: the session's tty, then the terminal's foreground pid, then a
    /// working directory that only one terminal has. Nil when nothing matches for sure.
    public static func terminalID(in terminals: [GhosttyTerminal], tty: String?, pid: Int, cwd: String) -> String? {
        if let tty, let match = terminals.first(where: { $0.tty == tty }) { return match.id }
        if let match = terminals.first(where: { $0.pid == pid }) { return match.id }
        let wanted = normalized(cwd)
        guard !wanted.isEmpty else { return nil }
        let matches = terminals.filter { $0.workingDirectory.map(normalized) == wanted }
        return matches.count == 1 ? matches[0].id : nil
    }

    private static func normalized(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
            .trimmingSuffix("/")
    }
}

/// The controlling terminal of a process, read with `sysctl` (what `ps -o tty=` shows).
public enum ProcessTTY {
    /// `/dev/ttys006`, or nil for a missing process or one without a terminal.
    public static func path(of pid: Int) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        let text = String(cString: name)
        return text.isEmpty || text.hasPrefix("?") ? nil : "/dev/" + text
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var text = self
        while text.count > 1, text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        return text
    }
}
