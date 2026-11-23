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

    /// The ticket or PR a row shows, which the launcher can expand into its PRs, its ticket and
    /// related tickets.
    public enum Subject: Hashable, Sendable {
        case ticket(String)
        case pullRequest(PullRequestRef)
    }

    public var title: String
    public var subtitle: String
    public var kind: Kind
    /// What Enter opens.
    public var target: OpenTarget
    /// What ⌘Enter opens (a PR's linked Jira ticket).
    public var secondary: OpenTarget?
    /// The ticket or PR the row shows, whose detail the launcher can show; nil for sessions and
    /// for the detail's own rows.
    public var subject: Subject?

    // How the row reads in the launcher: a line with the kind and its identifier, the name
    // under it, and the status on the right; `title` and `subtitle` say the same in one string
    // each (help text, VoiceOver, tests).

    /// `acme/store #812 · STORE-2474`, `STORE-2474`.
    public var identifier: String?
    /// The same, short enough for the result list: `store #812 · STORE-2474`.
    public var compactIdentifier: String?
    /// The PR's or ticket's title, the session's name.
    public var name: String?
    /// A small line above, e.g. how a related ticket relates: "Is blocked by".
    public var caption: String?
    public var badges: [StatusBadge]

    public init(
        title: String, subtitle: String, kind: Kind, target: OpenTarget, secondary: OpenTarget? = nil,
        subject: Subject? = nil, identifier: String? = nil, compactIdentifier: String? = nil, name: String? = nil,
        caption: String? = nil, badges: [StatusBadge] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.target = target
        self.secondary = secondary
        self.subject = subject
        self.identifier = identifier
        self.compactIdentifier = compactIdentifier ?? identifier
        self.name = name
        self.caption = caption
        self.badges = badges
    }

    /// What Enter does with the row, for the launcher's key line.
    public var openLabel: String {
        switch target {
        case .session: "Open in Ghostty"
        case .url(let url): url.host()?.hasSuffix("github.com") == true ? "Open on GitHub" : "Open in Jira"
        }
    }
}

/// Turns a parsed launcher query into the rows to show, from the snapshot, the settings and
/// what `LauncherLookup` found about the rows the snapshot does not know.
public enum LauncherResolver {
    public static let maxItems = 20

    public static func items(
        for query: LauncherQuery, snapshot: Snapshot, settings: AppSettings, lookup: LookupResults = LookupResults()
    ) -> [LauncherItem] {
        let site = settings.jiraSite
        let items = rows(for: query, snapshot: snapshot, settings: settings).compactMap { row -> LauncherItem? in
            switch row {
            case .item(let item):
                return item
            case .ticket(let key, let typed):
                if let ticket = lookup.tickets[key] {
                    // A moved ticket shows its new key but keeps the one asked for, whose PRs
                    // still carry it, and says so.
                    var found = item(ticket)
                    found?.subject = .ticket(key)
                    if ticket.key != key { found?.subtitle = "Moved from \(key) · \(ticket.status)" }
                    return found
                }
                guard let link = ticketLink(key, snapshot: snapshot, site: site) else { return nil }
                if lookup.unreachableTickets.contains(key) { return notFound(link, "Jira could not be reached") }
                // A guess (a bare number in each project) shows only once Jira confirms it, so
                // the list never shows rows that then vanish; what was typed shows at once.
                guard typed else { return nil }
                return lookup.missingTickets.contains(key) ? notFound(link, "Not found in Jira") : link
            case .pullRequest(let ref, let typed):
                if let found = lookup.pullRequests[ref] { return item(found) }
                guard let link = pullRequestLink(repo: ref.repo, number: ref.number) else { return nil }
                if lookup.unreachablePullRequests.contains(ref) { return notFound(link, "GitHub could not be reached") }
                guard typed else { return nil }
                return lookup.missingPullRequests.contains(ref) ? notFound(link, "Not found on GitHub") : link
            }
        }
        return Array(items.prefix(maxItems))
    }

    /// The "Open …" rows of the query that `LauncherLookup` can give a title: only those it
    /// could also open (a ticket needs the Jira site).
    public static func lookupRequest(for query: LauncherQuery, snapshot: Snapshot, settings: AppSettings) -> LookupRequest {
        var request = LookupRequest()
        for row in rows(for: query, snapshot: snapshot, settings: settings) {
            switch row {
            case .item: break
            // A switched-off source is never asked.
            case .ticket(let key, _):
                if isOn(.jira, settings), jiraURL(key, snapshot: snapshot, site: settings.jiraSite) != nil {
                    request.ticketKeys.append(key)
                }
            case .pullRequest(let ref, _):
                if isOn(.github, settings) { request.pullRequests.append(ref) }
            }
        }
        return request
    }

    static func isOn(_ source: Source, _ settings: AppSettings) -> Bool {
        settings.sourceEnabled[source] ?? true
    }

    /// A planned row: one the snapshot knows, or a ticket or PR it does not, shown by what the
    /// lookup found. `typed` rows are what the query names outright (`jira WA-9`, `gh 9`): they
    /// show at once and stay when they do not exist, saying so; the guesses of a bare number
    /// show only once found.
    private enum Row {
        case item(LauncherItem)
        case ticket(key: String, typed: Bool)
        case pullRequest(PullRequestRef, typed: Bool)
    }

    private static func rows(for query: LauncherQuery, snapshot: Snapshot, settings: AppSettings) -> [Row] {
        switch query {
        case .empty:
            []
        case .github(let repo, let number, let text):
            github(repo: repo, number: number, text: text, snapshot: snapshot, settings: settings)
        case .jira(let key, let number, let text):
            jira(key: key, number: number, text: text, snapshot: snapshot, settings: settings)
        case .number(let number):
            everything(number: number, snapshot: snapshot, settings: settings)
        }
    }

    private static func notFound(_ link: LauncherItem, _ text: String) -> LauncherItem {
        var item = link
        item.subtitle = text
        item.badges = [StatusBadge(text: text, glyph: .exclamation, tone: .secondary)]
        return item
    }

    // MARK: GitHub

    private static func github(
        repo: String?, number: Int?, text: String, snapshot: Snapshot, settings: AppSettings
    ) -> [Row] {
        let known = knownPullRequests(snapshot)
        guard let number else {
            let needle = text.lowercased()
            return known
                .filter { needle.isEmpty || $0.title.lowercased().contains(needle) || $0.repo.lowercased().contains(needle) }
                .compactMap { item($0, snapshot: snapshot) }
                .map(Row.item)
        }
        if let repo {
            guard let fullRepo = resolveRepo(repo, known: known, configured: repos(snapshot: snapshot, settings: settings))
            else { return [] }
            if let pr = known.first(where: { $0.repo.lowercased() == fullRepo.lowercased() && $0.number == number }) {
                return item(pr, snapshot: snapshot).map { [.item($0)] } ?? []
            }
            return [.pullRequest(PullRequestRef(repo: fullRepo, number: number), typed: true)]
        }
        // Every repository, the first one typed: it stays when the PR does not exist.
        let (prs, refs) = pullRequests(number: number, snapshot: snapshot, settings: settings)
        let first = repos(snapshot: snapshot, settings: settings).first.map { PullRequestRef(repo: $0, number: number) }
        return prs.compactMap { item($0, snapshot: snapshot) }.map(Row.item) + refs.map { .pullRequest($0, typed: $0 == first) }
    }

    /// My PRs first, then the review requests; a PR in both lists shows once, as mine.
    /// `store #9` for `acme/store`, number 9.
    static func compact(repo: String, number: Int) -> String {
        "\(repo.split(separator: "/").last.map(String.init) ?? repo) #\(number)"
    }

    static func knownPullRequests(_ snapshot: Snapshot) -> [PullRequest] {
        var seen = Set<String>()
        return (snapshot.myPullRequests + snapshot.reviewRequests).filter { seen.insert($0.id).inserted }
    }

    /// The configured repositories, else those of my PRs, most PRs first.
    static func repos(snapshot: Snapshot, settings: AppSettings) -> [String] {
        settings.githubRepos.isEmpty ? AppSettings.reposByFrequency(snapshot.myPullRequests) : settings.githubRepos
    }

    /// My PRs and review requests with this number in any repo, and the repositories' PRs with
    /// it that are not among them.
    private static func pullRequests(
        number: Int, snapshot: Snapshot, settings: AppSettings
    ) -> ([PullRequest], [PullRequestRef]) {
        let known = knownPullRequests(snapshot).filter { $0.number == number }
        let refs = repos(snapshot: snapshot, settings: settings)
            .map { PullRequestRef(repo: $0, number: number) }
            .filter { ref in !known.contains { PullRequestRef(repo: $0.repo, number: $0.number) == ref } }
        return (known, refs)
    }

    /// A row that opens a PR by number, for one not in my lists.
    private static func pullRequestLink(repo: String, number: Int) -> LauncherItem? {
        guard let url = URL(string: "https://github.com/\(repo)/pull/\(number)") else { return nil }
        return LauncherItem(
            title: "Open \(repo)#\(number)", subtitle: url.absoluteString, kind: .pullRequest, target: .url(url),
            subject: .pullRequest(PullRequestRef(repo: repo, number: number)),
            identifier: "\(repo) #\(number)", compactIdentifier: Self.compact(repo: repo, number: number),
            name: "Open on GitHub")
    }

    /// A full `owner/name` as typed, or the configured repository or the repo of a known PR
    /// with that name.
    private static func resolveRepo(_ typed: String, known: [PullRequest], configured: [String]) -> String? {
        if typed.contains("/") { return typed }
        func named(_ repo: String) -> Bool {
            repo.split(separator: "/").last.map { $0.lowercased() == typed.lowercased() } ?? false
        }
        return configured.first(where: named) ?? known.map(\.repo).first(where: named)
    }

    static func item(_ pr: PullRequest, snapshot: Snapshot) -> LauncherItem? {
        guard let url = URL(string: pr.url) else { return nil }
        let isMine = snapshot.myPullRequests.contains { $0.id == pr.id }
        return LauncherItem(
            title: "#\(pr.number) \(pr.title)", subtitle: pr.repo,
            kind: isMine ? .pullRequest : .reviewRequest(direct: pr.requestedDirectly), target: .url(url),
            secondary: pr.jiraKey.flatMap { jiraURL($0, snapshot: snapshot, site: nil) }.map { .url($0) },
            subject: .pullRequest(PullRequestRef(repo: pr.repo, number: pr.number)),
            identifier: (["\(pr.repo) #\(pr.number)"] + [pr.jiraKey].compactMap { $0 }).joined(separator: " · "),
            compactIdentifier: pr.rowIdentifiers.joined(separator: " · "),
            name: pr.title, badges: StatusBadge.pullRequest(pr))
    }


    // MARK: Jira

    private static func jira(
        key: String?, number: Int?, text: String, snapshot: Snapshot, settings: AppSettings
    ) -> [Row] {
        if let number {
            // Every project, the default one (the first) typed: it stays when it does not exist.
            let (known, keys) = tickets(number: number, snapshot: snapshot, settings: settings)
            let first = projects(snapshot: snapshot, settings: settings).first.map { "\($0)-\(number)" }
            return known.compactMap(item).map(Row.item) + keys.map { .ticket(key: $0, typed: $0 == first) }
        }
        guard let key else {
            let needle = text.lowercased()
            return snapshot.tickets
                .filter { needle.isEmpty || $0.summary.lowercased().contains(needle) || $0.key.lowercased().contains(needle) }
                .compactMap(item)
                .map(Row.item)
        }
        if let ticket = knownTickets(snapshot).first(where: { $0.key == key }) {
            return item(ticket).map { [.item($0)] } ?? []
        }
        return [.ticket(key: key, typed: true)]
    }

    /// The configured projects, else those of my tickets, most tickets first.
    static func projects(snapshot: Snapshot, settings: AppSettings) -> [String] {
        settings.jiraProjects.isEmpty ? AppSettings.projectsByFrequency(snapshot.tickets) : settings.jiraProjects
    }

    /// My tickets, then those of PRs that are not mine; each once.
    static func knownTickets(_ snapshot: Snapshot) -> [Ticket] {
        var seen = Set<String>()
        return (snapshot.tickets + snapshot.linkedTickets).filter { seen.insert($0.key).inserted }
    }

    /// The known tickets with this issue number in any project, and the keys of the projects'
    /// tickets with it that are not known.
    private static func tickets(number: Int, snapshot: Snapshot, settings: AppSettings) -> ([Ticket], [String]) {
        let known = knownTickets(snapshot).filter { issueNumber(of: $0.key) == number }
        let keys = projects(snapshot: snapshot, settings: settings)
            .map { "\($0)-\(number)" }
            .filter { key in !known.contains { $0.key == key } }
        return (known, keys)
    }

    /// A row that opens a ticket not in my list by the site's URL; without a site there is
    /// nothing to build.
    static func ticketLink(_ key: String, snapshot: Snapshot, site: URL?) -> LauncherItem? {
        guard let url = jiraURL(key, snapshot: snapshot, site: site) else { return nil }
        return LauncherItem(
            title: "Open \(key)", subtitle: url.absoluteString, kind: .ticket, target: .url(url), subject: .ticket(key),
            identifier: key, name: "Open in Jira")
    }

    /// A PR the lookup found: its title, and its repo and state.
    static func item(_ pr: PullRequestSummary) -> LauncherItem? {
        URL(string: pr.url).map {
            LauncherItem(
                title: "#\(pr.number) \(pr.title)", subtitle: "\(pr.repo) · \(pr.state.text)",
                kind: .pullRequest, target: .url($0), subject: .pullRequest(pr.ref),
                identifier: "\(pr.repo) #\(pr.number)", compactIdentifier: compact(repo: pr.repo, number: pr.number),
                name: pr.title, badges: [StatusBadge.pullRequest(pr.state)])
        }
    }

    static func item(_ ticket: Ticket) -> LauncherItem? {
        URL(string: ticket.url).map {
            LauncherItem(
                title: "\(ticket.key) \(ticket.summary)", subtitle: ticket.status, kind: .ticket, target: .url($0),
                subject: .ticket(ticket.key), identifier: ticket.key, name: ticket.summary,
                badges: [StatusBadge.ticket(status: ticket.status, category: ticket.statusCategory)])
        }
    }

    /// `<site>/browse/<key>`; the configured site wins over the one the snapshot carries.
    static func jiraURL(_ key: String, snapshot: Snapshot, site: URL?) -> URL? {
        guard let base = site ?? snapshot.jiraBaseURL.flatMap({ URL(string: $0) }) else { return nil }
        return base.appending(path: "browse/\(key)")
    }

    // MARK: Bare number

    /// Everything the number can be: my PRs and review requests with that number in any repo,
    /// the known tickets with that issue number in any project, the Claude Code sessions whose
    /// Jira key or folder has it, then each repository's PR and each project's ticket when the
    /// rows above do not already show them.
    private static func everything(number: Int, snapshot: Snapshot, settings: AppSettings) -> [Row] {
        let (prs, refs) = pullRequests(number: number, snapshot: snapshot, settings: settings)
        let (tickets, ticketKeys) = tickets(number: number, snapshot: snapshot, settings: settings)
        let sessions = snapshot.sessions.filter { session in
            session.jiraKey.flatMap(issueNumber) == number || folderNumbers(session.cwd).contains(number)
        }
        let rows = (prs.compactMap { item($0, snapshot: snapshot) } + tickets.compactMap(item) + sessions.map(item))
            .map(Row.item)
        return rows + refs.map { .pullRequest($0, typed: false) } + ticketKeys.map { .ticket(key: $0, typed: false) }
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
            kind: .session(session.status), target: .session(pid: session.pid),
            identifier: session.rowIdentifiers.joined(separator: " · "), name: session.name,
            badges: [StatusBadge.session(session.status)])
    }
}
