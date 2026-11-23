import Foundation
import os
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

/// The answer to a launcher lookup: the tickets Jira returned, and the asked-for keys it said
/// do not exist (or that I may not see).
public struct TicketLookup: Sendable, Equatable {
    public var tickets: [Ticket]
    public var missingKeys: Set<String>

    public init(tickets: [Ticket], missingKeys: Set<String>) {
        self.tickets = tickets
        self.missingKeys = missingKeys
    }
}

/// Fetches the user's open Jira Cloud tickets and their recent comments (REST v3).
public final class JiraSource: Sendable {
    static let jql = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
    static let fields = ["summary", "status", "priority", "updated", "comment", "issuelinks"]
    /// The same without `comment`: comments on tickets that are not mine are never shown or
    /// notified, and they would be most of the bulk fetch's answer.
    static let linkedFields = fields.filter { $0 != "comment" }
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
        let issues = try await search(Self.jql)
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

    /// The tickets with these keys, e.g. those of PRs that are not mine: one bulk fetch
    /// (`POST /rest/api/3/issue/bulkfetch`) with `linkedFields`, for at most the
    /// first `maxResults` keys, and no request at all without keys. Unlike a JQL `key in (…)`,
    /// a key that does not exist or that I may not see does not fail the others: Jira lists it
    /// under `issueErrors`, which is left out. They come without comments and never notify.
    public func fetchTickets(keys: [String]) async throws -> [Ticket] {
        try await lookUpTickets(keys: keys).tickets
    }

    /// `fetchTickets(keys:)` that also says which keys Jira named under `issueErrors`: those
    /// that do not exist or that I may not see. A ticket moved to another project comes back
    /// under its new key and is in neither list.
    public func lookUpTickets(keys: [String]) async throws -> TicketLookup {
        let keys = Array(keys.prefix(Self.maxResults))
        guard !keys.isEmpty else { return TicketLookup(tickets: [], missingKeys: []) }
        let body = try JSONSerialization.data(withJSONObject: [
            "issueIdsOrKeys": keys, "fields": Self.linkedFields,
        ] as [String: Any])
        let data = try await send(path: "/rest/api/3/issue/bulkfetch", method: "POST", body: body)
        let response = try mapped { try JSONDecoder().decode(BulkResponse.self, from: data) }
        let errors = response.issueErrors ?? []
        if !errors.isEmpty {
            Self.log.debug("Bulk fetch could not return \(errors.count, privacy: .public) of the tickets")
        }
        let tickets = try response.issues.map { issue in try mapped { try issue.ticket(site: credentials.site) } }
        // Jira's schema calls an error's `id` "the ID of the issue"; for a key that does not exist
        // it is the key as asked for. Should an answer name none of the keys, but have one error
        // for each key that did not come back, those keys are the missing ones.
        let requested = Set(keys)
        let named = Set(errors.compactMap(\.id)).intersection(requested)
        let unreturned = requested.subtracting(tickets.map(\.key))
        let missing = named.isEmpty && !errors.isEmpty && errors.count == unreturned.count ? unreturned : named
        return TicketLookup(tickets: tickets, missingKeys: missing)
    }

    private static let log = Logger(subsystem: "io.jp4.devpulse", category: "jira")

    /// The most tickets a word search returns.
    static let textSearchLimit = 20

    /// The tickets of these projects whose summary has every word (each as a prefix), newest
    /// first: one JQL search, for the launcher. Nothing is sent without words or projects.
    public func searchTickets(words: [String], projects: [String]) async throws -> [Ticket] {
        let projects = projects.filter { $0.wholeMatch(of: /[A-Z][A-Z0-9_]*/) != nil }
        // `SearchWords` lets only letters, digits, `-`, `_` and `.` through: nothing to escape.
        let terms = words.filter { !$0.isEmpty && !$0.contains("\"") && !$0.contains("\\") }
        guard !projects.isEmpty, !terms.isEmpty else { return [] }
        // A wildcard term is not analysed (no plurals, no split at `-`): the plain words, or with
        // the last one, still being typed, as a prefix.
        let phrase = terms.joined(separator: " ")
        let jql = "project in (\(projects.joined(separator: ", "))) AND "
            + "(summary ~ \"\(phrase)\" OR summary ~ \"\(phrase)*\") ORDER BY updated DESC"
        let issues = try await search(jql, fields: Self.linkedFields, maxResults: Self.textSearchLimit)
        return try issues.map { issue in try mapped { try issue.ticket(site: credentials.site) } }
    }

    private func search(
        _ jql: String, fields: [String] = JiraSource.fields, maxResults: Int = JiraSource.maxResults
    ) async throws -> [Issue] {
        let body = try JSONSerialization.data(withJSONObject: [
            "jql": jql, "fields": fields, "maxResults": maxResults,
        ] as [String: Any])
        return try decode(try await send(path: "/rest/api/3/search/jql", method: "POST", body: body))
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

    /// The bulk fetch's answer: the issues found, and one entry per key it could not return,
    /// naming that key (`id`, as it was asked for).
    private struct BulkResponse: Decodable {
        struct IssueError: Decodable { var id: String? }
        var issues: [Issue]
        var issueErrors: [IssueError]?

        /// `issues` may be left out when no key was found.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
            issueErrors = try c.decodeIfPresent([IssueError].self, forKey: .issueErrors)
        }

        private enum CodingKeys: String, CodingKey { case issues, issueErrors }
    }

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
            var issuelinks: [Link]?
        }
        /// One entry of `issuelinks`: the other ticket is the `outwardIssue` (this one "blocks"
        /// it) or the `inwardIssue` (this one "is blocked by" it). Everything is optional, so an
        /// odd link never fails the search; a link without a key is left out.
        struct Link: Decodable {
            struct LinkType: Decodable {
                var name: String?
                var inward: String?
                var outward: String?
            }
            struct LinkedIssue: Decodable {
                struct Fields: Decodable {
                    struct Status: Decodable {
                        var name: String?
                        var statusCategory: Issue.Fields.Status.Category?
                    }
                    var summary: String?
                    var status: Status?
                }
                var key: String?
                var fields: Fields?
            }
            var type: LinkType?
            var inwardIssue: LinkedIssue?
            var outwardIssue: LinkedIssue?

            var related: RelatedTicket? {
                let other: LinkedIssue?, relation: String?
                if let outwardIssue {
                    (other, relation) = (outwardIssue, type?.outward)
                } else {
                    (other, relation) = (inwardIssue, type?.inward)
                }
                guard let other, let key = other.key else { return nil }
                let status = other.fields?.status
                return RelatedTicket(
                    key: key, summary: other.fields?.summary ?? "", status: status?.name ?? "",
                    statusCategory: status?.statusCategory.map { Issue.category($0.key) } ?? .todo,
                    relation: relation ?? type?.name ?? "")
            }
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
                recentComments: recent,
                related: (fields.issuelinks ?? []).compactMap(\.related))
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
