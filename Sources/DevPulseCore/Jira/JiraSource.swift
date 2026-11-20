import Foundation
import Synchronization

public enum JiraError: Error, Equatable {
    case unauthorized
    case http(Int)
    case decoding(String)
}

public struct JiraResult: Sendable, Equatable {
    public var myAccountId: String
    public var tickets: [Ticket]

    public init(myAccountId: String, tickets: [Ticket]) {
        self.myAccountId = myAccountId
        self.tickets = tickets
    }
}

/// Fetches the user's open Jira Cloud tickets and their recent comments (REST v3).
public final class JiraSource: Sendable {
    static let jql = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
    static let fields = ["summary", "status", "priority", "updated", "comment"]
    static let maxResults = 50
    static let recentCommentLimit = 10

    private let credentials: JiraCredentials
    private let transport: any HTTPTransport
    private let accountId = Mutex<String?>(nil)
    /// The newest comments of tickets whose search `comment` field came back truncated, with
    /// the ticket's `updated` stamp they were fetched at.
    private let newestComments = Mutex<[String: FetchedComments]>([:])

    private struct FetchedComments {
        var updated: String
        var comments: [Comment]
    }

    public init(credentials: JiraCredentials, transport: any HTTPTransport = URLSessionTransport()) {
        self.credentials = credentials
        self.transport = transport
    }

    public func fetch() async throws -> JiraResult {
        let me = try await myAccountId()
        let body = try JSONSerialization.data(withJSONObject: [
            "jql": Self.jql, "fields": Self.fields, "maxResults": Self.maxResults,
        ] as [String: Any])
        let data = try await send(path: "/rest/api/3/search/jql", method: "POST", body: body)
        let issues = try decode(data)
        var tickets: [Ticket] = []
        for issue in issues {
            var ticket = try mapped { try issue.ticket(site: credentials.site) }
            if issue.commentsTruncated, let comments = await self.comments(of: issue) {
                ticket.recentComments = comments
                ticket.lastCommentAt = comments.first?.createdAt
            }
            tickets.append(ticket)
        }
        let keys = Set(issues.map(\.key))
        newestComments.withLock { $0 = $0.filter { keys.contains($0.key) } }
        return JiraResult(myAccountId: me, tickets: tickets)
    }

    /// The newest comments of a busy ticket whose search result left some out: fetched once per
    /// change of its `updated` stamp. Nil when that fetch fails; the search's comments stay then,
    /// and the next refresh tries again.
    private func comments(of issue: Issue) async -> [Comment]? {
        let updated = issue.fields.updated
        if let known = newestComments.withLock({ $0[issue.key] }), known.updated == updated {
            return known.comments
        }
        let query = [
            URLQueryItem(name: "orderBy", value: "-created"),
            URLQueryItem(name: "maxResults", value: String(Self.recentCommentLimit)),
        ]
        guard let data = try? await send(
                  path: "/rest/api/3/issue/\(issue.key)/comment", query: query, method: "GET", body: nil),
              let page = try? JSONDecoder().decode(Issue.Fields.Comments.self, from: data),
              let comments = try? Issue.newestFirst(page.comments)
        else { return nil }
        newestComments.withLock { $0[issue.key] = FetchedComments(updated: updated, comments: comments) }
        return comments
    }

    private func myAccountId() async throws -> String {
        if let cached = accountId.withLock({ $0 }) { return cached }
        let data = try await send(path: "/rest/api/3/myself", method: "GET", body: nil)
        let id: String
        do {
            id = try JSONDecoder().decode(Myself.self, from: data).accountId
        } catch {
            throw JiraError.decoding(String(describing: error))
        }
        accountId.withLock { $0 = id }
        return id
    }

    private func send(path: String, query: [URLQueryItem] = [], method: String, body: Data?) async throws -> Data {
        let url = credentials.site.appending(path: path)
        var request = URLRequest(url: query.isEmpty ? url : url.appending(queryItems: query))
        request.httpMethod = method
        request.httpBody = body
        let login = Data("\(credentials.email):\(credentials.token)".utf8).base64EncodedString()
        request.setValue("Basic \(login)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("DevPulse", forHTTPHeaderField: "User-Agent")
        let (data, http) = try await transport.send(request)
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw JiraError.unauthorized
        default: throw JiraError.http(http.statusCode)
        }
    }

    // MARK: - Mapping

    private func decode(_ data: Data) throws -> [Issue] {
        try mapped { try JSONDecoder().decode(SearchResponse.self, from: data).issues }
    }

    /// Runs a mapping step; any failure other than a `JiraError` becomes `.decoding`.
    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as JiraError {
            throw error
        } catch {
            throw JiraError.decoding(String(describing: error))
        }
    }

    // MARK: - Wire types

    private struct Myself: Decodable { var accountId: String }

    private struct SearchResponse: Decodable { var issues: [Issue] }

    private struct Issue: Decodable {
        struct Fields: Decodable {
            struct Status: Decodable {
                struct Category: Decodable { var key: String }
                var name: String
                var statusCategory: Category
            }
            struct Priority: Decodable { var name: String }
            struct Comments: Decodable {
                var total: Int?
                var comments: [CommentNode]
            }
            var summary: String
            var status: Status
            var priority: Priority?
            var updated: String
            var comment: Comments?
        }
        struct CommentNode: Decodable {
            struct Author: Decodable {
                var accountId: String?
                var displayName: String?
                var accountType: String?
            }
            var id: String
            var author: Author?
            var created: String

            func comment() throws -> Comment {
                Comment(
                    id: id, author: author?.accountId ?? "", authorName: author?.displayName,
                    authorKind: author?.accountType == "atlassian" ? .human : .bot,
                    createdAt: try JiraDate.parse(created))
            }
        }

        var key: String
        var fields: Fields

        /// The search returned fewer comments than the ticket has, so the newest may be missing.
        var commentsTruncated: Bool {
            guard let comment = fields.comment, let total = comment.total else { return false }
            return total > comment.comments.count
        }

        func ticket(site: URL) throws -> Ticket {
            let nodes = fields.comment?.comments ?? []
            let recent = try Self.newestFirst(nodes)
            return Ticket(
                key: key, summary: fields.summary, status: fields.status.name,
                statusCategory: Self.category(fields.status.statusCategory.key),
                priority: fields.priority?.name,
                url: site.appending(path: "browse/\(key)").absoluteString,
                updatedAt: try JiraDate.parse(fields.updated),
                commentCount: fields.comment?.total ?? nodes.count,
                lastCommentAt: recent.first?.createdAt,
                recentComments: recent)
        }

        /// The newest `recentCommentLimit` comments, newest first.
        static func newestFirst(_ nodes: [CommentNode]) throws -> [Comment] {
            let all = try nodes.map { try $0.comment() }
            return Array(all.sorted { $0.createdAt > $1.createdAt }.prefix(JiraSource.recentCommentLimit))
        }

        private static func category(_ key: String) -> StatusCategory {
            switch key {
            case "new": .todo
            case "done": .done
            default: .inProgress
            }
        }
    }
}

/// Jira dates: `2026-11-19T10:15:30.123+0100` (offset without colon); also tolerates
/// a colon offset, `Z` and missing fractional seconds.
enum JiraDate {
    /// Built once, one per pattern, and never changed afterwards. `DateFormatter` is `Sendable`
    /// and thread-safe, so concurrent fetches can share them; only setting `dateFormat` per call
    /// (as a single shared formatter would need) would race.
    private static let formatters: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXX", "yyyy-MM-dd'T'HH:mm:ssXXX",
    ].map { pattern in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }

    static func parse(_ text: String) throws -> Date {
        for formatter in formatters {
            if let date = formatter.date(from: text) { return date }
        }
        throw JiraError.decoding("bad date: \(text)")
    }
}
