import Foundation

/// The launcher's right-hand pane: what the selected result is about. A ticket shows its pull
/// requests and related tickets, a PR its ticket and that ticket's related tickets, a Claude
/// Code session its ticket.
public struct LauncherDetail: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var title: String
        public var items: [LauncherItem]
        /// Jira or GitHub has still to answer for this section.
        public var isLoading: Bool
        /// What to say when there are no rows and nothing is loading.
        public var emptyText: String?
    }

    public var title: String
    public var subtitle: String
    public var sections: [Section]

    /// The rows the keyboard moves through, in order.
    public var items: [LauncherItem] { sections.flatMap(\.items) }
}

extension LauncherResolver {
    /// The most pull requests, and the most related tickets, a detail lists.
    public static let maxDetailRows = 10

    public static func detail(
        for item: LauncherItem, snapshot: Snapshot, settings: AppSettings, lookup: LookupResults
    ) -> LauncherDetail {
        var sections: [LauncherDetail.Section] = []
        // A row that says "Not found" has nothing more to show.
        if isMissing(item.subject, lookup: lookup) {
            return LauncherDetail(title: item.title, subtitle: item.subtitle, sections: [])
        }
        switch item.subject {
        case .ticket(let key)? where !isOn(.github, settings):
            sections += relatedSection(of: ticket(key, snapshot: snapshot, lookup: lookup), snapshot: snapshot, settings: settings)
        case .ticket(let key)?:
            let keys = keys(of: key, snapshot: snapshot, lookup: lookup)
            let unanswered = keys.filter { lookup.pullRequestsForTicket[$0] == nil }
            let unreachable = !unanswered.isEmpty && unanswered.allSatisfy(lookup.unreachableSearches.contains)
            let searching = !repos(snapshot: snapshot, settings: settings).isEmpty && !unanswered.isEmpty && !unreachable
            sections.append(LauncherDetail.Section(
                title: "Pull requests", items: pullRequestRows(for: keys, snapshot: snapshot, lookup: lookup),
                isLoading: searching, emptyText: unreachable ? "GitHub could not be searched" : "No pull requests"))
            sections += relatedSection(of: ticket(key, snapshot: snapshot, lookup: lookup), snapshot: snapshot, settings: settings)
        case .pullRequest(let ref)?:
            sections += ticketSections(
                key: ticketKey(of: ref, snapshot: snapshot, settings: settings, lookup: lookup),
                noKey: "No Jira key in its title or branch", snapshot: snapshot, settings: settings, lookup: lookup)
        case nil:
            if case .session(let pid) = item.target, let session = snapshot.sessions.first(where: { $0.pid == pid }) {
                sections += ticketSections(
                    key: session.jiraKey, noKey: "No Jira key in its folder name",
                    snapshot: snapshot, settings: settings, lookup: lookup)
            }
        }
        return LauncherDetail(title: item.title, subtitle: item.subtitle, sections: sections)
    }

    /// What to ask Jira and GitHub before the detail is complete: a ticket's PRs in the
    /// repositories, or the ticket of a PR or session when it is not known yet.
    public static func detailLookupRequest(
        for item: LauncherItem, snapshot: Snapshot, settings: AppSettings, lookup: LookupResults
    ) -> LookupRequest {
        if isMissing(item.subject, lookup: lookup) { return LookupRequest() }
        let key: String?
        switch item.subject {
        case .ticket(let ticketKey)?:
            let repos = repos(snapshot: snapshot, settings: settings)
            guard isOn(.github, settings), !repos.isEmpty else { return LookupRequest() }
            return LookupRequest(
                pullRequestSearches: keys(of: ticketKey, snapshot: snapshot, lookup: lookup)
                    .map { PullRequestSearch(key: $0, repos: repos) })
        case .pullRequest(let ref)?:
            key = ticketKey(of: ref, snapshot: snapshot, settings: settings, lookup: lookup)
        case nil:
            guard case .session(let pid) = item.target else { return LookupRequest() }
            key = snapshot.sessions.first { $0.pid == pid }?.jiraKey
        }
        guard let key, isOn(.jira, settings), !lookup.missingTickets.contains(key),
              ticket(key, snapshot: snapshot, lookup: lookup) == nil,
              jiraURL(key, snapshot: snapshot, site: settings.jiraSite) != nil
        else { return LookupRequest() }
        return LookupRequest(ticketKeys: [key])
    }

    /// A PR's or a session's ticket, then that ticket's related tickets.
    private static func ticketSections(
        key: String?, noKey: String, snapshot: Snapshot, settings: AppSettings, lookup: LookupResults
    ) -> [LauncherDetail.Section] {
        guard let key else { return [LauncherDetail.Section(title: "Ticket", items: [], isLoading: false, emptyText: noKey)] }
        if lookup.missingTickets.contains(key) {
            return [LauncherDetail.Section(title: "Ticket", items: [], isLoading: false, emptyText: "\(key) is not in Jira")]
        }
        let found = ticket(key, snapshot: snapshot, lookup: lookup)
        guard let row = found.flatMap(item) ?? ticketLink(key, snapshot: snapshot, site: settings.jiraSite) else {
            return [LauncherDetail.Section(
                title: "Ticket", items: [], isLoading: false, emptyText: "\(key) · set up Jira in Settings to see it")]
        }
        let ticketSection = LauncherDetail.Section(
            title: "Ticket", items: [plain(row)],
            isLoading: found == nil && isOn(.jira, settings) && !lookup.unreachableTickets.contains(key), emptyText: nil)
        return [ticketSection] + relatedSection(of: found, snapshot: snapshot, settings: settings)
    }

    /// The related tickets, when there are any.
    private static func relatedSection(of ticket: Ticket?, snapshot: Snapshot, settings: AppSettings) -> [LauncherDetail.Section] {
        guard let ticket else { return [] }
        let rows = ticket.related.prefix(maxDetailRows).compactMap { related in
            jiraURL(related.key, snapshot: snapshot, site: settings.jiraSite).map {
                LauncherItem(
                    title: "\(related.key) \(related.summary)", subtitle: "\(related.relation) · \(related.status)",
                    kind: .ticket, target: .url($0))
            }
        }
        return rows.isEmpty ? [] : [LauncherDetail.Section(title: "Related tickets", items: rows, isLoading: false, emptyText: nil)]
    }

    /// The key asked for, and the ticket's current key when it was moved since.
    private static func keys(of key: String, snapshot: Snapshot, lookup: LookupResults) -> [String] {
        guard let current = ticket(key, snapshot: snapshot, lookup: lookup)?.key, current != key else { return [key] }
        return [key, current]
    }

    /// My PRs and review requests linked to the ticket (under any of its keys), then those
    /// GitHub's search found; each once.
    private static func pullRequestRows(for keys: [String], snapshot: Snapshot, lookup: LookupResults) -> [LauncherItem] {
        let known = knownPullRequests(snapshot).filter { $0.jiraKey.map(keys.contains) ?? false }
        var seen = Set(known.map { PullRequestRef(repo: $0.repo, number: $0.number) })
        let searched = keys.flatMap { lookup.pullRequestsForTicket[$0] ?? [] }.filter { seen.insert($0.ref).inserted }
        let rows = known.compactMap { item($0, snapshot: snapshot) } + searched.compactMap(item)
        return rows.prefix(maxDetailRows).map(plain)
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

    private static func isMissing(_ subject: LauncherItem.Subject?, lookup: LookupResults) -> Bool {
        switch subject {
        case .ticket(let key)?: lookup.missingTickets.contains(key)
        case .pullRequest(let ref)?: lookup.missingPullRequests.contains(ref)
        case nil: false
        }
    }

    /// Detail rows open what they show; they have no detail of their own.
    private static func plain(_ item: LauncherItem) -> LauncherItem {
        var row = item
        row.subject = nil
        return row
    }
}
