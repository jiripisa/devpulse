import Foundation

/// One row of the launcher's result list.
public struct LauncherItem: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    /// What Enter opens.
    public var target: OpenTarget
    /// What ⌘Enter opens (a PR's linked Jira ticket).
    public var secondary: OpenTarget?

    public init(title: String, subtitle: String, target: OpenTarget, secondary: OpenTarget? = nil) {
        self.title = title
        self.subtitle = subtitle
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
        }
        return Array(items.prefix(maxItems))
    }

    // MARK: GitHub

    private static func github(
        repo: String?, number: Int?, text: String, snapshot: Snapshot, settings: AppSettings
    ) -> [LauncherItem] {
        // My PRs first, then the review requests; a PR in both lists shows once.
        var seen = Set<String>()
        let known = (snapshot.myPullRequests + snapshot.reviewRequests).filter { seen.insert($0.id).inserted }
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
            guard let fallback = settings.defaultRepo ?? AppSettings.mostFrequentRepo(snapshot.myPullRequests)
            else { return [] }
            fullRepo = fallback
        }
        if let pr = known.first(where: { $0.repo.lowercased() == fullRepo.lowercased() && $0.number == number }) {
            return item(pr, snapshot: snapshot).map { [$0] } ?? []
        }
        guard let url = URL(string: "https://github.com/\(fullRepo)/pull/\(number)") else { return [] }
        return [LauncherItem(title: "Open \(fullRepo)#\(number)", subtitle: url.absoluteString, target: .url(url))]
    }

    /// A full `owner/name` as typed, or the owner of a known PR in a repo of that name.
    private static func resolveRepo(_ typed: String, known: [PullRequest]) -> String? {
        if typed.contains("/") { return typed }
        return known.first { $0.repo.split(separator: "/").last.map { $0.lowercased() == typed.lowercased() } ?? false }?.repo
    }

    private static func item(_ pr: PullRequest, snapshot: Snapshot) -> LauncherItem? {
        guard let url = URL(string: pr.url) else { return nil }
        return LauncherItem(
            title: "#\(pr.number) \(pr.title)", subtitle: pr.repo, target: .url(url),
            secondary: pr.jiraKey.flatMap { jiraURL($0, snapshot: snapshot, site: nil) }.map { .url($0) })
    }

    // MARK: Jira

    private static func jira(
        key: String?, number: Int?, text: String, snapshot: Snapshot, settings: AppSettings
    ) -> [LauncherItem] {
        let site = settings.jiraSite
        var key = key
        if key == nil, let number {
            guard let project = settings.defaultJiraProject ?? AppSettings.mostFrequentProject(snapshot.tickets)
            else { return [] }
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
        // Not in my list: open it by the site's URL; without a site there is nothing to build.
        guard let url = jiraURL(key, snapshot: snapshot, site: site) else { return [] }
        return [LauncherItem(title: "Open \(key)", subtitle: url.absoluteString, target: .url(url))]
    }

    private static func item(_ ticket: Ticket) -> LauncherItem? {
        URL(string: ticket.url).map {
            LauncherItem(title: "\(ticket.key) \(ticket.summary)", subtitle: ticket.status, target: .url($0))
        }
    }

    /// `<site>/browse/<key>`; the configured site wins over the one the snapshot carries.
    private static func jiraURL(_ key: String, snapshot: Snapshot, site: URL?) -> URL? {
        guard let base = site ?? snapshot.jiraBaseURL.flatMap({ URL(string: $0) }) else { return nil }
        return base.appending(path: "browse/\(key)")
    }
}
