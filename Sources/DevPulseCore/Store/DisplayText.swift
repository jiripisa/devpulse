import Foundation

extension Snapshot {
    /// What the menu bar icon counts: direct review requests plus Claude sessions waiting for me.
    public var attentionCount: Int {
        reviewRequests.count(where: \.requestedDirectly) + sessions.count { $0.status == .waiting }
    }
}

/// Short relative times for the UI: "just now", "2 min ago", "3 h ago", "1 d ago".
public enum RelativeAge {
    public static func text(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }
}

/// One line per source: its age when OK, otherwise its state or error (with the data's age).
public enum SourceStatusText {
    public static func text(for status: SourceStatus, now: Date) -> String {
        let age = status.lastSuccess.map { RelativeAge.text(since: $0, now: now) }
        switch status.state {
        case .ok:
            return [status.message, age].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "OK"
        case .error:
            let message = status.message ?? "Error"
            return age.map { "\(message) · data from \($0)" } ?? message
        case .fetching: return "Loading…"
        case .disabled: return "Off"
        case .unconfigured: return "Not configured"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// What an empty section shows instead of rows.
public enum SectionPlaceholder: Sendable, Equatable {
    /// A link to Settings.
    case setUp
    case text(String)
}

extension SourceStatusText {
    /// The empty state of a section fed by a source with `status`; `empty` is the section's own
    /// "nothing here" text, used only when the empty list is known to be real.
    public static func placeholder(for status: SourceStatus, empty: String) -> SectionPlaceholder {
        switch status.state {
        case .unconfigured: .setUp
        case .disabled: .text("Turned off in Settings")
        case .fetching: .text("Loading…")
        case .error where status.lastSuccess == nil: .text("Could not load")
        case .ok, .error: .text(empty)
        }
    }
}
