import Foundation
import Testing
@testable import DevPulseCore

@Suite("Model")
struct ModelTests {

    /// The shared JSON contract, read by path so the test target needs no resources.
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("protocol/fixtures/snapshot-v1.json")

    private static func loadFixture() throws -> Snapshot {
        try Snapshot.decoder.decode(Snapshot.self, from: Data(contentsOf: fixtureURL))
    }

    @Test("Fixture decodes and round-trips")
    func fixtureDecodesAndRoundTrips() throws {
        let snapshot = try Self.loadFixture()
        let reencoded = try Snapshot.encoder.encode(snapshot)
        #expect(try Snapshot.decoder.decode(Snapshot.self, from: reencoded) == snapshot)
    }

    @Test("Fixture holds the expected content")
    func fixtureContent() throws {
        let snapshot = try Self.loadFixture()
        #expect(snapshot.myPullRequests.count == 2)
        #expect(snapshot.myPullRequests.filter { $0.jiraKey != nil }.count == 1)
        #expect(snapshot.reviewRequests.count == 2)
        #expect(snapshot.reviewRequests.map(\.requestedDirectly) == [true, false])
        #expect(snapshot.tickets.count == 2)
        #expect(snapshot.tickets.contains { $0.summary.contains("žluťoučkých koní") })
        #expect(snapshot.sessions.map(\.status) == [.busy, .waiting, .idle])
        #expect(snapshot.sessions[1].waitingFor == "permission prompt")
        #expect(snapshot.sessions[2].jiraKey == "STORE-2290")
        #expect(snapshot.tickets.flatMap(\.recentComments).contains { $0.authorName != nil })
        #expect(snapshot.generatedAt == Date(timeIntervalSince1970: 1_795_082_400))
    }

    @Test("Fixture holds head repositories, related tickets and linked tickets")
    func fixtureLinks() throws {
        let snapshot = try Self.loadFixture()
        #expect(snapshot.myPullRequests.map(\.headRepo) == ["acmecorp/store", "jiripisa/devpulse"])
        #expect(snapshot.reviewRequests[0].headRepo == "alice-dev/store")  // from a fork
        #expect(snapshot.tickets[0].related == [
            RelatedTicket(
                key: "STORE-2474", summary: "Replace invoice order", status: "To Do",
                statusCategory: .todo, relation: "blocks"),
            RelatedTicket(
                key: "PAY-310", summary: "Payment gateway returns stale invoice totals", status: "In Review",
                statusCategory: .inProgress, relation: "is blocked by"),
        ])
        #expect(snapshot.linkedTickets.map(\.key) == ["WEB-77"])
        #expect(snapshot.linkedTickets[0].related.map(\.relation) == ["is caused by"])
        #expect(snapshot.reviewRequests[1].jiraKey == "WEB-77")
    }

    @Test("A snapshot without head repositories, related or linked tickets still decodes")
    func olderSnapshotDecodes() throws {
        var json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtureURL)) as? [String: Any])
        func strip(_ key: String, from list: String) {
            json[list] = (json[list] as? [[String: Any]])?.map { item in
                var item = item
                item[key] = nil
                return item
            }
        }
        json["linkedTickets"] = nil
        strip("related", from: "tickets")
        strip("headRepo", from: "myPullRequests")
        strip("headRepo", from: "reviewRequests")
        let data = try JSONSerialization.data(withJSONObject: json)
        let snapshot = try Snapshot.decoder.decode(Snapshot.self, from: data)
        #expect(snapshot.linkedTickets.isEmpty)
        #expect(snapshot.tickets.count == 2)
        #expect(snapshot.tickets.allSatisfy { $0.related.isEmpty })
        #expect((snapshot.myPullRequests + snapshot.reviewRequests).allSatisfy { $0.headRepo == nil })
    }

    @Test("Absent optionals are not encoded")
    func absentOptionalsAreOmitted() throws {
        let session = ClaudeSession(pid: 1, name: "n", cwd: "/", status: .idle, updatedAt: Date(timeIntervalSince1970: 0))
        let json = try #require(String(data: Snapshot.encoder.encode(session), encoding: .utf8))
        #expect(!json.contains("waitingFor"))
        #expect(!json.contains("jiraKey"))
    }

    @Test("Unknown session status decodes as unknown")
    func unknownSessionStatusDecodesAsUnknown() throws {
        let json = #"{"pid":1,"name":"n","cwd":"/","status":"thinking","updatedAt":"2026-11-19T10:00:00Z"}"#
        let session = try Snapshot.decoder.decode(ClaudeSession.self, from: Data(json.utf8))
        #expect(session.status == .unknown)
    }

    @Test("Unknown check state and review decision decode as none")
    func unknownChecksAndReviewDecodeAsNone() throws {
        #expect(try Snapshot.decoder.decode(CheckState.self, from: Data(#""stale""#.utf8)) == .none)
        #expect(try Snapshot.decoder.decode(ReviewDecision.self, from: Data(#""dismissed""#.utf8)) == .none)
    }
}
