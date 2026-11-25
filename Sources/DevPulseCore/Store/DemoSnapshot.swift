import Foundation

/// A recorded snapshot for the website's screenshots: the app's DEBUG-only
/// `-DevPulseDemoSnapshot <path>` shows it instead of live data. Every date is moved so that
/// `generatedAt` is now, so the ages ("12 min ago") read the same whenever it is shown.
public enum DemoSnapshot {
    /// The answer to `devpulse upgrade` while a demo runs: a demo never updates the app.
    public static let upgradeReport = UpgradeReport(.failed, message: "Not available in demo mode.")

    public static func load(from url: URL, now: Date = Date()) throws -> Snapshot {
        let snapshot = try Snapshot.decoder.decode(Snapshot.self, from: Data(contentsOf: url))
        return snapshot.shifted(by: now.timeIntervalSince(snapshot.generatedAt))
    }
}

extension Snapshot {
    /// The same snapshot with every date moved by `offset` seconds.
    public func shifted(by offset: TimeInterval) -> Snapshot {
        func move(_ date: Date) -> Date { date.addingTimeInterval(offset) }
        func move(_ status: SourceStatus) -> SourceStatus {
            var status = status
            status.lastSuccess = status.lastSuccess.map(move)
            return status
        }
        func move(_ comments: [Comment]) -> [Comment] {
            comments.map { var c = $0; c.createdAt = move(c.createdAt); return c }
        }
        func move(_ pr: PullRequest) -> PullRequest {
            var pr = pr
            pr.updatedAt = move(pr.updatedAt)
            pr.lastCommentAt = pr.lastCommentAt.map(move)
            pr.recentComments = move(pr.recentComments)
            return pr
        }
        func move(_ ticket: Ticket) -> Ticket {
            var ticket = ticket
            ticket.updatedAt = move(ticket.updatedAt)
            ticket.lastCommentAt = ticket.lastCommentAt.map(move)
            ticket.recentComments = move(ticket.recentComments)
            return ticket
        }
        var next = self
        next.generatedAt = move(generatedAt)
        next.sources = Sources(github: move(sources.github), jira: move(sources.jira), claude: move(sources.claude))
        next.myPullRequests = myPullRequests.map(move)
        next.reviewRequests = reviewRequests.map(move)
        next.tickets = tickets.map(move)
        next.linkedTickets = linkedTickets.map(move)
        next.createdTickets = createdTickets.map(move)
        next.sessions = sessions.map { var s = $0; s.updatedAt = move(s.updatedAt); return s }
        return next
    }
}
