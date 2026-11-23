import Foundation

/// How a status reads at a glance (the "Lookout" design): a word, a shape and a tone, so it
/// stays readable without colour. A row's kind (ticket, PR, session) is shown separately, on
/// the left; its status sits on the right, and CI and review state are two badges, never one.
public struct StatusBadge: Equatable, Sendable {
    public enum Glyph: Equatable, Sendable {
        case check, cross, clock, diamond, exclamation, halfCircle, openCircle, checkCircle
    }

    /// The colour role; the app maps it to its light and dark colours.
    public enum Tone: Equatable, Sendable {
        case success, attention, failure, activity, review, secondary
    }

    public var text: String
    public var glyph: Glyph
    public var tone: Tone

    public init(text: String, glyph: Glyph, tone: Tone) {
        self.text = text
        self.glyph = glyph
        self.tone = tone
    }

    /// The CI state of a PR's head commit; nil without checks.
    public static func ci(_ state: CheckState) -> StatusBadge? {
        switch state {
        case .success: StatusBadge(text: "CI passing", glyph: .check, tone: .success)
        case .failure, .error: StatusBadge(text: "CI failing", glyph: .cross, tone: .failure)
        case .pending: StatusBadge(text: "CI pending", glyph: .clock, tone: .attention)
        case .none: nil
        }
    }

    /// The review decision; nil when GitHub has none.
    public static func review(_ decision: ReviewDecision) -> StatusBadge? {
        switch decision {
        case .approved: StatusBadge(text: "Approved", glyph: .check, tone: .success)
        case .changesRequested: StatusBadge(text: "Changes requested", glyph: .exclamation, tone: .failure)
        case .reviewRequired: StatusBadge(text: "Review required", glyph: .diamond, tone: .attention)
        case .none: nil
        }
    }

    /// CI, then review: both when known.
    public static func pullRequest(_ pr: PullRequest) -> [StatusBadge] {
        [ci(pr.checks), review(pr.reviewDecision)].compactMap { $0 }
    }

    /// A PR found by a lookup, whose checks and reviews are not known.
    public static func pullRequest(_ state: PullRequestSummary.State) -> StatusBadge {
        switch state {
        case .open: StatusBadge(text: "Open", glyph: .openCircle, tone: .activity)
        case .draft: StatusBadge(text: "Draft", glyph: .openCircle, tone: .secondary)
        case .merged: StatusBadge(text: "Merged", glyph: .checkCircle, tone: .review)
        case .closed: StatusBadge(text: "Closed", glyph: .cross, tone: .secondary)
        }
    }

    /// A Jira status by its category; a status in progress that names a review stands out.
    public static func ticket(status: String, category: StatusCategory) -> StatusBadge {
        switch category {
        case .done:
            return StatusBadge(text: status.isEmpty ? "Done" : status, glyph: .checkCircle, tone: .success)
        case .inProgress where status.localizedCaseInsensitiveContains("review"):
            return StatusBadge(text: status, glyph: .diamond, tone: .review)
        case .inProgress:
            return StatusBadge(text: status.isEmpty ? "In Progress" : status, glyph: .halfCircle, tone: .activity)
        case .todo:
            return StatusBadge(text: status.isEmpty ? "To Do" : status, glyph: .openCircle, tone: .secondary)
        }
    }

    public static func session(_ status: SessionStatus) -> StatusBadge {
        switch status {
        case .busy: StatusBadge(text: "Working", glyph: .halfCircle, tone: .activity)
        case .waiting: StatusBadge(text: "Waiting for input", glyph: .diamond, tone: .attention)
        case .idle: StatusBadge(text: "Idle", glyph: .openCircle, tone: .secondary)
        case .unknown: StatusBadge(text: "Unknown", glyph: .openCircle, tone: .secondary)
        }
    }
}

extension LauncherItem.Kind {
    /// The kind's short name, shown next to its icon in the kind's colour.
    public var label: String {
        switch self {
        case .ticket: "Jira"
        case .pullRequest: "PR"
        case .reviewRequest(let direct): direct ? "Review" : "Team review"
        case .session: "Claude"
        }
    }
}
