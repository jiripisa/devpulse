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
