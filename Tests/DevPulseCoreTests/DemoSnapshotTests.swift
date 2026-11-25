import Foundation
import Testing
@testable import DevPulseCore

@Suite("Demo snapshot")
struct DemoSnapshotTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let fixtureURL = root.appendingPathComponent("protocol/fixtures/snapshot-v1.json")
    private static let demoURL = root.appendingPathComponent("scripts/demo-snapshot.json")

    private static func fixture() throws -> Snapshot {
        try Snapshot.decoder.decode(Snapshot.self, from: Data(contentsOf: fixtureURL))
    }

    @Test("A demo answers devpulse upgrade with a failure instead of updating")
    func upgradeRefused() {
        #expect(DemoSnapshot.upgradeReport == UpgradeReport(.failed, message: "Not available in demo mode."))
    }

    @Test("Loading moves every date so that generatedAt is now")
    func loadingMovesEveryDate() throws {
        let original = try Self.fixture()
        let hour: TimeInterval = 3600
        let now = original.generatedAt.addingTimeInterval(hour)
        let demo = try DemoSnapshot.load(from: Self.fixtureURL, now: now)

        #expect(demo.generatedAt == now)
        #expect(demo.sources.github.lastSuccess == original.sources.github.lastSuccess?.addingTimeInterval(hour))
        #expect(demo.sources.jira.lastSuccess == original.sources.jira.lastSuccess?.addingTimeInterval(hour))
        #expect(demo.sources.claude.lastSuccess == original.sources.claude.lastSuccess?.addingTimeInterval(hour))
        let pr = demo.myPullRequests[0], originalPR = original.myPullRequests[0]
        #expect(pr.updatedAt == originalPR.updatedAt.addingTimeInterval(hour))
        #expect(pr.lastCommentAt == originalPR.lastCommentAt?.addingTimeInterval(hour))
        #expect(pr.recentComments.map(\.createdAt) == originalPR.recentComments.map { $0.createdAt.addingTimeInterval(hour) })
        #expect(demo.reviewRequests[0].updatedAt == original.reviewRequests[0].updatedAt.addingTimeInterval(hour))
        let ticket = demo.tickets[0], originalTicket = original.tickets[0]
        #expect(ticket.updatedAt == originalTicket.updatedAt.addingTimeInterval(hour))
        #expect(ticket.lastCommentAt == originalTicket.lastCommentAt?.addingTimeInterval(hour))
        #expect(ticket.recentComments.map(\.createdAt) == originalTicket.recentComments.map { $0.createdAt.addingTimeInterval(hour) })
        #expect(demo.sessions.map(\.updatedAt) == original.sessions.map { $0.updatedAt.addingTimeInterval(hour) })
        let linked = demo.linkedTickets[0], originalLinked = original.linkedTickets[0]
        #expect(linked.updatedAt == originalLinked.updatedAt.addingTimeInterval(hour))
        #expect(linked.lastCommentAt == originalLinked.lastCommentAt?.addingTimeInterval(hour))
        #expect(linked.recentComments.map(\.createdAt) == originalLinked.recentComments.map { $0.createdAt.addingTimeInterval(hour) })
        #expect(demo.createdTickets.map(\.updatedAt) == original.createdTickets.map { $0.updatedAt.addingTimeInterval(hour) })
    }

    @Test("Moving by zero changes nothing")
    func movingByZeroChangesNothing() throws {
        let original = try Self.fixture()
        #expect(original.shifted(by: 0) == original)
    }

    @Test("The demo data in scripts/ decodes")
    func demoDataDecodes() throws {
        let demo = try DemoSnapshot.load(from: Self.demoURL, now: Date())
        #expect(!demo.myPullRequests.isEmpty)
        #expect(!demo.reviewRequests.isEmpty)
        #expect(!demo.tickets.isEmpty)
        #expect(demo.sessions.map(\.status) == [.busy, .waiting, .idle])
        #expect(demo.tickets.count == 5)
        #expect(demo.tickets.allSatisfy { !$0.related.isEmpty })
        #expect(demo.linkedTickets.map(\.key) == LinkedTickets.keys(for: demo))
        #expect(!demo.linkedTickets.isEmpty)
        #expect(demo.createdTickets.count == 2)
        #expect(demo.createdTicketStatuses == ["In Review"])
    }

    @Test("A bare number in the demo finds a pull request, a ticket and a session")
    func demoNumberFindsEveryKind() throws {
        let demo = try DemoSnapshot.load(from: Self.demoURL, now: Date())
        let kinds = LauncherResolver.items(for: .parse("2290"), snapshot: demo, settings: AppSettings()).map(\.kind)
        #expect(kinds.contains { if case .reviewRequest = $0 { true } else { false } })
        #expect(kinds.contains(.ticket))
        #expect(kinds.contains { if case .session = $0 { true } else { false } })
    }
}
