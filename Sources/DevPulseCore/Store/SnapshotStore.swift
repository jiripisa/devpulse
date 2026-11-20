import Foundation

public protocol GitHubFetching: Sendable {
    func fetch(includeTeamRequests: Bool) async throws -> GitHubResult
}

public protocol JiraFetching: Sendable {
    func fetch() async throws -> JiraResult
    /// The tickets with these keys, whoever they are assigned to, in one search.
    func fetchTickets(keys: [String]) async throws -> [Ticket]
}

/// The Claude Code session watcher. The store never scans the session files itself: the
/// watcher's reports are the only session data.
public protocol ClaudeSessionProviding: Sendable {
    func start(onChange: @escaping @Sendable ([ClaudeSession]) -> Void)
    func stop()
}

extension GitHubSource: GitHubFetching {}
extension JiraSource: JiraFetching {}
extension ClaudeSessionSource: ClaudeSessionProviding {}

/// The single source of truth: combines GitHub, Jira and Claude Code data into one `Snapshot`.
/// A failing source keeps its previous data and only changes its status. The app shell drives the
/// refresh loop (see `RefreshPolicy`).
@MainActor
public final class SnapshotStore {
    public private(set) var snapshot: Snapshot
    /// Set from the last successful GitHub / Jira fetch; used to recognize my own comments.
    public private(set) var githubLogin: String?
    public private(set) var jiraAccountId: String?
    public private(set) var isPaused = false
    public private(set) var lastAttempt: Date?
    public var settings: AppSettings
    /// Called with the old and the new snapshot, only when they differ. Timestamps count
    /// (`lastSuccess`), so every successful refresh fires; `generatedAt` alone never does.
    public var onChange: ((Snapshot, Snapshot) -> Void)?

    private var inFlight: Set<Source> = []
    private let github: any GitHubFetching
    private let jiraFactory: @Sendable (JiraCredentials) -> any JiraFetching
    /// Kept between refreshes, so the source's own cache (the account ID) lasts; rebuilt only
    /// when the site, e-mail or token change.
    private var jira: (credentials: JiraCredentials, source: any JiraFetching)?
    /// The watcher's last report, kept while Claude Code is switched off so switching it back
    /// on shows the sessions at once. Nil until the first report.
    private var watchedSessions: [ClaudeSession]?
    private let claude: any ClaudeSessionProviding
    private let jiraCredentials: () -> JiraCredentials?
    private let now: @Sendable () -> Date

    public init(
        github: any GitHubFetching,
        jiraFactory: @escaping @Sendable (JiraCredentials) -> any JiraFetching,
        claude: any ClaudeSessionProviding,
        jiraCredentials: @escaping () -> JiraCredentials?,
        settings: AppSettings = AppSettings(),
        appVersion: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.github = github
        self.jiraFactory = jiraFactory
        self.claude = claude
        self.jiraCredentials = jiraCredentials
        self.settings = settings
        self.now = now
        let fetching = SourceStatus(state: .fetching)
        // No refresh includes Claude Code (the watcher owns it, and its reports are dropped while
        // it is off), so a switched-off Claude starts as off; GitHub and Jira learn it on the
        // first fetch.
        let claudeOn = settings.sourceEnabled[.claude] ?? true
        snapshot = Snapshot(
            appVersion: appVersion, generatedAt: now(),
            sources: Sources(
                github: fetching, jira: fetching,
                claude: claudeOn ? fetching : SourceStatus(state: .disabled)),
            myPullRequests: [], reviewRequests: [], tickets: [], sessions: [])
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    public func shouldRefresh(policy: RefreshPolicy = RefreshPolicy()) -> Bool {
        policy.shouldFetch(now: now(), lastAttempt: lastAttempt, interval: settings.refreshInterval, paused: isPaused)
    }

    /// Fetches the given sources (GitHub and Jira concurrently) and publishes one combined update.
    /// A source that is already being fetched is skipped, so overlapping calls never fetch twice
    /// and results never apply out of order.
    public func refresh(_ requested: Set<Source>) async {
        let sources = requested.subtracting(inFlight)
        guard !sources.isEmpty else { return }
        let moment = now()
        lastAttempt = moment
        let includeTeam = settings.includeTeamReviewRequests
        let runGitHub = sources.contains(.github) && isEnabled(.github)
        let runJira = sources.contains(.jira) && isEnabled(.jira)
        // A switched-off Jira does not touch the Keychain; its site comes from the settings.
        let credentials = runJira ? jiraCredentials() : nil
        var fetched = Set<Source>()
        if runGitHub { fetched.insert(.github) }
        if runJira && credentials != nil { fetched.insert(.jira) }
        inFlight.formUnion(fetched)
        let jiraSource = credentials.map(jiraSource(for:))
        let github = self.github

        async let githubOutcome = fetchGitHub(github, includeTeam: includeTeam, run: runGitHub)
        async let jiraOutcome = fetchJira(jiraSource, run: runJira)
        let (githubResult, jiraResult) = await (githubOutcome, jiraOutcome)
        let results = Results(github: githubResult, jira: jiraResult, credentials: credentials, moment: moment)

        // The tickets of PRs that are not mine: one more search, which needs both results.
        var linkedResult: Result<[Ticket], any Error>?
        if runJira, let jiraSource {
            let keys = LinkedTickets.keys(for: merged(results, for: sources, into: snapshot))
            linkedResult = keys.isEmpty ? .success([]) : await fetchLinked(jiraSource, keys: keys)
        }
        inFlight.subtract(fetched)

        // Built on the snapshot as it is now, so Claude Code reports that came in meanwhile stay.
        var next = merged(results, for: sources, into: snapshot)
        if case .success(let result)? = githubResult { githubLogin = result.viewerLogin }
        if case .success(let result)? = jiraResult { jiraAccountId = result.myAccountId }
        if sources.contains(.jira) {
            if !isEnabled(.jira) || credentials == nil {
                next.linkedTickets = []
            } else if case .success(let tickets)? = linkedResult {
                next.linkedTickets = tickets
            }
            // A failed search keeps the last linked tickets and leaves the Jira state alone: they
            // are extra detail, and my own tickets came through.
        }

        // Only applies the switch: the sessions are the watcher's, never a new scan.
        if sources.contains(.claude) {
            if isEnabled(.claude) {
                if let watchedSessions, next.sources.claude.state != .ok {
                    next.sessions = watchedSessions
                    next.sources.claude = SourceStatus(state: .ok, lastSuccess: moment)
                }
            } else {
                next.sources.claude = SourceStatus(state: .disabled, lastSuccess: next.sources.claude.lastSuccess)
                next.sessions = []
            }
        }

        publish(next)
    }

    /// What one refresh fetched from GitHub and Jira.
    private struct Results {
        var github: Result<GitHubResult, any Error>?
        var jira: Result<JiraResult, any Error>?
        var credentials: JiraCredentials?
        var moment: Date
    }

    /// `base` with the GitHub and Jira results of a refresh of `sources` applied and the PRs
    /// linked to their tickets. A failing source keeps its data and only changes its status.
    private func merged(_ results: Results, for sources: Set<Source>, into base: Snapshot) -> Snapshot {
        var next = base
        let moment = results.moment
        let site = results.credentials?.site.absoluteString
        let githubResult = results.github, jiraResult = results.jira, credentials = results.credentials

        if sources.contains(.github) {
            if !isEnabled(.github) {
                next.sources.github = SourceStatus(state: .disabled, lastSuccess: next.sources.github.lastSuccess)
                next.myPullRequests = []
                next.reviewRequests = []
            } else if let githubResult {
                switch githubResult {
                case .success(let result):
                    next.myPullRequests = result.mine
                    next.reviewRequests = result.reviewRequests
                    next.sources.github = SourceStatus(
                        state: .ok, lastSuccess: moment,
                        message: result.warnings.isEmpty ? nil : result.warnings.joined(separator: "; "))
                case .failure(let error):
                    next.sources.github.state = .error
                    next.sources.github.message = SourceErrorMessage.text(for: error)
                }
            }
        }

        if sources.contains(.jira) {
            if !isEnabled(.jira) {
                next.sources.jira = SourceStatus(state: .disabled, lastSuccess: next.sources.jira.lastSuccess)
                next.tickets = []
                next.jiraBaseURL = settings.jiraSite?.absoluteString
            } else if credentials == nil {
                next.sources.jira = SourceStatus(state: .unconfigured, lastSuccess: next.sources.jira.lastSuccess)
                next.tickets = []
                next.jiraBaseURL = nil
            } else if let jiraResult {
                next.jiraBaseURL = site
                switch jiraResult {
                case .success(let result):
                    next.tickets = result.tickets
                    next.sources.jira = SourceStatus(state: .ok, lastSuccess: moment)
                case .failure(let error):
                    next.sources.jira.state = .error
                    next.sources.jira.message = SourceErrorMessage.text(for: error)
                }
            }
        }

        if sources.contains(.github) || sources.contains(.jira) {
            linkTickets(&next)
        }
        return next
    }

    /// Starts taking Claude Code session changes straight into the snapshot.
    public func startWatchingClaude() {
        claude.start { [weak self] sessions in
            Task { @MainActor in self?.applyClaude(sessions) }
        }
    }

    public func stopWatchingClaude() {
        claude.stop()
    }

    private func applyClaude(_ sessions: [ClaudeSession]) {
        watchedSessions = sessions
        guard isEnabled(.claude) else { return }
        var next = snapshot
        next.sessions = sessions
        next.sources.claude = SourceStatus(state: .ok, lastSuccess: now())
        publish(next)
    }

    /// Links each PR to a key of a project I have tickets in, or of the default project, when
    /// its title or branch has one; otherwise the first key, as GitHub mapped it.
    private func linkTickets(_ snapshot: inout Snapshot) {
        var known = Set(snapshot.tickets.map { JiraKey.project(of: $0.key) })
        if let project = settings.defaultJiraProject, !project.isEmpty { known.insert(project) }
        guard !known.isEmpty else { return }
        func link(_ prs: inout [PullRequest]) {
            for i in prs.indices {
                prs[i].jiraKey = JiraKey.find(inAny: [prs[i].title, prs[i].headBranch], knownProjects: known)
            }
        }
        link(&snapshot.myPullRequests)
        link(&snapshot.reviewRequests)
    }

    private func jiraSource(for credentials: JiraCredentials) -> any JiraFetching {
        if let jira, jira.credentials == credentials { return jira.source }
        let source = jiraFactory(credentials)
        jira = (credentials, source)
        return source
    }

    private func isEnabled(_ source: Source) -> Bool { settings.sourceEnabled[source] ?? true }

    private func publish(_ next: Snapshot) {
        guard next != snapshot else { return }
        var next = next
        next.generatedAt = now()
        let old = snapshot
        snapshot = next
        onChange?(old, next)
    }
}

private func fetchGitHub(
    _ source: any GitHubFetching, includeTeam: Bool, run: Bool
) async -> Result<GitHubResult, any Error>? {
    guard run else { return nil }
    do { return .success(try await source.fetch(includeTeamRequests: includeTeam)) } catch {
        return isCancellation(error) ? nil : .failure(error)
    }
}

private func fetchJira(_ source: (any JiraFetching)?, run: Bool) async -> Result<JiraResult, any Error>? {
    guard run, let source else { return nil }
    do { return .success(try await source.fetch()) } catch { return isCancellation(error) ? nil : .failure(error) }
}

private func fetchLinked(_ source: any JiraFetching, keys: [String]) async -> Result<[Ticket], any Error>? {
    do { return .success(try await source.fetchTickets(keys: keys)) } catch {
        return isCancellation(error) ? nil : .failure(error)
    }
}

/// A cancelled refresh drops its result instead of reporting an error.
private func isCancellation(_ error: any Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
}
