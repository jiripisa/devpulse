import Foundation

public enum OpenTarget: Sendable, Equatable {
    case url(URL)
    case session(pid: Int)
}

public enum NotificationEvent: Sendable, Equatable {
    case reviewRequested(PullRequest, direct: Bool)
    case prComment(PullRequest, Comment)
    case ciFinished(PullRequest, CheckState)
    case ticketComment(Ticket, Comment)
    /// A ticket I created reached one of the watched statuses (its `status`).
    case createdTicketReachedStatus(Ticket)
    case claudeWaiting(ClaudeSession)
    case claudeFinished(ClaudeSession)

    public var trigger: NotificationTrigger {
        switch self {
        case .reviewRequested(_, let direct): direct ? .directReviewRequest : .teamReviewRequest
        case .prComment(_, let comment):
            switch comment.authorKind {
            case .human: .prHumanComment
            case .copilot: .prCopilotComment
            case .bot: .prBotComment
            }
        case .ciFinished: .ciFinished
        case .ticketComment(_, let comment): comment.authorKind == .human ? .jiraHumanComment : .jiraAutomationComment
        case .createdTicketReachedStatus: .jiraCreatedTicketStatus
        case .claudeWaiting: .claudeWaiting
        case .claudeFinished: .claudeFinished
        }
    }

    public var title: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .prComment(let pr, _): "New comment on #\(pr.number)"
        case .ciFinished(let pr, let state):
            switch state {
            case .success: "CI passed on #\(pr.number)"
            case .failure: "CI failed on #\(pr.number)"
            default: "CI error on #\(pr.number)"
            }
        case .ticketComment(let ticket, _): "New comment on \(ticket.key)"
        case .createdTicketReachedStatus(let ticket): "\(ticket.key) is \(ticket.status)"
        case .claudeWaiting: "Claude is waiting"
        case .claudeFinished: "Claude finished"
        }
    }

    public var body: String {
        switch self {
        case .reviewRequested(let pr, _): "\(pr.repo)#\(pr.number) \(pr.title)"
        case .prComment(let pr, let comment): "\(comment.authorName ?? comment.author): \(pr.title)"
        case .ciFinished(let pr, _): "\(pr.repo) \(pr.title)"
        case .ticketComment(let ticket, let comment): "\(comment.authorName ?? comment.author): \(ticket.summary)"
        case .createdTicketReachedStatus(let ticket): ticket.summary
        case .claudeWaiting(let session): "\(session.name) — \(session.waitingFor ?? "needs your input")"
        case .claudeFinished(let session): session.name
        }
    }

    public var target: OpenTarget {
        switch self {
        case .reviewRequested(let pr, _), .prComment(let pr, _), .ciFinished(let pr, _): .url(Self.url(pr.url))
        case .ticketComment(let ticket, _), .createdTicketReachedStatus(let ticket): .url(Self.url(ticket.url))
        case .claudeWaiting(let session), .claudeFinished(let session): .session(pid: session.pid)
        }
    }

    private static func url(_ string: String) -> URL {
        URL(string: string) ?? URL(string: "about:blank")!
    }
}

/// Decides which notifications a new snapshot warrants. Purely content/ID based, so a
/// refresh that only changes timestamps yields nothing.
public enum ChangeDetector {
    public static func events(
        old: Snapshot?, new: Snapshot, myGitHubLogin: String?, myJiraAccountId: String?,
        settings: AppSettings, seen: inout SeenState
    ) -> [NotificationEvent] {
        var events: [NotificationEvent] = []
        events += github(new, login: myGitHubLogin, seen: &seen)
        events += jira(new, accountId: myJiraAccountId, seen: &seen)
        events += claude(old: old, new: new, seen: &seen)

        // Sources that are off or not configured start from a fresh baseline when they come back.
        for (source, status) in [(Source.github, new.sources.github), (.jira, new.sources.jira),
                                 (.claude, new.sources.claude)]
        where status.state == .disabled || status.state == .unconfigured {
            seen.baselined.remove(source)
        }
        return events.filter { event in
            settings.notificationsEnabled[event.trigger.source] ?? true
                && settings.triggers[event.trigger] ?? event.trigger.defaultEnabled
        }
    }

    /// Slack for clock skew between GitHub/Jira and this machine.
    private static let slack: TimeInterval = 600

    /// A comment older than the previous successful fetch belongs to a PR/ticket that only
    /// just entered the result (new assignment, reopened, ...), not to something new.
    private static func isFresh(_ comment: Comment, since lastChecked: Date?) -> Bool {
        guard let lastChecked else { return true }
        return comment.createdAt > lastChecked.addingTimeInterval(-slack)
    }

    // MARK: GitHub

    private static func github(_ new: Snapshot, login: String?, seen: inout SeenState) -> [NotificationEvent] {
        // Without a known login our own comments could not be told apart, so stay silent.
        guard new.sources.github.state == .ok, let login else { return [] }
        let baseline = !seen.baselined.contains(.github)
        let lastChecked = seen.lastChecked[.github]
        var events: [NotificationEvent] = []

        var requestKeys: Set<String> = []
        for pr in new.reviewRequests {
            let key = pr.id + (pr.requestedDirectly ? ":direct" : ":team")
            requestKeys.insert(key)
            if seen.reviewRequests.insert(key).inserted, !baseline {
                events.append(.reviewRequested(pr, direct: pr.requestedDirectly))
            }
        }
        var commentKeys: Set<String> = []
        var ciKeys: Set<String> = []
        for pr in new.myPullRequests {
            for comment in pr.recentComments {
                let key = "github:" + comment.id
                commentKeys.insert(key)
                if seen.comments.insert(key).inserted, !baseline, comment.author != login, isFresh(comment, since: lastChecked) {
                    events.append(.prComment(pr, comment))
                }
            }
            if [.success, .failure, .error].contains(pr.checks) {
                let key = "\(pr.id)@\(pr.headOid):\(pr.checks.rawValue)"
                ciKeys.insert(key)
                if seen.ciNotified.insert(key).inserted, !baseline {
                    events.append(.ciFinished(pr, pr.checks))
                }
            }
        }
        seen.reviewRequests = seen.reviewRequests.intersection(requestKeys)
        seen.comments = seen.comments.filter { !$0.hasPrefix("github:") || commentKeys.contains($0) }
        // Keep CI keys of every state for PRs still open at that head, so flapping does not re-notify.
        let heads = Set((new.myPullRequests).map { "\($0.id)@\($0.headOid):" })
        seen.ciNotified = seen.ciNotified.filter { key in heads.contains { key.hasPrefix($0) } }
        seen.baselined.insert(.github)
        seen.lastChecked[.github] = new.sources.github.lastSuccess ?? new.generatedAt
        return events
    }

    // MARK: Jira

    private static func jira(_ new: Snapshot, accountId: String?, seen: inout SeenState) -> [NotificationEvent] {
        guard new.sources.jira.state == .ok, let accountId else { return [] }
        let baseline = !seen.baselined.contains(.jira)
        let lastChecked = seen.lastChecked[.jira]
        var events: [NotificationEvent] = []
        var commentKeys: Set<String> = []
        for ticket in new.tickets {
            for comment in ticket.recentComments {
                let key = "jira:" + comment.id
                commentKeys.insert(key)
                if seen.comments.insert(key).inserted, !baseline, comment.author != accountId, isFresh(comment, since: lastChecked) {
                    events.append(.ticketComment(ticket, comment))
                }
            }
        }
        seen.comments = seen.comments.filter { !$0.hasPrefix("jira:") || commentKeys.contains($0) }
        events += created(new, baseline: baseline, seen: &seen)
        seen.baselined.insert(.jira)
        seen.lastChecked[.jira] = new.sources.jira.lastSuccess ?? new.generatedAt
        return events
    }

    /// A ticket I created in a watched status that was not in one before: keyed by ticket and
    /// status, so moving on to another watched status notifies too, and leaving and coming back
    /// notifies again. Silent while the statuses differ from those last seen (the view was just
    /// switched on, or other statuses chosen): what is already there is the baseline.
    /// A failed search changes nothing: its list is the last good one, or none.
    private static func created(_ new: Snapshot, baseline: Bool, seen: inout SeenState) -> [NotificationEvent] {
        guard new.createdTicketsError == nil else { return [] }
        let statuses = new.createdTicketStatuses
        let quiet = baseline || seen.createdTicketStatuses != statuses
        var keys: Set<String> = []
        var events: [NotificationEvent] = []
        for ticket in new.createdTickets {
            let key = "\(ticket.key):\(ticket.status.lowercased())"
            keys.insert(key)
            if !seen.createdTickets.contains(key), !quiet {
                events.append(.createdTicketReachedStatus(ticket))
            }
        }
        seen.createdTickets = keys
        seen.createdTicketStatuses = statuses.isEmpty ? nil : statuses
        return events
    }

    // MARK: Claude

    private static func claude(old: Snapshot?, new: Snapshot, seen: inout SeenState) -> [NotificationEvent] {
        guard new.sources.claude.state == .ok else { return [] }
        defer { seen.baselined.insert(.claude) }
        // No previous snapshot (app launch) or an unreliable one: nothing to compare against.
        guard let old, old.sources.claude.state == .ok else { return [] }
        let before = Dictionary(old.sessions.map { ($0.pid, $0.status) }, uniquingKeysWith: { $1 })
        return new.sessions.compactMap { session in
            guard let previous = before[session.pid] else { return nil }
            switch (previous, session.status) {
            case (.waiting, .waiting): return nil
            case (_, .waiting): return .claudeWaiting(session)
            case (.busy, .idle): return .claudeFinished(session)
            default: return nil
            }
        }
    }
}
