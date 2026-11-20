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
                id: id, repo: repository.nameWithOwner, number: number, title: title, url: url,
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
