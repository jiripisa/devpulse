import Foundation
import Synchronization
import Testing
@testable import DevPulseCore

private final class FakeJiraTransport: HTTPTransport {
    let status: Int
    let search: Mutex<Data>
    /// Bodies of `GET /rest/api/3/issue/<key>/comment`, by path.
    let comments: [String: Data]
    let requests = Mutex<[URLRequest]>([])

    init(status: Int = 200, search: Data, comments: [String: Data] = [:]) {
        self.status = status
        self.search = Mutex(search)
        self.comments = comments
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        let path = request.url?.path ?? ""
        let body = path == "/rest/api/3/myself" ? Data(#"{"accountId":"acc-me"}"#.utf8)
            : comments[path] ?? search.withLock { $0 }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    func requests(to path: String) -> [URLRequest] {
        requests.withLock { $0 }.filter { $0.url?.path == path }
    }
}

/// A search whose one ticket has 25 comments but returns only the two oldest.
private func truncatedSearch(updated: String) -> Data {
    let comment = { (id: Int) in
        #"{ "id": "\#(id)", "author": { "accountId": "acc-a", "accountType": "atlassian" }, "created": "2026-11-\#(String(format: "%02d", id))T10:00:00.000+0100" }"#
    }
    return Data("""
        { "issues": [ { "key": "BIG-1", "fields": {
          "summary": "Busy", "status": { "name": "To Do", "statusCategory": { "key": "new" } },
          "updated": "\(updated)",
          "comment": { "total": 25, "maxResults": 2, "comments": [\(comment(1)), \(comment(2))] } } } ] }
        """.utf8)
}

/// The per-ticket answer: the 10 newest of the 25 comments, newest first.
private let newestComments: Data = {
    let items = (16...25).reversed().map { id in
        #"{ "id": "\#(id)", "author": { "accountId": "acc-a", "accountType": "atlassian" }, "created": "2026-11-\#(id)T10:00:00.000+0100" }"#
    }
    return Data(#"{ "total": 25, "comments": [\#(items.joined(separator: ","))] }"#.utf8)
}()

@Suite("Jira source")
struct JiraTests {

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/jira-search.json")

    private static func fixture() throws -> Data { try Data(contentsOf: fixtureURL) }

    private static let credentials = JiraCredentials(
        site: URL(string: "https://example.atlassian.net")!, email: "me@example.com", token: "tok")

    private static func make(status: Int = 200) throws -> (JiraSource, FakeJiraTransport) {
        let transport = FakeJiraTransport(status: status, search: try fixture())
        return (JiraSource(credentials: credentials, transport: transport), transport)
    }

    @Test("Sends Basic auth with email:token")
    func basicAuth() async throws {
        let (source, transport) = try Self.make()
        _ = try await source.fetch()
        let expected = "Basic " + Data("me@example.com:tok".utf8).base64EncodedString()
        let requests = transport.requests.withLock { $0 }
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
        }
    }

    @Test("Posts the JQL search with the wanted fields")
    func searchRequest() async throws {
        let (source, transport) = try Self.make()
        _ = try await source.fetch()
        let search = try #require(transport.requests.withLock { $0 }.first { $0.url?.path == "/rest/api/3/search/jql" })
        #expect(search.httpMethod == "POST")
        let body = try #require(search.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["jql"] as? String == "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC")
        #expect(json["fields"] as? [String] == ["summary", "status", "priority", "updated", "comment"])
        #expect(json["maxResults"] as? Int == 50)
    }

    @Test("Maps status category, url, priority and the offset date")
    func mapping() async throws {
        let (source, _) = try Self.make()
        let result = try await source.fetch()
        #expect(result.myAccountId == "acc-me")
        #expect(result.tickets.map(\.key) == ["SYN-1", "SYN-2", "SYN-3"])
        #expect(result.tickets.map(\.statusCategory) == [.todo, .inProgress, .done])
        let first = result.tickets[0]
        #expect(first.url == "https://example.atlassian.net/browse/SYN-1")
        #expect(first.summary == "First synthetic ticket")
        #expect(first.status == "To Do")
        #expect(first.priority == "High")
        #expect(result.tickets[1].priority == nil)
        // 2026-11-19T10:15:30.123+0100 == 09:15:30.123Z
        #expect(abs(first.updatedAt.timeIntervalSince1970 - 1_795_079_730.123) < 0.001)
        #expect(result.tickets[1].updatedAt == Date(timeIntervalSince1970: 1_795_086_000))  // 11:00Z
    }

    @Test("Maps comments: accountId as author, kind from accountType, newest first")
    func comments() async throws {
        let (source, _) = try Self.make()
        let first = try await source.fetch().tickets[0]
        #expect(first.commentCount == 3)
        #expect(first.recentComments.map(\.id) == ["9003", "9002", "9001"])
        #expect(first.lastCommentAt == first.recentComments[0].createdAt)
        let byId = Dictionary(uniqueKeysWithValues: first.recentComments.map { ($0.id, $0) })
        #expect(byId["9001"]?.author == "acc-alice")
        #expect(byId["9001"]?.authorName == "Alice Example")
        #expect(byId["9001"]?.authorKind == .human)
        #expect(byId["9002"]?.authorKind == .bot)
    }

    @Test("Keeps the last 10 comments; non-atlassian or missing account types are bots")
    func commentLimit() async throws {
        let (source, _) = try Self.make()
        let third = try await source.fetch().tickets[2]
        #expect(third.commentCount == 12)
        #expect(third.recentComments.count == 10)
        #expect(third.recentComments.first?.id == "12")
        #expect(third.recentComments.first?.authorKind == .bot)  // no accountType
        #expect(third.recentComments.first?.author == "")  // no accountId
        #expect(third.recentComments.last?.id == "3")
        #expect(third.recentComments.contains { $0.id == "1" } == false)
    }

    @Test("A ticket without comments has no lastCommentAt")
    func noComments() async throws {
        let (source, _) = try Self.make()
        let second = try await source.fetch().tickets[1]
        #expect(second.commentCount == 0)
        #expect(second.lastCommentAt == nil)
        #expect(second.recentComments.isEmpty)
    }

    @Test("Calls /myself on the first fetch only")
    func myselfCached() async throws {
        let (source, transport) = try Self.make()
        _ = try await source.fetch()
        _ = try await source.fetch()
        let myself = transport.requests.withLock { $0 }.filter { $0.url?.path == "/rest/api/3/myself" }
        #expect(myself.count == 1)
    }

    private static let bigComments = "/rest/api/3/issue/BIG-1/comment"

    private static func truncated() -> (JiraSource, FakeJiraTransport) {
        let transport = FakeJiraTransport(
            search: truncatedSearch(updated: "2026-11-19T10:00:00.000+0100"),
            comments: [bigComments: newestComments])
        return (JiraSource(credentials: credentials, transport: transport), transport)
    }

    @Test("A truncated comment field fetches the newest comments of that ticket once")
    func truncatedComments() async throws {
        let (source, transport) = Self.truncated()
        let ticket = try #require(try await source.fetch().tickets.first)
        let fetches = transport.requests(to: Self.bigComments)
        #expect(fetches.count == 1)
        let query = URLComponents(url: try #require(fetches.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.contains(URLQueryItem(name: "orderBy", value: "-created")) == true)
        #expect(query?.contains(URLQueryItem(name: "maxResults", value: "10")) == true)
        #expect(fetches.first?.httpMethod == "GET")
        #expect(ticket.recentComments.map(\.id) == (16...25).reversed().map(String.init))
        #expect(ticket.lastCommentAt == ticket.recentComments.first?.createdAt)
        #expect(ticket.commentCount == 25)
    }

    @Test("An unchanged updated stamp reuses the comments without another fetch")
    func unchangedTicketNoRefetch() async throws {
        let (source, transport) = Self.truncated()
        _ = try await source.fetch()
        let again = try #require(try await source.fetch().tickets.first)
        #expect(transport.requests(to: Self.bigComments).count == 1)
        #expect(again.recentComments.first?.id == "25")
        transport.search.withLock { $0 = truncatedSearch(updated: "2026-11-19T11:00:00.000+0100") }
        _ = try await source.fetch()
        #expect(transport.requests(to: Self.bigComments).count == 2)
    }

    @Test("A complete comment field needs no per-ticket fetch")
    func completeCommentsNoFetch() async throws {
        let (source, transport) = try Self.make()
        _ = try await source.fetch()
        let paths = transport.requests.withLock { $0 }.compactMap { $0.url?.path }
        #expect(paths.allSatisfy { !$0.hasPrefix("/rest/api/3/issue/") })
    }

    @Test("401 and 403 are unauthorized, other statuses are http errors", arguments: [401, 403])
    func unauthorized(status: Int) async throws {
        let (source, _) = try Self.make(status: status)
        await #expect(throws: JiraError.unauthorized) { try await source.fetch() }
    }

    @Test("Other failures carry the status code")
    func httpError() async throws {
        let (source, _) = try Self.make(status: 500)
        await #expect(throws: JiraError.http(500)) { try await source.fetch() }
    }

    @Test("Parses Jira date variants")
    func dates() throws {
        let expected = Date(timeIntervalSince1970: 1_795_079_730)  // 09:15:30Z
        #expect(try JiraDate.parse("2026-11-19T10:15:30.000+0100") == expected)
        #expect(try JiraDate.parse("2026-11-19T10:15:30+0100") == expected)
        #expect(try JiraDate.parse("2026-11-19T10:15:30.000+01:00") == expected)
        #expect(try JiraDate.parse("2026-11-19T09:15:30Z") == expected)
        #expect(throws: JiraError.self) { try JiraDate.parse("yesterday") }
    }
}
