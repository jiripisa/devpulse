import Foundation

/// What a launcher row expands into when the selection rests on it: a ticket's PRs and related
/// tickets, or a PR's ticket and that ticket's related tickets.
extension LauncherResolver {
    /// The most PRs, and the most related tickets, one expanded row shows.
    public static let maxChildren = 10

    /// The rows under an expanded row, indented in the launcher; they do not expand themselves.
    public static func children(
        of subject: LauncherItem.Subject, snapshot: Snapshot, settings: AppSettings, lookup: LookupResults
    ) -> [LauncherItem] {
        let items: [LauncherItem]
        switch subject {
        case .ticket(let key):
            items = pullRequestRows(for: key, snapshot: snapshot, lookup: lookup)
                + relatedRows(of: ticket(key, snapshot: snapshot, lookup: lookup), snapshot: snapshot, settings: settings)
        case .pullRequest(let ref):
            guard let key = ticketKey(of: ref, snapshot: snapshot, settings: settings, lookup: lookup) else { return [] }
            let found = ticket(key, snapshot: snapshot, lookup: lookup)
            let row = found.flatMap(item) ?? ticketLink(key, snapshot: snapshot, site: settings.jiraSite)
            items = (row.map { [$0] } ?? []) + relatedRows(of: found, snapshot: snapshot, settings: settings)
        }
        return items.map { item in
            var child = item
            child.subject = nil
            return child
        }
    }

    /// What to ask Jira and GitHub before an expanded row can show everything: a ticket's PRs
    /// in the repositories, or a PR's ticket when it is not known yet.
    public static func childLookupRequest(
        for subject: LauncherItem.Subject, snapshot: Snapshot, settings: AppSettings, lookup: LookupResults
    ) -> LookupRequest {
        switch subject {
        case .ticket(let key):
            let repos = repos(snapshot: snapshot, settings: settings)
            return repos.isEmpty ? LookupRequest() : LookupRequest(pullRequestSearches: [PullRequestSearch(key: key, repos: repos)])
        case .pullRequest(let ref):
            guard let key = ticketKey(of: ref, snapshot: snapshot, settings: settings, lookup: lookup),
                  ticket(key, snapshot: snapshot, lookup: lookup) == nil,
                  jiraURL(key, snapshot: snapshot, site: settings.jiraSite) != nil
            else { return LookupRequest() }
            return LookupRequest(ticketKeys: [key])
        }
    }

    /// My PRs and review requests linked to the ticket, then those GitHub's search found; each once.
    private static func pullRequestRows(for key: String, snapshot: Snapshot, lookup: LookupResults) -> [LauncherItem] {
        let known = knownPullRequests(snapshot).filter { $0.jiraKey == key }
        let knownRefs = Set(known.map { PullRequestRef(repo: $0.repo, number: $0.number) })
        let searched = (lookup.pullRequestsForTicket[key] ?? []).filter { !knownRefs.contains($0.ref) }
        let rows = known.compactMap { item($0, snapshot: snapshot) } + searched.compactMap(item)
        return Array(rows.prefix(maxChildren))
    }

    private static func relatedRows(of ticket: Ticket?, snapshot: Snapshot, settings: AppSettings) -> [LauncherItem] {
        guard let ticket else { return [] }
        return ticket.related.prefix(maxChildren).compactMap { related in
            jiraURL(related.key, snapshot: snapshot, site: settings.jiraSite).map {
                LauncherItem(
                    title: "\(related.key) \(related.summary)", subtitle: "\(related.relation) · \(related.status)",
                    kind: .ticket, target: .url($0))
            }
        }
    }

    /// The ticket with this key: mine, a PR's, or one the lookup found (possibly under its new
    /// key after a move).
    private static func ticket(_ key: String, snapshot: Snapshot, lookup: LookupResults) -> Ticket? {
        knownTickets(snapshot).first { $0.key == key } ?? lookup.tickets[key] ?? lookup.tickets.values.first { $0.key == key }
    }

    /// A PR's Jira key: as the store linked it for my PRs, else from the looked-up title or branch.
    private static func ticketKey(
        of ref: PullRequestRef, snapshot: Snapshot, settings: AppSettings, lookup: LookupResults
    ) -> String? {
        if let known = knownPullRequests(snapshot).first(where: { PullRequestRef(repo: $0.repo, number: $0.number) == ref }) {
            return known.jiraKey
        }
        let summary = lookup.pullRequests[ref]
            ?? lookup.pullRequestsForTicket.values.lazy.flatMap { $0 }.first { $0.ref == ref }
        return summary?.jiraKey(knownProjects: Set(projects(snapshot: snapshot, settings: settings)))
    }
}

/// One line of the launcher's list: a result, or (indented) a child of the expanded result.
public struct LauncherRow: Equatable, Sendable {
    public var item: LauncherItem
    /// 0 for a result, 1 for a child.
    public var depth: Int
    /// Stable while rows come and go: what the row opens, and for a child its parent's too.
    public var id: String
}

public enum LauncherRows {
    /// The results with the children right under the first result whose subject is `expanded`.
    public static func build(
        _ items: [LauncherItem], expanded: LauncherItem.Subject?, children: [LauncherItem]
    ) -> [LauncherRow] {
        var rows: [LauncherRow] = []
        var seen = Set<String>()
        /// The same thing twice (a ticket both blocking and related) still gets its own id.
        func unique(_ id: String) -> String {
            var candidate = id
            var n = 1
            while !seen.insert(candidate).inserted {
                n += 1
                candidate = "\(id)#\(n)"
            }
            return candidate
        }
        var placed = false
        for item in items {
            let id = unique(key(item.target))
            rows.append(LauncherRow(item: item, depth: 0, id: id))
            if !placed, let expanded, item.subject == expanded {
                placed = true
                rows += children.map { LauncherRow(item: $0, depth: 1, id: unique("\(id)>\(key($0.target))")) }
            }
        }
        return rows
    }

    /// The subject of the result a row belongs to: its own, or its parent's for a child.
    public static func topSubject(at index: Int, in rows: [LauncherRow]) -> LauncherItem.Subject? {
        guard rows.indices.contains(index) else { return nil }
        return rows[...index].last { $0.depth == 0 }?.item.subject
    }

    private static func key(_ target: OpenTarget) -> String {
        switch target {
        case .url(let url): url.absoluteString
        case .session(let pid): "session:\(pid)"
        }
    }
}
