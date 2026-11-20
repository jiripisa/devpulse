import Foundation

/// Decides whether the app shell's loop should fetch now.
public struct RefreshPolicy: Sendable {
    /// What the timer, waking and the refresh commands fetch. Claude Code sessions are left
    /// out: the file watcher owns them (a re-scan would skip its protection against a
    /// half-written session file).
    public static let fetchedSources: Set<Source> = [.github, .jira]

    public init() {}

    /// How late the loop's sleep may end, so the system can group it with other wakes.
    public func tolerance(forSleep delay: TimeInterval) -> TimeInterval {
        delay / 10
    }

    public func shouldFetch(now: Date, lastAttempt: Date?, interval: TimeInterval, paused: Bool) -> Bool {
        guard !paused else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= interval
    }

    /// How long the loop can sleep before the next fetch is due (0 when it is due already).
    public func secondsUntilDue(now: Date, lastAttempt: Date?, interval: TimeInterval) -> TimeInterval {
        guard let lastAttempt else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastAttempt))
    }
}
