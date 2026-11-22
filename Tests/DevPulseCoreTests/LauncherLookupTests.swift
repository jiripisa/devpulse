import Foundation
import Synchronization
import Testing
@testable import DevPulseCore

private struct Offline: Error {}

/// Answers the lookups from fixed data and records every call.
private final class FakeLookups: Sendable {
    let tickets = Mutex<Result<[Ticket], any Error>>(.success([]))
    let pullRequests = Mutex<[PullRequestRef: Result<PullRequestSummary?, any Error>]>([:])
    let ticketCalls = Mutex<[[String]]>([])
    let pullRequestCalls = Mutex<[PullRequestRef]>([])
    let clock = Mutex(Date(timeIntervalSince1970: 1_000))

    @MainActor func lookup(ttl: TimeInterval = 300) -> LauncherLookup {
        LauncherLookup(
            ttl: ttl, now: { self.clock.withLock { $0 } },
            fetchTickets: { keys in
                self.ticketCalls.withLock { $0.append(keys) }
                return try self.tickets.withLock { $0 }.get()
            },
            fetchPullRequest: { ref in
                self.pullRequestCalls.withLock { $0.append(ref) }
                return try (self.pullRequests.withLock { $0[ref] } ?? .success(nil)).get()
            })
    }

    func advance(_ seconds: TimeInterval) { clock.withLock { $0 += seconds } }
}

@Suite @MainActor struct LauncherLookupTests {
    private let store = PullRequestRef(repo: "acme/store", number: 7)

    private func summary(_ title: String) -> PullRequestSummary {
        PullRequestSummary(repo: "acme/store", number: 7, title: title, state: .open, url: "https://github.com/acme/store/pull/7")
    }

    @Test func asksJiraOnceForAllKeysAndRecordsFoundAndMissing() async {
        let fake = FakeLookups()
        fake.tickets.withLock { $0 = .success([makeTicket(key: "WA-7")]) }
        let lookup = fake.lookup()
        await lookup.resolve(LookupRequest(ticketKeys: ["STORE-7", "WA-7"]))
        #expect(fake.ticketCalls.withLock { $0 } == [["STORE-7", "WA-7"]])
        #expect(lookup.results.tickets.keys.sorted() == ["WA-7"])
        #expect(lookup.results.missingTickets == ["STORE-7"])
    }

    @Test func remembersAnswersForTheTTL() async {
        let fake = FakeLookups()
        fake.pullRequests.withLock { $0[store] = .success(summary("Seven")) }
        let lookup = fake.lookup(ttl: 300)
        let request = LookupRequest(ticketKeys: ["WA-7"], pullRequests: [store])
        await lookup.resolve(request)
        fake.advance(299)
        await lookup.resolve(request)
        #expect(fake.ticketCalls.withLock { $0.count } == 1)
        #expect(fake.pullRequestCalls.withLock { $0.count } == 1)
        fake.advance(2)
        await lookup.resolve(request)
        #expect(fake.ticketCalls.withLock { $0.count } == 2)
        #expect(fake.pullRequestCalls.withLock { $0.count } == 2)
        // Only what is not fresh is asked for.
        await lookup.resolve(LookupRequest(ticketKeys: ["WA-7", "OPS-7"]))
        #expect(fake.ticketCalls.withLock { $0.last } == ["OPS-7"])
    }

    @Test func aFailedLookupRemembersNothing() async {
        let fake = FakeLookups()
        fake.tickets.withLock { $0 = .failure(Offline()) }
        fake.pullRequests.withLock { $0[store] = .failure(Offline()) }
        let lookup = fake.lookup()
        let request = LookupRequest(ticketKeys: ["WA-7"], pullRequests: [store])
        await lookup.resolve(request)
        #expect(lookup.results == LookupResults())
        await lookup.resolve(request)
        #expect(fake.ticketCalls.withLock { $0.count } == 2)
        #expect(fake.pullRequestCalls.withLock { $0.count } == 2)
    }

    @Test func aPullRequestThatDoesNotExistIsMissing() async {
        let fake = FakeLookups()
        let lookup = fake.lookup(ttl: 0)
        await lookup.resolve(LookupRequest(pullRequests: [store]))
        #expect(lookup.results.missingPullRequests == [store])
        fake.pullRequests.withLock { $0[store] = .success(summary("Seven")) }
        await lookup.resolve(LookupRequest(pullRequests: [store]))
        #expect(lookup.results.missingPullRequests.isEmpty)
        #expect(lookup.results.pullRequests[store]?.title == "Seven")
    }

    @Test func anEmptyRequestAsksNothing() async {
        let fake = FakeLookups()
        await fake.lookup().resolve(LookupRequest())
        #expect(fake.ticketCalls.withLock { $0.isEmpty })
        #expect(fake.pullRequestCalls.withLock { $0.isEmpty })
    }
}
