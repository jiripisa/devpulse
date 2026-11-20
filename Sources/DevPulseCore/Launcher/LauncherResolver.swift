import Foundation

/// One row of the launcher's result list.
public struct LauncherItem: Equatable, Sendable {
    /// What the row is, for its icon: a bare number mixes all kinds in one list.
    public enum Kind: Equatable, Sendable {
        case pullRequest
        case reviewRequest(direct: Bool)
        case ticket
        case session(SessionStatus)
    }

    public var title: String
    public var subtitle: String
    public var kind: Kind
    /// What Enter opens.
    public var target: OpenTarget
    /// What ⌘Enter opens (a PR's linked Jira ticket).
    public var secondary: OpenTarget?

    public init(title: String, subtitle: String, kind: Kind, target: OpenTarget, secondary: OpenTarget? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.target = target
        self.secondary = secondary
    }
}

/// Turns a parsed launcher query into the rows to show, from the snapshot and the settings.
public enum LauncherResolver {
    public static let maxItems = 20

    public static func items(for query: LauncherQuery, snapshot: Snapshot, settings: AppSettings) -> [LauncherItem] {
        let items: [LauncherItem]
        switch query {
        case .empty:
            items = []
        case .github(let repo, let number, let text):
            items = github(repo: repo, number: number, text: text, snapshot: snapshot, settings: settings)
        case .jira(let key, let number, let text):
            items = jira(key: key, number: number, text: text, snapshot: snapshot, settings: settings)
        case .number(let number):
            items = everything(number: number, snapshot: snapshot, settings: settings)
        }
        return Array(items.prefix(maxItems))
    }

    // MARK: GitHub

    private static func github(
        repo: String?, number: Int?, text: String, snapshot: Snapshot, settings: AppSettings
    ) -> [LauncherItem] {
        let known = knownPullRequests(snapshot)
        guard let number else {
            let needle = text.lowercased()
            return known
                .filter { needle.isEmpty || $0.title.lowercased().contains(needle) || $0.repo.lowercased().contains(needle) }
                .compactMap { item($0, snapshot: snapshot) }
        }
        let fullRepo: String
        if let repo {
            guard let resolved = resolveRepo(repo, known: known) else { return [] }
            fullRepo = resolved
        } else {
            let matches = known.filter { $0.number == number }
            if !matches.isEmpty { return matches.compactMap { item($0, snapshot: snapshot) } }
            guard let fallback = defaultRepo(snapshot: snapshot, settings: settings) else { return [] }
            fullRepo = fallback
        }
        if let pr = known.first(where: { $0.repo.lowercased() == fullRepo.lowercased() && $0.number == number }) {
            return item(pr, snapshot: snapshot).map { [$0] } ?? []
        }
        return pullRequestLink(repo: fullRepo, number: number).map { [$0] } ?? []
    }

    /// My PRs first, then the review requests; a PR in both lists shows once, as mine.
    private static func knownPullRequests(_ snapshot: Snapshot) -> [PullRequest] {
        var seen = Set<String>()
        return (snapshot.myPullRequests + snapshot.reviewRequests).filter { seen.insert($0.id).inserted }
    }

    /// The configured default repository, else the one most of my PRs are in.
    private static func defaultRepo(snapshot: Snapshot, settings: AppSettings) -> String? {
        settings.defaultRepo ?? AppSettings.mostFrequentRepo(snapshot.myPullRequests)
    }

    /// A row that opens a PR by number, for one not in my lists.
    private static func pullRequestLink(repo: String, number: Int) -> LauncherItem? {
        guard let url = URL(string: "https://github.com/\(repo)/pull/\(number)") else { return nil }
        return LauncherItem(
            title: "Open \(repo)#\(number)", subtitle: url.absoluteString, kind: .pullRequest, target: .url(url))
    }

    /// A full `owner/name` as typed, or the owner of a known PR in a repo of that name.
    private static func resolveRepo(_ typed: String, known: [PullRequest]) -> String? {
        if typed.contains("/") { return typed }
        return known.first { $0.repo.split(separator: "/").last.map { $0.lowercased() == typed.lowercased() } ?? false }?.repo
    }

    private static func item(_ pr: PullRequest, snapshot: Snapshot) -> LauncherItem? {
        guard let url = URL(string: pr.url) else { return nil }
        let isMine = snapshot.myPullRequests.contains { $0.id == pr.id }
        return LauncherItem(
            title: "#\(pr.number) \(pr.title)", subtitle: pr.repo,
            kind: isMine ? .pullRequest : .reviewRequest(direct: pr.requestedDirectly), target: .url(url),
            secondary: pr.jiraKey.flatMap { jiraURL($0, snapshot: snapshot, site: nil) }.map { .url($0) })
    }

    // MARK: Jira

    private static func jira(
        key: String?, number: Int?, text: String, snapshot: Snapshot, settings: AppSettings
    ) -> [LauncherItem] {
        let site = settings.jiraSite
        var key = key
        if key == nil, let number {
            guard let project = defaultProject(snapshot: snapshot, settings: settings) else { return [] }
            key = "\(project)-\(number)"
        }
        guard let key else {
            let needle = text.lowercased()
            return snapshot.tickets
                .filter { needle.isEmpty || $0.summary.lowercased().contains(needle) || $0.key.lowercased().contains(needle) }
                .compactMap(item)
        }
        if let ticket = snapshot.tickets.first(where: { $0.key == key }) {
            return item(ticket).map { [$0] } ?? []
        }
        return ticketLink(key, snapshot: snapshot, site: site).map { [$0] } ?? []
    }

    /// The configured default project, else the one most of my tickets are in.
    private static func defaultProject(snapshot: Snapshot, settings: AppSettings) -> String? {
        settings.defaultJiraProject ?? AppSettings.mostFrequentProject(snapshot.tickets)
    }

    /// A row that opens a ticket not in my list by the site's URL; without a site there is
    /// nothing to build.
    private static func ticketLink(_ key: String, snapshot: Snapshot, site: URL?) -> LauncherItem? {
        guard let url = jiraURL(key, snapshot: snapshot, site: site) else { return nil }
        return LauncherItem(title: "Open \(key)", subtitle: url.absoluteString, kind: .ticket, target: .url(url))
    }

    private static func item(_ ticket: Ticket) -> LauncherItem? {
        URL(string: ticket.url).map {
            LauncherItem(title: "\(ticket.key) \(ticket.summary)", subtitle: ticket.status, kind: .ticket, target: .url($0))
        }
    }

    /// `<site>/browse/<key>`; the configured site wins over the one the snapshot carries.
    private static func jiraURL(_ key: String, snapshot: Snapshot, site: URL?) -> URL? {
        guard let base = site ?? snapshot.jiraBaseURL.flatMap({ URL(string: $0) }) else { return nil }
        return base.appending(path: "browse/\(key)")
    }

    // MARK: Bare number

    /// Everything the number can be: my PRs and review requests with that number in any repo,
    /// my tickets with that issue number in any project, the Claude Code sessions whose Jira key
    /// or folder has it, then a row for the default repo's PR and the default project's ticket
    /// when the rows above do not already show them.
    private static func everything(number: Int, snapshot: Snapshot, settings: AppSettings) -> [LauncherItem] {
        let prs = knownPullRequests(snapshot).filter { $0.number == number }
        let tickets = snapshot.tickets.filter { issueNumber(of: $0.key) == number }
        let sessions = snapshot.sessions.filter { session in
            session.jiraKey.flatMap(issueNumber) == number || folderNumbers(session.cwd).contains(number)
        }
        var items = prs.compactMap { item($0, snapshot: snapshot) }
            + tickets.compactMap(item)
            + sessions.map(item)
        if let repo = defaultRepo(snapshot: snapshot, settings: settings),
           !prs.contains(where: { $0.repo.lowercased() == repo.lowercased() }),
           let link = pullRequestLink(repo: repo, number: number) {
            items.append(link)
        }
        if let project = defaultProject(snapshot: snapshot, settings: settings) {
            let key = "\(project)-\(number)"
            if !tickets.contains(where: { $0.key == key }),
               let link = ticketLink(key, snapshot: snapshot, site: settings.jiraSite) {
                items.append(link)
            }
        }
        return items
    }

    /// `2474` of `STORE-2474`.
    private static func issueNumber(of key: String) -> Int? {
        key.lastIndex(of: "-").flatMap { Int(key[key.index(after: $0)...]) }
    }

    /// The whole numbers in the folder's own name: `store-2474-fix` has 2474, never 247.
    private static func folderNumbers(_ cwd: String) -> [Int] {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.matches(of: /\d+/).compactMap { Int($0.output) }
    }

    private static func item(_ session: ClaudeSession) -> LauncherItem {
        let cwd = (session.cwd as NSString).abbreviatingWithTildeInPath
        return LauncherItem(
            title: [session.name, session.jiraKey].compactMap { $0 }.joined(separator: " "),
            subtitle: "Claude Code session · \(session.stateText) · \(cwd)",
            kind: .session(session.status), target: .session(pid: session.pid))
    }
}
