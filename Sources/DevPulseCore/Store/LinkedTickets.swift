import Foundation

/// The PR tickets that are not in my own tickets: fetched with one extra Jira search per
/// refresh, so the PR detail can show their status and related tickets.
enum LinkedTickets {
    /// At most one search's worth (`JiraSource.maxResults`).
    static let limit = 50

    /// The Jira keys of my PRs, then of my review requests, that are not among my tickets: each
    /// once, in that order, at most `limit`.
    static func keys(for snapshot: Snapshot) -> [String] {
        let mine = Set(snapshot.tickets.map(\.key))
        var seen = Set<String>()
        let keys = (snapshot.myPullRequests + snapshot.reviewRequests)
            .compactMap(\.jiraKey)
            .filter { !mine.contains($0) && seen.insert($0).inserted }
        return Array(keys.prefix(limit))
    }
}
