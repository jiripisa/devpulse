import Foundation
import Synchronization
import Testing
@testable import DevPulseCore

private final class FakeTokens: GitHubTokenProviding {
    let calls = Mutex<[Bool]>([])
    func token(forceRefresh: Bool) async throws -> String {
        calls.withLock { $0.append(forceRefresh) }
        return forceRefresh ? "fresh-token" : "old-token"
    }
}

private final class FakeTransport: HTTPTransport {
    let statuses: Mutex<[Int]>
    let body: Data
    let requests = Mutex<[URLRequest]>([])

    init(statuses: [Int] = [200], body: Data) {
        self.statuses = Mutex(statuses)
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        let status = statuses.withLock { $0.count > 1 ? $0.removeFirst() : ($0.first ?? 200) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

@Suite("GitHub source")
struct GitHubTests {

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/github-response.json")

    private static func fixture() throws -> Data { try Data(contentsOf: fixtureURL) }

    private static func fetch(team: Bool) async throws -> GitHubResult {
        let source = GitHubSource(tokens: FakeTokens(), transport: FakeTransport(body: try fixture()))
        return try await source.fetch(includeTeamRequests: team)
    }

    @Test("Maps repo, checks, review state and the Jira key")
    func mapping() async throws {
        let result = try await Self.fetch(team: false)
        #expect(result.viewerLogin == "me-synthetic")
        #expect(result.mine.map(\.number) == [101, 102, 103, 104, 105])
        #expect(result.mine.map(\.checks) == [.success, .pending, .failure, .error, .none])
        let first = result.mine[0]
        #expect(first.repo == "acme/widgets")
        #expect(first.id == "PR_widgets_101")
        #expect(first.headBranch == "feature/STORE-999-other")
        #expect(first.jiraKey == "STORE-100")  // the title wins over the branch
        #expect(first.reviewDecision == .approved)
        #expect(first.approvals == 2)
        #expect(first.pendingReviewers == 0)
        #expect(first.requestedDirectly == true)
        #expect(first.updatedAt == Date(timeIntervalSince1970: 1_795_082_400))  // 2026-11-19T10:00:00Z
        #expect(result.mine[1].jiraKey == "STORE-200")  // from the branch
        #expect(result.mine[1].pendingReviewers == 2)
        #expect(result.mine[2].jiraKey == nil)
        #expect(result.mine[2].reviewDecision == .changesRequested)
    }

    @Test("Maps the head repository, which differs for a PR from a fork")
    func headRepository() async throws {
        let mine = try await Self.fetch(team: false).mine
        #expect(mine[0].headRepo == "fork-owner/widgets")
        #expect(mine[0].repo == "acme/widgets")
        // A deleted fork comes back as null, an older answer without the field as missing.
        #expect(mine[1].headRepo == nil)
        #expect(mine[2].headRepo == nil)
    }

    @Test("Classifies the author kind")
    func authorKind() async throws {
        let comments = try await Self.fetch(team: false).mine[0].recentComments
        let kinds = Dictionary(uniqueKeysWithValues: comments.map { ($0.author, $0.authorKind) })
        #expect(kinds["alice"] == .human)
        #expect(kinds["bob"] == .human)
        #expect(kinds["ci-helper"] == .bot)
        #expect(kinds["Copilot"] == .copilot)  // a Bot whose login contains "copilot"
        #expect(kinds["copilot-fan"] == .human)  // a User is human even with "copilot" in the login
        #expect(comments.first { $0.author == "alice" }?.authorName == "Alice Example")
        #expect(comments.first { $0.author == "ci-helper" }?.authorName == nil)
    }

    @Test("Merges comments and reviews, newest first")
    func recentComments() async throws {
        let pr = try await Self.fetch(team: false).mine[0]
        #expect(pr.recentComments.map(\.id) == ["PRR_1", "IC_2", "IC_1", "IC_3", "PRR_2"])
        #expect(pr.commentCount == 5)
        #expect(pr.lastCommentAt == pr.recentComments.first?.createdAt)
        let quiet = try await Self.fetch(team: false).mine[4]
        #expect(quiet.recentComments.isEmpty && quiet.lastCommentAt == nil)
    }

    @Test("Without team requests only direct ones are returned")
    func directOnly() async throws {
        let result = try await Self.fetch(team: false)
        #expect(result.reviewRequests.map(\.number) == [201])
        #expect(result.reviewRequests[0].requestedDirectly == true)
    }

    @Test("Team-only requests are flagged and not duplicated")
    func teamRequests() async throws {
        let result = try await Self.fetch(team: true)
        #expect(result.reviewRequests.map(\.number) == [201, 202])
        #expect(result.reviewRequests.map(\.requestedDirectly) == [true, false])
    }

    @Test("Sends one GraphQL POST with the aliased searches")
    func requestShape() async throws {
        let tokens = FakeTokens()
        let transport = FakeTransport(body: try Self.fixture())
        let source = GitHubSource(tokens: tokens, transport: transport)
        _ = try await source.fetch(includeTeamRequests: true)
        let requests = transport.requests.withLock { $0 }
        #expect(requests.count == 1)
        let request = requests[0]
        #expect(request.url?.absoluteString == "https://api.github.com/graphql")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token")
        let body = try #require(request.httpBody)
        let query = try #require(
            (JSONSerialization.jsonObject(with: body) as? [String: Any])?["query"] as? String)
        #expect(query.contains("viewer"))
        #expect(query.contains("is:open is:pr author:@me archived:false"))
        #expect(query.contains("is:open is:pr user-review-requested:@me"))
        #expect(query.contains("is:open is:pr review-requested:@me"))
        #expect(query.contains("first: 50"))
        #expect(query.contains("headRepository { nameWithOwner }"))

        let noTeam = FakeTransport(body: try Self.fixture())
        _ = try await GitHubSource(tokens: tokens, transport: noTeam).fetch(includeTeamRequests: false)
        let body2 = try #require(noTeam.requests.withLock { $0 }[0].httpBody)
        let query2 = try #require(
            (JSONSerialization.jsonObject(with: body2) as? [String: Any])?["query"] as? String)
        #expect(!query2.contains("team:"))
    }

    private static func pullRequestBody(state: String = "open", draft: Bool = false, mergedAt: String? = nil) -> Data {
        let merged = mergedAt.map { "\"\($0)\"" } ?? "null"
        return Data("""
            {"number":7,"title":"Faster checkout","state":"\(state)","draft":\(draft),"merged_at":\(merged),
             "html_url":"https://github.com/acme/store/pull/7"}
            """.utf8)
    }

    @Test("Fetches one PR by number over REST")
    func pullRequestByNumber() async throws {
        let transport = FakeTransport(body: Self.pullRequestBody())
        let source = GitHubSource(tokens: FakeTokens(), transport: transport)
        let pr = try await source.fetchPullRequest(repo: "acme/store", number: 7)
        #expect(pr == PullRequestSummary(
            repo: "acme/store", number: 7, title: "Faster checkout", state: .open,
            url: "https://github.com/acme/store/pull/7"))
        let request = try #require(transport.requests.withLock { $0.first })
        #expect(request.url?.absoluteString == "https://api.github.com/repos/acme/store/pulls/7")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token")
    }

    @Test("Maps draft, merged and closed PRs")
    func pullRequestStates() async throws {
        func state(_ body: Data) async throws -> PullRequestSummary.State? {
            try await GitHubSource(tokens: FakeTokens(), transport: FakeTransport(body: body))
                .fetchPullRequest(repo: "acme/store", number: 7)?.state
        }
        #expect(try await state(Self.pullRequestBody(draft: true)) == .draft)
        #expect(try await state(Self.pullRequestBody(state: "closed", mergedAt: "2026-11-01T10:00:00Z")) == .merged)
        #expect(try await state(Self.pullRequestBody(state: "closed")) == .closed)
    }

    @Test("A PR that does not exist is nil; a 401 retries once with a fresh token")
    func pullRequestNotFoundAndRetry() async throws {
        let missing = GitHubSource(tokens: FakeTokens(), transport: FakeTransport(statuses: [404], body: Data("{}".utf8)))
        #expect(try await missing.fetchPullRequest(repo: "acme/store", number: 7) == nil)
        let transport = FakeTransport(statuses: [401, 200], body: Self.pullRequestBody())
        let tokens = FakeTokens()
        let retried = try await GitHubSource(tokens: tokens, transport: transport).fetchPullRequest(repo: "acme/store", number: 7)
        #expect(retried?.title == "Faster checkout")
        #expect(tokens.calls.withLock { $0 } == [false, true])
        let failing = GitHubSource(tokens: FakeTokens(), transport: FakeTransport(statuses: [500], body: Data()))
        await #expect(throws: GitHubError.http(500)) { try await failing.fetchPullRequest(repo: "acme/store", number: 7) }
    }

    @Test("A repo that is not owner/name is never requested")
    func pullRequestInvalidRepo() async throws {
        let transport = FakeTransport(body: Self.pullRequestBody())
        let source = GitHubSource(tokens: FakeTokens(), transport: transport)
        for repo in ["store", "a/b/c", "../x", "a b/c", "a/b?x=1"] {
            #expect(try await source.fetchPullRequest(repo: repo, number: 7) == nil)
        }
        #expect(transport.requests.withLock { $0.isEmpty })
    }

    @Test("A 401 refreshes the token once and retries")
    func tokenRefresh() async throws {
        let tokens = FakeTokens()
        let transport = FakeTransport(statuses: [401, 200], body: try Self.fixture())
        let result = try await GitHubSource(tokens: tokens, transport: transport).fetch(includeTeamRequests: false)
        #expect(result.mine.count == 5)
        #expect(tokens.calls.withLock { $0 } == [false, true])
        let auth = transport.requests.withLock { $0 }.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(auth == ["Bearer old-token", "Bearer fresh-token"])
    }

    @Test("A second 401 throws unauthorized")
    func secondUnauthorized() async throws {
        let tokens = FakeTokens()
        let transport = FakeTransport(statuses: [401], body: Data())
        await #expect(throws: GitHubError.unauthorized) {
            try await GitHubSource(tokens: tokens, transport: transport).fetch(includeTeamRequests: false)
        }
        #expect(tokens.calls.withLock { $0 } == [false, true])
        #expect(transport.requests.withLock { $0 }.count == 2)
    }

    @Test("Other HTTP statuses and bad bodies become errors")
    func otherErrors() async throws {
        await #expect(throws: GitHubError.http(502)) {
            try await GitHubSource(tokens: FakeTokens(), transport: FakeTransport(statuses: [502], body: Data()))
                .fetch(includeTeamRequests: false)
        }
        await #expect {
            try await GitHubSource(tokens: FakeTokens(), transport: FakeTransport(body: Data("{}".utf8)))
                .fetch(includeTeamRequests: false)
        } throws: { error in
            if case GitHubError.decoding = error { return true }
            return false
        }
    }

    @Test("GraphQL errors without data throw with the messages")
    func graphQLErrors() async throws {
        let body = Data(#"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#.utf8)
        await #expect(throws: GitHubError.graphQL(["API rate limit exceeded"])) {
            try await GitHubSource(tokens: FakeTokens(), transport: FakeTransport(body: body))
                .fetch(includeTeamRequests: false)
        }
    }

    @Test("Partial data with errors is returned with warnings")
    func partialData() async throws {
        var json = try #require(JSONSerialization.jsonObject(with: try Self.fixture()) as? [String: Any])
        json["errors"] = [["message": "Resource not accessible"]]
        let body = try JSONSerialization.data(withJSONObject: json)
        let result = try await GitHubSource(tokens: FakeTokens(), transport: FakeTransport(body: body))
            .fetch(includeTeamRequests: false)
        #expect(result.mine.count == 5)
        #expect(result.warnings == ["Resource not accessible"])
        #expect(try await Self.fetch(team: false).warnings.isEmpty)
    }
}

@Suite("gh token provider")
struct GhCLITokenProviderTests {

    private func script(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("gh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("Returns the trimmed token")
    func token() async throws {
        let gh = try script("echo synthetic-token")
        let provider = GhCLITokenProvider(executable: gh)
        #expect(try await provider.token(forceRefresh: false) == "synthetic-token")
    }

    @Test("A hanging gh is terminated at the deadline")
    func timeout() async throws {
        let gh = try script("exec sleep 30")
        let provider = GhCLITokenProvider(executable: gh, timeout: 0.2)
        let started = ContinuousClock.now
        await #expect(throws: GitHubError.ghTimedOut) {
            try await provider.token(forceRefresh: true)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("A failing gh means not logged in")
    func notLoggedIn() async throws {
        let gh = try script("exit 1")
        await #expect(throws: GitHubError.notLoggedIn) {
            try await GhCLITokenProvider(executable: gh).token(forceRefresh: false)
        }
    }

    /// A `gh` that counts its runs in a file next to it.
    private func countingScript() throws -> (gh: URL, runs: () -> Int) {
        let gh = try script("echo run >> \"$(dirname \"$0\")/runs\"\necho synthetic-token")
        let log = gh.deletingLastPathComponent().appendingPathComponent("runs")
        return (gh, { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count })
    }

    @Test("The token is read once and reused by later fetches")
    func tokenCached() async throws {
        let (gh, runs) = try countingScript()
        let source = GitHubSource(
            tokens: GhCLITokenProvider(executable: gh),
            transport: FakeTransport(body: try Data(contentsOf: Self.fixtureURL)))
        _ = try await source.fetch(includeTeamRequests: false)
        _ = try await source.fetch(includeTeamRequests: false)
        #expect(runs() == 1)
    }

    @Test("A 401 reads the token again")
    func unauthorizedRereads() async throws {
        let (gh, runs) = try countingScript()
        let source = GitHubSource(
            tokens: GhCLITokenProvider(executable: gh),
            transport: FakeTransport(statuses: [200, 401, 200], body: try Data(contentsOf: Self.fixtureURL)))
        _ = try await source.fetch(includeTeamRequests: false)
        _ = try await source.fetch(includeTeamRequests: false)
        #expect(runs() == 2)
    }

    @Test("A failed read is not cached")
    func failureNotCached() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let flag = dir.appendingPathComponent("logged-in")
        let gh = try script("[ -f '\(flag.path)' ] || exit 1\necho synthetic-token")
        let provider = GhCLITokenProvider(executable: gh)
        await #expect(throws: GitHubError.notLoggedIn) { try await provider.token(forceRefresh: false) }
        try Data().write(to: flag)
        #expect(try await provider.token(forceRefresh: false) == "synthetic-token")
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/github-response.json")
}
