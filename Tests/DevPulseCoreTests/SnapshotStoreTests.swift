import Foundation
import OSLog
import Synchronization
import Testing
@testable import DevPulseCore

private final class FakeGitHub: GitHubFetching {
    let results = Mutex<[Result<GitHubResult, Error>]>([])
    let teamFlags = Mutex<[Bool]>([])
    let pullRequestLookups = Mutex<[String]>([])
    func fetchPullRequests(_ refs: [PullRequestRef]) async throws -> PullRequestLookup {
        pullRequestLookups.withLock { $0.append(refs.map { "\($0.repo)#\($0.number)" }.joined(separator: ",")) }
        var lookup = PullRequestLookup()
        for ref in refs {
            lookup.found[ref] = PullRequestSummary(
                repo: ref.repo, number: ref.number, title: "T", state: .open, url: "https://github.com/\(ref.repo)/pull/\(ref.number)")
        }
        return lookup
    }
    func fetch(includeTeamRequests: Bool) async throws -> GitHubResult {
        teamFlags.withLock { $0.append(includeTeamRequests) }
        return try results.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }.get()
    }
}

private final class FakeJira: JiraFetching {
    let result = Mutex<Result<JiraResult, Error>>(.success(JiraResult(myAccountId: "acc", tickets: [])))
    /// The answer to the linked-tickets search, and the keys of every such search.
    let linked = Mutex<Result<[Ticket], Error>>(.success([]))
    let linkedSearches = Mutex<[[String]]>([])
    /// The answer to the created-tickets search, and the statuses of every such search.
    let created = Mutex<Result<[Ticket], Error>>(.success([]))
    let createdSearches = Mutex<[[String]]>([])
    func fetch() async throws -> JiraResult { try result.withLock { $0 }.get() }
    func fetchCreatedTickets(statuses: [String]) async throws -> [Ticket] {
        createdSearches.withLock { $0.append(statuses) }
        return try created.withLock { $0 }.get()
    }
    func fetchTickets(keys: [String]) async throws -> [Ticket] {
        linkedSearches.withLock { $0.append(keys) }
        return try linked.withLock { $0 }.get()
    }
}

/// A Jira whose linked-tickets search waits until released.
private final class GatedLinkedJira: JiraFetching {
    let searches = Mutex(0)
    private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
    func fetch() async throws -> JiraResult { JiraResult(myAccountId: "acc", tickets: []) }
    func fetchTickets(keys: [String]) async throws -> [Ticket] {
        await withCheckedContinuation { c in
            continuation.withLock { $0 = c }
            searches.withLock { $0 += 1 }
        }
        return keys.map(makeTicket(key:))
    }
    func release() { continuation.withLock { $0 }?.resume() }
}

/// A PR whose title carries `key`, as GitHub and the store map it.
private func makePR(number: Int, key: String) -> PullRequest {
    var pr = makePR(number: number)
    pr.title = "\(key) Change \(number)"
    pr.jiraKey = key
    return pr
}

private final class FakeClaude: ClaudeSessionProviding {
    let sessions = Mutex<[ClaudeSession]>([])
    let handler = Mutex<(@Sendable ([ClaudeSession]) -> Void)?>(nil)
    func currentSessions() -> [ClaudeSession] { sessions.withLock { $0 } }
    func start(onChange: @escaping @Sendable ([ClaudeSession]) -> Void) { handler.withLock { $0 = onChange } }
    func stop() { handler.withLock { $0 = nil } }
}

private final class GatedGitHub: GitHubFetching {
    let count = Mutex(0)
    private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
    func fetch(includeTeamRequests: Bool) async throws -> GitHubResult {
        await withCheckedContinuation { c in
            continuation.withLock { $0 = c }
            count.withLock { $0 += 1 }
        }
        return GitHubResult(viewerLogin: "me", mine: [makePR(number: 7)], reviewRequests: [])
    }
    func release() { continuation.withLock { $0 }?.resume() }
}

/// Answers Jira's `/myself` and an empty search, counting the `/myself` calls.
private final class MyselfCountingTransport: HTTPTransport {
    let myselfCalls = Mutex(0)
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isMyself = request.url?.path == "/rest/api/3/myself"
        if isMyself { myselfCalls.withLock { $0 += 1 } }
        let body = isMyself ? #"{"accountId":"acc-me"}"# : #"{"issues":[]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private let creds = JiraCredentials(site: URL(string: "https://acme.atlassian.net")!, email: "e", token: "t")
private let t0 = Date(timeIntervalSince1970: 1_000)

private final class FakeClock: Sendable {
    let date = Mutex(t0)
}

@MainActor private final class Rig {
    let github = FakeGitHub()
    let jira = FakeJira()
    let claude = FakeClaude()
    let store: SnapshotStore
    let clock = FakeClock()

    init(settings: AppSettings = AppSettings(), credentials: JiraCredentials? = creds) {
        github.results.withLock { $0 = [.success(GitHubResult(viewerLogin: "me", mine: [makePR(number: 1)], reviewRequests: []))] }
        let jira = self.jira
        let clock = self.clock
        store = SnapshotStore(
            github: github, jiraFactory: { _ in jira }, claude: claude,
            jiraCredentials: { credentials }, settings: settings, appVersion: "1.0",
            now: { clock.date.withLock { $0 } })
    }
}

@Suite @MainActor struct SnapshotStoreTests {
    @Test func launcherLookupsUseTheSourcesWhileTheyAreOn() async throws {
        let rig = Rig()
        rig.jira.linked.withLock { $0 = .success([makeTicket(key: "WA-7")]) }
        #expect(try await rig.store.lookUpTickets(keys: ["WA-7"]).tickets.map(\.key) == ["WA-7"])
        #expect(rig.jira.linkedSearches.withLock { $0 } == [["WA-7"]])
        let refs = [PullRequestRef(repo: "acme/store", number: 7), PullRequestRef(repo: "acme/api", number: 7)]
        let prs = try await rig.store.lookUpPullRequests(refs)
        #expect(prs.found[refs[1]]?.title == "T")
        #expect(rig.github.pullRequestLookups.withLock { $0 } == ["acme/store#7,acme/api#7"])
    }

    @Test func launcherLookupsFailWhenASourceIsOffOrJiraIsNotSetUp() async {
        var off = AppSettings()
        off.sourceEnabled[.jira] = false
        off.sourceEnabled[.github] = false
        let rig = Rig(settings: off)
        await #expect(throws: LookupUnavailable.self) { try await rig.store.lookUpTickets(keys: ["WA-7"]) }
        await #expect(throws: LookupUnavailable.self) {
            try await rig.store.lookUpPullRequests([PullRequestRef(repo: "acme/store", number: 7)])
        }
        #expect(rig.jira.linkedSearches.withLock { $0 }.isEmpty)
        #expect(rig.github.pullRequestLookups.withLock { $0 }.isEmpty)
        let unset = Rig(credentials: nil)
        await #expect(throws: LookupUnavailable.self) { try await unset.store.lookUpTickets(keys: ["WA-7"]) }
    }

    @Test func successfulFetchFillsSnapshotAndIds() async {
        let rig = Rig()
        rig.jira.result.withLock { $0 = .success(JiraResult(myAccountId: "acc-1", tickets: [makeTicket(key: "A-1")])) }
        await rig.store.refresh([.github, .jira])
        let snap = rig.store.snapshot
        #expect(snap.myPullRequests.count == 1)
        #expect(snap.tickets.map(\.key) == ["A-1"])
        #expect(snap.sources.github == SourceStatus(state: .ok, lastSuccess: t0))
        #expect(snap.sources.jira.state == .ok)
        #expect(snap.jiraBaseURL == "https://acme.atlassian.net")
        #expect(snap.appVersion == "1.0")
        #expect(rig.store.githubLogin == "me")
        #expect(rig.store.jiraAccountId == "acc-1")
    }

    @Test func githubFailureKeepsDataAndLastSuccess() async {
        let rig = Rig()
        await rig.store.refresh([.github])
        rig.clock.date.withLock { $0 = t0.addingTimeInterval(120) }
        rig.github.results.withLock { $0 = [.failure(GitHubError.http(502))] }
        await rig.store.refresh([.github])
        let snap = rig.store.snapshot
        #expect(snap.myPullRequests.count == 1)
        #expect(snap.sources.github.state == .error)
        #expect(snap.sources.github.message == "HTTP 502")
        #expect(snap.sources.github.lastSuccess == t0)
        #expect(rig.store.githubLogin == "me")
    }

    @Test func jiraFailureKeepsTickets() async {
        let rig = Rig()
        rig.jira.result.withLock { $0 = .success(JiraResult(myAccountId: "a", tickets: [makeTicket(key: "A-1")])) }
        await rig.store.refresh([.jira])
        rig.jira.result.withLock { $0 = .failure(JiraError.unauthorized) }
        await rig.store.refresh([.jira])
        #expect(rig.store.snapshot.tickets.count == 1)
        #expect(rig.store.snapshot.sources.jira.state == .error)
        #expect(rig.store.snapshot.sources.jira.message == "Jira credentials rejected")
    }

    @Test func disabledSourceIsEmptied() async {
        let rig = Rig()
        await rig.store.refresh([.github])
        #expect(rig.store.snapshot.myPullRequests.count == 1)
        var settings = rig.store.settings
        settings.sourceEnabled[.github] = false
        rig.store.settings = settings
        await rig.store.refresh([.github])
        #expect(rig.store.snapshot.sources.github.state == .disabled)
        #expect(rig.store.snapshot.myPullRequests.isEmpty)
        #expect(rig.store.snapshot.reviewRequests.isEmpty)
    }

    @Test func disabledJiraSkipsTheCredentialsAndKeepsTheSite() async {
        var settings = AppSettings()
        settings.sourceEnabled[.jira] = false
        settings.jiraSite = URL(string: "https://acme.atlassian.net")
        var reads = 0
        let store = SnapshotStore(
            github: FakeGitHub(), jiraFactory: { _ in FakeJira() }, claude: FakeClaude(),
            jiraCredentials: {
                reads += 1
                return creds
            },
            settings: settings, appVersion: "1.0", now: { t0 })
        await store.refresh([.jira])
        #expect(reads == 0)
        #expect(store.snapshot.sources.jira.state == .disabled)
        #expect(store.snapshot.jiraBaseURL == "https://acme.atlassian.net")
    }

    @Test func jiraWithoutCredentialsIsUnconfigured() async {
        let rig = Rig(credentials: nil)
        await rig.store.refresh([.jira])
        #expect(rig.store.snapshot.sources.jira.state == .unconfigured)
        #expect(rig.store.snapshot.tickets.isEmpty)
        #expect(rig.store.snapshot.jiraBaseURL == nil)
    }

    @Test func warningsKeepStateOkAndAreJoined() async {
        let rig = Rig()
        rig.github.results.withLock {
            $0 = [.success(GitHubResult(viewerLogin: "me", mine: [], reviewRequests: [], warnings: ["a", "b"]))]
        }
        await rig.store.refresh([.github])
        #expect(rig.store.snapshot.sources.github.state == .ok)
        #expect(rig.store.snapshot.sources.github.message == "a; b")
    }

    @Test func teamRequestsFlagComesFromSettings() async {
        var settings = AppSettings()
        settings.includeTeamReviewRequests = true
        let rig = Rig(settings: settings)
        await rig.store.refresh([.github])
        #expect(rig.github.teamFlags.withLock { $0 } == [true])
    }

    @Test func onChangeFiresOnRealChangeIncludingTimestamps() async {
        let rig = Rig()
        let calls = Mutex(0)
        rig.store.onChange = { _, _ in calls.withLock { $0 += 1 } }
        await rig.store.refresh([.github])
        #expect(calls.withLock { $0 } == 1)
        // Same data, same clock: nothing changed.
        await rig.store.refresh([.github])
        #expect(calls.withLock { $0 } == 1)
        // Same data, later clock: lastSuccess moved, so it fires.
        rig.clock.date.withLock { $0 = t0.addingTimeInterval(60) }
        await rig.store.refresh([.github])
        #expect(calls.withLock { $0 } == 2)
        // A repeated identical failure fires once, then not again.
        rig.github.results.withLock { $0 = [.failure(GitHubError.http(500))] }
        await rig.store.refresh([.github])
        #expect(calls.withLock { $0 } == 3)
        rig.clock.date.withLock { $0 = t0.addingTimeInterval(120) }
        await rig.store.refresh([.github])
        #expect(calls.withLock { $0 } == 3)
    }

    @Test func overlappingRefreshFetchesOnce() async {
        let rig = Rig()
        let gate = GatedGitHub()
        let store = SnapshotStore(
            github: gate, jiraFactory: { _ in rig.jira }, claude: rig.claude,
            jiraCredentials: { creds }, appVersion: "1.0", now: { t0 })
        let a = Task { await store.refresh([.github]) }
        while gate.count.withLock({ $0 }) == 0 { await Task.yield() }
        await store.refresh([.github])  // B: skipped while A is in flight
        gate.release()
        await a.value
        #expect(gate.count.withLock { $0 } == 1)
        #expect(store.snapshot.myPullRequests.map(\.number) == [7])
        #expect(store.snapshot.sources.github == SourceStatus(state: .ok, lastSuccess: t0))
    }

    @Test func cancelledFetchIsDroppedNotAnError() async {
        let rig = Rig()
        await rig.store.refresh([.github])
        rig.github.results.withLock { $0 = [.failure(CancellationError())] }
        rig.jira.result.withLock { $0 = .failure(URLError(.cancelled)) }
        await rig.store.refresh([.github, .jira])
        #expect(rig.store.snapshot.sources.github.state == .ok)
        #expect(rig.store.snapshot.sources.jira.state != .error)
    }

    @Test func claudeUpdatesGoStraightIn() async {
        let rig = Rig()
        let calls = Mutex<[Snapshot]>([])
        rig.store.onChange = { _, new in calls.withLock { $0.append(new) } }
        rig.store.startWatchingClaude()
        let session = ClaudeSession(pid: 1, name: "n", cwd: "/", status: .waiting, updatedAt: t0)
        rig.claude.handler.withLock { $0 }?([session])
        await Task.yield()
        for _ in 0..<50 where rig.store.snapshot.sessions.isEmpty { await Task.yield() }
        #expect(rig.store.snapshot.sessions == [session])
        #expect(calls.withLock { $0.count } == 1)
        rig.store.stopWatchingClaude()
        #expect(rig.claude.handler.withLock { $0 } == nil)
    }

    @Test func claudeRefreshUsesTheWatcherAndNeverRescans() async {
        let rig = Rig()
        let watched = ClaudeSession(pid: 1, name: "watched", cwd: "/", status: .busy, updatedAt: t0)
        // What a fresh scan would read now, e.g. a half-written file already dropped.
        rig.claude.sessions.withLock { $0 = [] }
        rig.store.startWatchingClaude()
        rig.claude.handler.withLock { $0 }?([watched])
        for _ in 0..<50 where rig.store.snapshot.sessions.isEmpty { await Task.yield() }
        await rig.store.refresh(Set(Source.allCases))
        #expect(rig.store.snapshot.sessions == [watched])
        #expect(rig.store.snapshot.sources.claude.state == .ok)
        // Off and on again: the watcher's last list comes back without a new scan or event.
        var settings = rig.store.settings
        settings.sourceEnabled[.claude] = false
        rig.store.settings = settings
        await rig.store.refresh([.claude])
        #expect(rig.store.snapshot.sessions.isEmpty)
        #expect(rig.store.snapshot.sources.claude.state == .disabled)
        settings.sourceEnabled[.claude] = true
        rig.store.settings = settings
        await rig.store.refresh([.claude])
        #expect(rig.store.snapshot.sessions == [watched])
        #expect(rig.store.snapshot.sources.claude.state == .ok)
    }

    @Test func jiraAccountIsFetchedOnceUntilTheCredentialsChange() async {
        let transport = MyselfCountingTransport()
        let credentials = Mutex(creds)
        let store = SnapshotStore(
            github: FakeGitHub(), jiraFactory: { JiraSource(credentials: $0, transport: transport) },
            claude: FakeClaude(), jiraCredentials: { credentials.withLock { $0 } },
            appVersion: "1.0", now: { t0 })
        await store.refresh([.jira])
        await store.refresh([.jira])
        #expect(transport.myselfCalls.withLock { $0 } == 1)
        #expect(store.snapshot.sources.jira.state == .ok)
        credentials.withLock { $0.token = "new-token" }
        await store.refresh([.jira])
        #expect(transport.myselfCalls.withLock { $0 } == 2)
    }

    @Test func prKeysPreferTheProjectsOfMyTicketsAndTheDefault() async {
        var pr = makePR(number: 3)
        pr.title = "Bump AB-12 for STORE-7"
        pr.headBranch = "feature/SHOP-9-bump"
        pr.jiraKey = JiraKey.find(in: pr.title)  // as GitHubSource maps it: AB-12
        let rig = Rig()
        rig.github.results.withLock { $0 = [.success(GitHubResult(viewerLogin: "me", mine: [pr], reviewRequests: [pr]))] }
        rig.jira.result.withLock { $0 = .success(JiraResult(myAccountId: "a", tickets: [makeTicket(key: "STORE-1")])) }
        await rig.store.refresh([.github, .jira])
        #expect(rig.store.snapshot.myPullRequests.map(\.jiraKey) == ["STORE-7"])
        #expect(rig.store.snapshot.reviewRequests.map(\.jiraKey) == ["STORE-7"])
        // The default project counts too, and a known key in the branch beats an unknown one
        // in the title.
        var settings = rig.store.settings
        settings.jiraProjects = ["SHOP"]
        rig.store.settings = settings
        rig.jira.result.withLock { $0 = .success(JiraResult(myAccountId: "a", tickets: [])) }
        await rig.store.refresh([.github, .jira])
        #expect(rig.store.snapshot.myPullRequests.map(\.jiraKey) == ["SHOP-9"])
    }

    // MARK: Linked tickets

    @Test func prTicketsThatAreNotMineComeFromOneExtraSearch() async {
        let rig = Rig()
        rig.github.results.withLock {
            $0 = [.success(GitHubResult(
                viewerLogin: "me",
                mine: [makePR(number: 1, key: "OTHER-1"), makePR(number: 2, key: "MINE-1")],
                reviewRequests: [makePR(number: 3, key: "OTHER-2"), makePR(number: 4, key: "OTHER-1")]))]
        }
        rig.jira.result.withLock { $0 = .success(JiraResult(myAccountId: "a", tickets: [makeTicket(key: "MINE-1")])) }
        rig.jira.linked.withLock { $0 = .success([makeTicket(key: "OTHER-1"), makeTicket(key: "OTHER-2")]) }
        await rig.store.refresh([.github, .jira])
        // One search, for the keys missing from my tickets, each once, in PR order.
        #expect(rig.jira.linkedSearches.withLock { $0 } == [["OTHER-1", "OTHER-2"]])
        #expect(rig.store.snapshot.linkedTickets.map(\.key) == ["OTHER-1", "OTHER-2"])
        #expect(rig.store.snapshot.tickets.map(\.key) == ["MINE-1"])
    }

    @Test func theTicketsICreatedComeFromTheirOwnSearchInTheWatchedStatuses() async {
        var settings = AppSettings()
        settings.createdTicketStatuses = ["In Review", "QA"]
        let rig = Rig(settings: settings)
        rig.jira.result.withLock { $0 = .success(JiraResult(myAccountId: "a", tickets: [makeTicket(key: "MINE-1")])) }
        rig.jira.created.withLock { $0 = .success([makeTicket(key: "MADE-1"), makeTicket(key: "MADE-2")]) }
        await rig.store.refresh([.github, .jira])
        #expect(rig.jira.createdSearches.withLock { $0 } == [["In Review", "QA"]])
        #expect(rig.store.snapshot.createdTickets.map(\.key) == ["MADE-1", "MADE-2"])
        #expect(rig.store.snapshot.createdTicketStatuses == ["In Review", "QA"])
        #expect(rig.store.snapshot.createdTicketsError == nil)
        #expect(rig.store.snapshot.tickets.map(\.key) == ["MINE-1"])
    }

    @Test func switchingTheCreatedTicketsOffClearsThemWithoutASearch() async {
        let rig = Rig()
        rig.jira.created.withLock { $0 = .success([makeTicket(key: "MADE-1")]) }
        await rig.store.refresh([.jira])
        #expect(rig.store.snapshot.createdTickets.map(\.key) == ["MADE-1"])
        rig.store.settings.showsCreatedTickets = false
        await rig.store.refresh([.jira])
        #expect(rig.jira.createdSearches.withLock { $0 }.count == 1)
        #expect(rig.store.snapshot.createdTickets.isEmpty)
        #expect(rig.store.snapshot.createdTicketStatuses.isEmpty)
    }

    @Test func aFailedCreatedSearchKeepsTheTicketsSaysWhyAndLeavesJiraOk() async {
        let rig = Rig()
        rig.jira.created.withLock { $0 = .success([makeTicket(key: "MADE-1")]) }
        await rig.store.refresh([.jira])
        // A status Jira does not know: it refuses the whole search.
        rig.jira.created.withLock { $0 = .failure(JiraError.http(400)) }
        await rig.store.refresh([.jira])
        #expect(rig.store.snapshot.createdTickets.map(\.key) == ["MADE-1"])
        #expect(rig.store.snapshot.createdTicketsError == "Jira refused the search; check the statuses in Settings › Jira")
        #expect(rig.store.snapshot.sources.jira.state == .ok)
        rig.jira.created.withLock { $0 = .failure(JiraError.http(503)) }
        await rig.store.refresh([.jira])
        #expect(rig.store.snapshot.createdTicketsError == "HTTP 503")
        // Other statuses: the old list was for those before, it goes.
        rig.store.settings.createdTicketStatuses = ["QA"]
        await rig.store.refresh([.jira])
        #expect(rig.store.snapshot.createdTickets.isEmpty)
        rig.jira.created.withLock { $0 = .success([makeTicket(key: "MADE-2")]) }
        await rig.store.refresh([.jira])
        #expect(rig.store.snapshot.createdTicketsError == nil)
        #expect(rig.store.snapshot.createdTickets.map(\.key) == ["MADE-2"])
    }

    @Test func aJiraThatIsOffOrFailsTakesTheCreatedTicketsAlong() async {
        let rig = Rig()
        rig.jira.created.withLock { $0 = .success([makeTicket(key: "MADE-1")]) }
        await rig.store.refresh([.jira])
        // My own search failing: nothing is asked, the list stays like my tickets.
        rig.jira.result.withLock { $0 = .failure(JiraError.http(500)) }
        await rig.store.refresh([.jira])
        #expect(rig.jira.createdSearches.withLock { $0 }.count == 1)
        #expect(rig.store.snapshot.createdTickets.map(\.key) == ["MADE-1"])
        rig.store.settings.sourceEnabled[.jira] = false
        await rig.store.refresh([.jira])
        #expect(rig.store.snapshot.createdTickets.isEmpty)
    }

    @Test func noMissingKeysMeansNoSearch() async {
        let rig = Rig()
        rig.github.results.withLock {
            $0 = [.success(GitHubResult(viewerLogin: "me", mine: [makePR(number: 1, key: "MINE-1"), makePR(number: 2)],
                                        reviewRequests: []))]
        }
        rig.jira.result.withLock { $0 = .success(JiraResult(myAccountId: "a", tickets: [makeTicket(key: "MINE-1")])) }
        await rig.store.refresh([.github, .jira])
        #expect(rig.jira.linkedSearches.withLock { $0 }.isEmpty)
        #expect(rig.store.snapshot.linkedTickets.isEmpty)
    }

    @Test func theLinkedKeysAreCappedAtFifty() {
        let prs = (1...60).map { makePR(number: $0, key: "MANY-\($0)") }
        var snapshot = Rig().store.snapshot
        snapshot.myPullRequests = prs
        let keys = LinkedTickets.keys(for: snapshot)
        #expect(keys == (1...50).map { "MANY-\($0)" })
    }

    @Test func aFailedLinkedFetchLeavesNoLinkedTicketsAndTheJiraStateOk() async {
        let rig = Rig()
        rig.github.results.withLock {
            $0 = [.success(GitHubResult(viewerLogin: "me", mine: [makePR(number: 1, key: "OTHER-1")], reviewRequests: []))]
        }
        rig.jira.result.withLock { $0 = .success(JiraResult(myAccountId: "a", tickets: [makeTicket(key: "MINE-1")])) }
        rig.jira.linked.withLock { $0 = .success([makeTicket(key: "OTHER-1")]) }
        await rig.store.refresh([.github, .jira])
        #expect(rig.store.snapshot.linkedTickets.map(\.key) == ["OTHER-1"])
        // A site without the bulk fetch (404) or one that rejects it (400): nothing linked,
        // my own tickets and the Jira state as usual.
        rig.jira.linked.withLock { $0 = .failure(JiraError.http(404)) }
        await rig.store.refresh([.github, .jira])
        #expect(rig.store.snapshot.linkedTickets.isEmpty)
        #expect(rig.store.snapshot.tickets.map(\.key) == ["MINE-1"])
        #expect(rig.store.snapshot.sources.jira.state == .ok)
        #expect(rig.store.snapshot.sources.jira.message == nil)
    }

    @Test func aFailedLinkedFetchIsLoggedAsAnErrorWithoutTheKeys() async throws {
        let start = Date()
        let rig = Rig()
        rig.github.results.withLock {
            $0 = [.success(GitHubResult(viewerLogin: "me", mine: [makePR(number: 1, key: "LOGGED-7")], reviewRequests: []))]
        }
        rig.jira.linked.withLock { $0 = .failure(JiraError.http(418)) }
        await rig.store.refresh([.github, .jira])
        let log = try OSLogStore(scope: .currentProcessIdentifier)
        let messages = try log.getEntries(
            at: log.position(date: start),
            matching: NSPredicate(format: "subsystem == %@ AND category == %@", "io.jp4.devpulse", "jira"))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.level == .error }
            .map(\.composedMessage)
        #expect(messages.contains { $0.contains("HTTP 418") }, "\(messages)")
        #expect(!messages.contains { $0.contains("LOGGED-7") })
    }

    @Test func aFailedMainJiraFetchSkipsTheLinkedFetchAndKeepsTheLinkedTickets() async {
        let rig = Rig()
        rig.github.results.withLock {
            $0 = [.success(GitHubResult(viewerLogin: "me", mine: [makePR(number: 1, key: "OTHER-1")], reviewRequests: []))]
        }
        rig.jira.linked.withLock { $0 = .success([makeTicket(key: "OTHER-1")]) }
        await rig.store.refresh([.github, .jira])
        #expect(rig.jira.linkedSearches.withLock { $0 }.count == 1)
        // Credentials rejected, an outage or a cancelled fetch: no second request that would
        // fail too, and the linked tickets stay like my own tickets do.
        for failure in [JiraError.unauthorized, JiraError.http(503)] as [any Error] + [CancellationError()] {
            rig.jira.result.withLock { $0 = .failure(failure) }
            await rig.store.refresh([.github, .jira])
            #expect(rig.jira.linkedSearches.withLock { $0 }.count == 1)
            #expect(rig.store.snapshot.linkedTickets.map(\.key) == ["OTHER-1"])
        }
    }

    @Test func jiraOffOrUnconfiguredDropsTheLinkedTickets() async {
        let rig = Rig()
        rig.github.results.withLock {
            $0 = [.success(GitHubResult(viewerLogin: "me", mine: [makePR(number: 1, key: "OTHER-1")], reviewRequests: []))]
        }
        rig.jira.linked.withLock { $0 = .success([makeTicket(key: "OTHER-1")]) }
        await rig.store.refresh([.github, .jira])
        #expect(rig.store.snapshot.linkedTickets.count == 1)
        var settings = rig.store.settings
        settings.sourceEnabled[.jira] = false
        rig.store.settings = settings
        await rig.store.refresh([.github, .jira])
        #expect(rig.store.snapshot.linkedTickets.isEmpty)
        #expect(rig.jira.linkedSearches.withLock { $0 }.count == 1)

        let unconfigured = Rig(credentials: nil)
        unconfigured.github.results.withLock {
            $0 = [.success(GitHubResult(viewerLogin: "me", mine: [makePR(number: 1, key: "OTHER-1")], reviewRequests: []))]
        }
        await unconfigured.store.refresh([.github, .jira])
        #expect(unconfigured.store.snapshot.linkedTickets.isEmpty)
        #expect(unconfigured.jira.linkedSearches.withLock { $0 }.isEmpty)
    }

    @Test func sessionsThatArriveDuringTheLinkedSearchAreKept() async {
        let github = FakeGitHub()
        github.results.withLock {
            $0 = [.success(GitHubResult(viewerLogin: "me", mine: [makePR(number: 1, key: "OTHER-1")], reviewRequests: []))]
        }
        let jira = GatedLinkedJira()
        let claude = FakeClaude()
        let store = SnapshotStore(
            github: github, jiraFactory: { _ in jira }, claude: claude,
            jiraCredentials: { creds }, appVersion: "1.0", now: { t0 })
        store.startWatchingClaude()
        let refresh = Task { await store.refresh([.github, .jira]) }
        while jira.searches.withLock({ $0 }) == 0 { await Task.yield() }
        let session = ClaudeSession(pid: 1, name: "n", cwd: "/", status: .busy, updatedAt: t0)
        claude.handler.withLock { $0 }?([session])
        for _ in 0..<50 where store.snapshot.sessions.isEmpty { await Task.yield() }
        #expect(store.snapshot.sessions == [session])
        jira.release()
        await refresh.value
        #expect(store.snapshot.sessions == [session])
        #expect(store.snapshot.linkedTickets.map(\.key) == ["OTHER-1"])
        #expect(store.snapshot.myPullRequests.count == 1)
    }

    @Test func claudeSwitchedOffAtLaunchIsDisabledWithoutARefresh() async {
        var settings = AppSettings()
        settings.sourceEnabled[.claude] = false
        let rig = Rig(settings: settings)
        #expect(rig.store.snapshot.sources.claude.state == .disabled)
        #expect(rig.store.snapshot.sources.github.state == .fetching)
        #expect(rig.store.snapshot.sources.jira.state == .fetching)
        // The watcher's reports stay out while it is off; GitHub and Jira fetch as before.
        rig.store.startWatchingClaude()
        rig.claude.handler.withLock { $0 }?([ClaudeSession(pid: 1, name: "n", cwd: "/", status: .busy, updatedAt: t0)])
        await rig.store.refresh(RefreshPolicy.fetchedSources)
        #expect(rig.store.snapshot.sources.claude.state == .disabled)
        #expect(rig.store.snapshot.sessions.isEmpty)
        #expect(rig.store.snapshot.sources.github.state == .ok)
        #expect(rig.store.snapshot.sources.jira.state == .ok)
    }

    @Test func allSourcesStartFetchingWhenOn() {
        let sources = Rig().store.snapshot.sources
        #expect([sources.github.state, sources.jira.state, sources.claude.state] == [.fetching, .fetching, .fetching])
    }

    @Test func pauseIsRecorded() {
        let rig = Rig()
        rig.store.setPaused(true)
        #expect(rig.store.isPaused)
        rig.store.setPaused(false)
        #expect(!rig.store.isPaused)
    }
}

@Suite struct RefreshPolicyTests {
    let policy = RefreshPolicy()

    @Test func timerAndManualRefreshesFetchOnlyGitHubAndJira() {
        // Claude Code sessions come from the file watcher alone.
        #expect(RefreshPolicy.fetchedSources == [.github, .jira])
    }

    @Test func theSleepMayRunLateByATenth() {
        #expect(policy.tolerance(forSleep: 120) == 12)
        #expect(policy.tolerance(forSleep: 0) == 0)
    }

    @Test func pausedNeverFetches() {
        #expect(!policy.shouldFetch(now: t0, lastAttempt: nil, interval: 120, paused: true))
    }

    @Test func fetchesWhenNeverAttemptedOrIntervalPassed() {
        #expect(policy.shouldFetch(now: t0, lastAttempt: nil, interval: 120, paused: false))
        #expect(!policy.shouldFetch(now: t0.addingTimeInterval(119), lastAttempt: t0, interval: 120, paused: false))
        #expect(policy.shouldFetch(now: t0.addingTimeInterval(120), lastAttempt: t0, interval: 120, paused: false))
    }

    @Test func secondsUntilDue() {
        #expect(policy.secondsUntilDue(now: t0, lastAttempt: nil, interval: 120) == 0)
        #expect(policy.secondsUntilDue(now: t0.addingTimeInterval(20), lastAttempt: t0, interval: 120) == 100)
        #expect(policy.secondsUntilDue(now: t0.addingTimeInterval(500), lastAttempt: t0, interval: 120) == 0)
    }
}

@Suite struct SourceErrorMessageTests {
    @Test func mapsEveryCase() {
        let m = SourceErrorMessage.text(for:)
        #expect(m(GitHubError.ghMissing) == "GitHub CLI (gh) not found — install it with Homebrew")
        // Plain text in the popover and the TUI: typographic quotes, no Markdown backticks.
        #expect(m(GitHubError.notLoggedIn) == "Not logged in — run “gh auth login”")
        #expect(m(GitHubError.ghTimedOut) == "gh did not respond")
        #expect(m(GitHubError.unauthorized) == "GitHub token rejected")
        #expect(m(GitHubError.graphQL(["first", "second"])) == "first")
        #expect(m(GitHubError.graphQL([])) == "GitHub returned an error")
        #expect(m(GitHubError.http(500)) == "HTTP 500")
        #expect(m(GitHubError.decoding("x")) == "Unexpected response")
        #expect(m(JiraError.unauthorized) == "Jira credentials rejected")
        #expect(m(JiraError.http(404)) == "HTTP 404")
        #expect(m(JiraError.decoding("x")) == "Unexpected response")
        #expect(m(URLError(.notConnectedToInternet)) == "Offline")
        #expect(m(URLError(.networkConnectionLost)) == "Offline")
    }
}
