import Foundation

public struct GitHubResult: Sendable, Equatable {
    public var viewerLogin: String
    public var mine: [PullRequest]
    public var reviewRequests: [PullRequest]
    /// GraphQL error messages that came with partial data; empty normally.
    public var warnings: [String]

    public init(viewerLogin: String, mine: [PullRequest], reviewRequests: [PullRequest], warnings: [String] = []) {
        self.viewerLogin = viewerLogin
        self.mine = mine
        self.reviewRequests = reviewRequests
        self.warnings = warnings
    }
}

/// Fetches the user's open PRs and review requests with one GraphQL request.
public final class GitHubSource: Sendable {
    private let tokens: any GitHubTokenProviding
    private let transport: any HTTPTransport

    public init(tokens: any GitHubTokenProviding, transport: any HTTPTransport = URLSessionTransport()) {
        self.tokens = tokens
        self.transport = transport
    }

    public func fetch(includeTeamRequests: Bool) async throws -> GitHubResult {
        let body = try GitHubQuery.body(includeTeamRequests: includeTeamRequests)
        var response = try await post(body, token: tokens.token(forceRefresh: false))
        if response.1.statusCode == 401 {
            response = try await post(body, token: tokens.token(forceRefresh: true))
        }
        let (data, http) = response
        switch http.statusCode {
        case 200..<300: break
        case 401: throw GitHubError.unauthorized
        default: throw GitHubError.http(http.statusCode)
        }
        return try Self.map(data, includeTeamRequests: includeTeamRequests)
    }

    /// PRs by repository and number, for the launcher's rows of PRs not in my lists: one
    /// GraphQL request for all of them (at most `maxLookups`). A PR GitHub does not find in a
    /// repository, or a repository it reports NOT_FOUND, is missing; so is a ref whose repo is
    /// not a plain `owner/name` or whose number is too long, which is never sent.
    public func fetchPullRequests(_ refs: [PullRequestRef]) async throws -> PullRequestLookup {
        var lookup = PullRequestLookup()
        var asked: [PullRequestRef] = []
        for ref in refs.prefix(Self.maxLookups) where !asked.contains(ref) {
            // GraphQL's Int is 32 bits: a longer number would fail the whole query.
            if AppSettings.isRepo(ref.repo), ref.number <= Int(Int32.max) {
                asked.append(ref)
            } else {
                lookup.missing.insert(ref)
            }
        }
        guard !asked.isEmpty else { return lookup }
        let body = try GitHubQuery.lookupBody(asked)
        var response = try await post(body, token: tokens.token(forceRefresh: false))
        if response.1.statusCode == 401 {
            response = try await post(body, token: tokens.token(forceRefresh: true))
        }
        let (data, http) = response
        switch http.statusCode {
        case 200..<300: break
        case 401: throw GitHubError.unauthorized
        default: throw GitHubError.http(http.statusCode)
        }
        struct Answer: Decodable {
            struct Repository: Decodable { var pullRequest: Node? }
            struct Node: Decodable {
                var number: Int
                var title: String
                var state: String
                var isDraft: Bool
                var url: String
                var headRefName: String?
            }
            struct GraphQLError: Decodable {
                /// A path step: a field name or a list index.
                enum Step: Decodable {
                    case field(String), index(Int)
                    init(from decoder: any Decoder) throws {
                        let c = try decoder.singleValueContainer()
                        if let i = try? c.decode(Int.self) { self = .index(i) } else { self = .field(try c.decode(String.self)) }
                    }
                }
                var message: String
                var type: String?
                var path: [Step]?
                /// The alias (`p0`, …) the error is about.
                var alias: String? {
                    if case .field(let name)? = path?.first { return name }
                    return nil
                }
            }
            /// An alias maps to null when the repository does not resolve.
            var data: [String: Repository?]?
            var errors: [GraphQLError]?
        }
        let answer: Answer
        do {
            answer = try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
        guard let nodes = answer.data else {
            throw GitHubError.graphQL((answer.errors ?? []).map(\.message))
        }
        let errorTypes = Dictionary(grouping: answer.errors ?? [], by: { $0.alias ?? "" })
            .mapValues { Set($0.map { $0.type ?? "" }) }
        for (index, ref) in asked.enumerated() {
            let alias = "p\(index)"
            let types = errorTypes[alias] ?? []
            // An alias the answer leaves out, or one with an error other than "not found" (an
            // org that refuses the token, a GitHub hiccup), says nothing about the PR.
            guard let repository = nodes[alias], types.subtracting(["NOT_FOUND"]).isEmpty else { continue }
            guard let resolved = repository else {
                if types.contains("NOT_FOUND") { lookup.missing.insert(ref) }
                continue
            }
            guard let node = resolved.pullRequest else {
                lookup.missing.insert(ref)
                continue
            }
            lookup.found[ref] = PullRequestSummary(
                repo: ref.repo, number: node.number, title: node.title,
                state: Self.state(node.state, draft: node.isDraft), url: node.url, headBranch: node.headRefName)
        }
        return lookup
    }

    /// The most PRs one launcher lookup asks about: every configured repository, and a typed one.
    static let maxLookups = 20

    private static func state(_ raw: String, draft: Bool) -> PullRequestSummary.State {
        raw == "MERGED" ? .merged : raw == "CLOSED" ? .closed : draft ? .draft : .open
    }

    /// The PRs that name a Jira key (in the title or description, as GitHub's search reads
    /// them) in these repositories, for an expanded launcher row: one GraphQL search. Nothing is
    /// sent for a malformed key or without a usable repository.
    public func searchPullRequests(_ search: PullRequestSearch) async throws -> [PullRequestSummary] {
        let repos = Array(search.repos.filter(AppSettings.isRepo).prefix(AppSettings.maxGitHubRepos))
        guard search.key.wholeMatch(of: /[A-Z][A-Z0-9_]*-\d+/) != nil, !repos.isEmpty else { return [] }
        let body = try GitHubQuery.searchBody(key: search.key, repos: repos)
        var response = try await post(body, token: tokens.token(forceRefresh: false))
        if response.1.statusCode == 401 {
            response = try await post(body, token: tokens.token(forceRefresh: true))
        }
        let (data, http) = response
        switch http.statusCode {
        case 200..<300: break
        case 401: throw GitHubError.unauthorized
        default: throw GitHubError.http(http.statusCode)
        }
        struct Answer: Decodable {
            struct Payload: Decodable {
                struct Search: Decodable { var nodes: [Node?] }
                var search: Search
            }
            /// Search results that are not PRs come as empty objects: every field is optional.
            struct Node: Decodable {
                struct Repository: Decodable { var nameWithOwner: String }
                var number: Int?
                var title: String?
                var state: String?
                var isDraft: Bool?
                var url: String?
                var headRefName: String?
                var repository: Repository?
            }
            struct GraphQLError: Decodable { var message: String }
            var data: Payload?
            var errors: [GraphQLError]?
        }
        let answer: Answer
        do {
            answer = try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
        guard let payload = answer.data else { throw GitHubError.graphQL((answer.errors ?? []).map(\.message)) }
        return payload.search.nodes.compactMap { node in
            guard let node, let number = node.number, let title = node.title, let url = node.url,
                  let repo = node.repository?.nameWithOwner
            else { return nil }
            return PullRequestSummary(
                repo: repo, number: number, title: title, state: Self.state(node.state ?? "", draft: node.isDraft ?? false),
                url: url, headBranch: node.headRefName)
        }
    }

    private func post(_ body: Data, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: GitHubQuery.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DevPulse", forHTTPHeaderField: "User-Agent")
        return try await transport.send(request)
    }

    // MARK: - Mapping

    static func map(_ data: Data, includeTeamRequests: Bool) throws -> GitHubResult {
        let root: Response
        do {
            root = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
        let messages = (root.errors ?? []).map(\.message)
        guard let payload = root.data else {
            throw messages.isEmpty ? GitHubError.decoding("response has no data") : GitHubError.graphQL(messages)
        }
        do {
            let mine = try (payload.mine?.nodes ?? []).compactMap { try $0?.pullRequest(requestedDirectly: true) }
            let direct = try (payload.direct?.nodes ?? []).compactMap { try $0?.pullRequest(requestedDirectly: true) }
            var requests = direct
            if includeTeamRequests {
                let known = Set(direct.map(\.id))
                let teamOnly = try (payload.team?.nodes ?? [])
                    .compactMap { try $0?.pullRequest(requestedDirectly: false) }
                    .filter { !known.contains($0.id) }
                requests += teamOnly
            }
            return GitHubResult(viewerLogin: payload.viewer.login, mine: mine, reviewRequests: requests, warnings: messages)
        } catch let error as GitHubError {
            throw error
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    // MARK: - Wire types

    private struct Response: Decodable {
        struct GraphQLError: Decodable { var message: String }
        struct Payload: Decodable {
            struct Viewer: Decodable { var login: String }
            var viewer: Viewer
            var mine: SearchResult?
            var direct: SearchResult?
            var team: SearchResult?
        }
        var data: Payload?
        var errors: [GraphQLError]?
    }

    /// Search nodes that are not pull requests decode as `null` (empty object).
    private struct SearchResult: Decodable {
        var nodes: [PullRequestNode?]
    }

    private struct Author: Decodable {
        var login: String
        var typename: String
        var name: String?
        enum CodingKeys: String, CodingKey { case login, name, typename = "__typename" }
    }

    private struct CommentNode: Decodable {
        var id: String
        var createdAt: String?
        var submittedAt: String?
        var author: Author?

        func comment() throws -> Comment {
            guard let stamp = submittedAt ?? createdAt else {
                throw GitHubError.decoding("comment \(id) has no date")
            }
            // A deleted account comes back as a null author.
            let login = author?.login ?? "ghost"
            // Copilot is a bot/app account; a regular user with "copilot" in the login is human.
            let isUser = author?.typename == "User"
            let kind: AuthorKind =
                !isUser && login.localizedCaseInsensitiveContains("copilot") ? .copilot
                : author?.typename == "Bot" ? .bot : .human
            return Comment(
                id: id, author: login, authorName: author?.name, authorKind: kind,
                createdAt: try GitHubDate.parse(stamp))
        }
    }

    private struct PullRequestNode: Decodable {
        struct Repository: Decodable { var nameWithOwner: String }
        struct Rollup: Decodable { var state: String }
        struct CommitNode: Decodable {
            struct Commit: Decodable { var statusCheckRollup: Rollup? }
            var commit: Commit
        }
        struct Nodes<T: Decodable>: Decodable { var nodes: [T] }
        struct Counted<T: Decodable>: Decodable {
            var totalCount: Int
            var nodes: [T]?
        }
        struct ReviewState: Decodable { var state: String }
        struct Count: Decodable { var totalCount: Int }

        var id: String?
        var number: Int?
        var title: String
        var url: String
        var headRefName: String
        var headRefOid: String
        var updatedAt: String
        var repository: Repository
        /// Null when the fork was deleted.
        var headRepository: Repository?
        var reviewDecision: String?
        var commits: Nodes<CommitNode>
        var latestOpinionatedReviews: Nodes<ReviewState>
        var reviewRequests: Count
        var comments: Counted<CommentNode>
        var reviews: Counted<CommentNode>

        func pullRequest(requestedDirectly: Bool) throws -> PullRequest? {
            // Anything that is not a pull request comes through as an empty object.
            guard let id, let number else { return nil }
            let checks = CheckState(rawValue: (commits.nodes.last?.commit.statusCheckRollup?.state ?? "").lowercased())
                ?? .none
            let recent = try ((comments.nodes ?? []) + (reviews.nodes ?? []))
                .map { try $0.comment() }
                .sorted { $0.createdAt > $1.createdAt }
            return PullRequest(
                id: id, repo: repository.nameWithOwner, headRepo: headRepository?.nameWithOwner,
                number: number, title: title, url: url,
                headBranch: headRefName, headOid: headRefOid,
                jiraKey: JiraKey.find(inAny: [title, headRefName]),
                checks: checks,
                reviewDecision: Self.decision(reviewDecision),
                approvals: latestOpinionatedReviews.nodes.filter { $0.state == "APPROVED" }.count,
                pendingReviewers: reviewRequests.totalCount,
                commentCount: comments.totalCount + reviews.totalCount,
                lastCommentAt: recent.first?.createdAt,
                requestedDirectly: requestedDirectly,
                updatedAt: try GitHubDate.parse(updatedAt),
                recentComments: recent)
        }

        private static func decision(_ raw: String?) -> ReviewDecision {
            switch raw {
            case "APPROVED": .approved
            case "CHANGES_REQUESTED": .changesRequested
            case "REVIEW_REQUIRED": .reviewRequired
            default: .none
            }
        }
    }
}

/// GitHub API dates: `2026-11-19T10:00:00Z`, tolerating fractional seconds.
enum GitHubDate {
    static func parse(_ text: String) throws -> Date {
        let plain = Date.ISO8601FormatStyle()
        if let date = try? plain.parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        throw GitHubError.decoding("bad date: \(text)")
    }
}
