import Foundation
import Synchronization
import Testing
@testable import DevPulseCore

private struct Offline: Error {}

/// Answers the lookups from fixed data and records every call.
private final class FakeLookups: Sendable {
    let tickets = Mutex<Result<TicketLookup, any Error>>(.success(TicketLookup(tickets: [], missingKeys: [])))
    /// When set, every ticket lookup waits until it is released.
    let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let gated = Mutex(false)
    let pullRequests = Mutex<Result<PullRequestLookup, any Error>>(.success(PullRequestLookup()))
    let ticketCalls = Mutex<[[String]]>([])
    let pullRequestCalls = Mutex<[[PullRequestRef]]>([])
    let clock = Mutex(Date(timeIntervalSince1970: 1_000))

    @MainActor func lookup(ttl: TimeInterval = 300) -> LauncherLookup {
        LauncherLookup(
            ttl: ttl, now: { self.clock.withLock { $0 } },
            fetchTickets: { keys in
                self.ticketCalls.withLock { $0.append(keys) }
                if self.gated.withLock({ $0 }) {
                    await withCheckedContinuation { c in self.gate.withLock { $0 = c } }
                }
                return try self.tickets.withLock { $0 }.get()
            },
            fetchPullRequests: { refs in
                self.pullRequestCalls.withLock { $0.append(refs) }
                return try self.pullRequests.withLock { $0 }.get()
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
        fake.tickets.withLock { $0 = .success(TicketLookup(tickets: [makeTicket(key: "WA-7")], missingKeys: ["STORE-7"])) }
        let lookup = fake.lookup()
        await lookup.resolve(LookupRequest(ticketKeys: ["STORE-7", "WA-7"]))
        #expect(fake.ticketCalls.withLock { $0 } == [["STORE-7", "WA-7"]])
        #expect(lookup.results.tickets.keys.sorted() == ["WA-7"])
        #expect(lookup.results.missingTickets == ["STORE-7"])
    }

    @Test func remembersAnswersForTheTTL() async {
        let fake = FakeLookups()
        fake.pullRequests.withLock { $0 = .success(PullRequestLookup(found: [store: summary("Seven")])) }
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
        fake.pullRequests.withLock { $0 = .failure(Offline()) }
        let lookup = fake.lookup()
        let request = LookupRequest(ticketKeys: ["WA-7"], pullRequests: [store])
        await lookup.resolve(request)
        #expect(lookup.results == LookupResults())
        await lookup.resolve(request)
        #expect(fake.ticketCalls.withLock { $0.count } == 2)
        #expect(fake.pullRequestCalls.withLock { $0.count } == 2)
    }

    @Test func asksGitHubOnceForAllPullRequests() async {
        let fake = FakeLookups()
        let api = PullRequestRef(repo: "acme/api", number: 7)
        let web = PullRequestRef(repo: "acme/web", number: 7)
        fake.pullRequests.withLock { $0 = .success(PullRequestLookup(found: [store: summary("Seven")], missing: [api])) }
        let lookup = fake.lookup(ttl: 0)
        await lookup.resolve(LookupRequest(pullRequests: [store, api, web]))
        #expect(fake.pullRequestCalls.withLock { $0 } == [[store, api, web]])
        #expect(lookup.results.pullRequests[store]?.title == "Seven")
        #expect(lookup.results.missingPullRequests == [api])
        // GitHub said nothing about acme/web: neither found nor missing.
        #expect(lookup.results.pullRequests[web] == nil)
        // A PR found later is no longer missing.
        fake.pullRequests.withLock { $0 = .success(PullRequestLookup(found: [api: summary("Api")])) }
        await lookup.resolve(LookupRequest(pullRequests: [api]))
        #expect(lookup.results.missingPullRequests.isEmpty)
        #expect(lookup.results.pullRequests[api] != nil)
    }

    @Test func aKeyJiraSaysNothingAboutIsNeitherFoundNorMissing() async {
        let fake = FakeLookups()
        fake.tickets.withLock { $0 = .success(TicketLookup(tickets: [], missingKeys: [])) }
        let lookup = fake.lookup()
        await lookup.resolve(LookupRequest(ticketKeys: ["WA-7"]))
        #expect(lookup.results == LookupResults())
        // Still not asked again within the TTL.
        await lookup.resolve(LookupRequest(ticketKeys: ["WA-7"]))
        #expect(fake.ticketCalls.withLock { $0.count } == 1)
    }

    @Test func aTicketMovedToAnotherProjectIsFoundUnderItsOldKey() async {
        let fake = FakeLookups()
        var moved = makeTicket(key: "NEW-45")
        moved.summary = "Moved"
        fake.tickets.withLock { $0 = .success(TicketLookup(tickets: [moved], missingKeys: ["STORE-7"])) }
        let lookup = fake.lookup()
        await lookup.resolve(LookupRequest(ticketKeys: ["STORE-7", "OLD-7"]))
        #expect(lookup.results.tickets["OLD-7"]?.key == "NEW-45")
        #expect(lookup.results.missingTickets == ["STORE-7"])
        // Two unaccounted keys and one unasked ticket cannot be paired.
        fake.tickets.withLock { $0 = .success(TicketLookup(tickets: [moved], missingKeys: [])) }
        let other = fake.lookup()
        await other.resolve(LookupRequest(ticketKeys: ["A-7", "B-7"]))
        #expect(other.results == LookupResults())
    }

    @Test func overlappingLookupsAskOnce() async {
        let fake = FakeLookups()
        fake.gated.withLock { $0 = true }
        let lookup = fake.lookup()
        let request = LookupRequest(ticketKeys: ["WA-7"])
        let first = Task { await lookup.resolve(request) }
        while fake.gate.withLock({ $0 == nil }) { await Task.yield() }
        await lookup.resolve(request)
        #expect(fake.ticketCalls.withLock { $0.count } == 1)
        fake.gate.withLock { $0 }?.resume()
        await first.value
    }

    @Test func anEmptyRequestAsksNothing() async {
        let fake = FakeLookups()
        await fake.lookup().resolve(LookupRequest())
        #expect(fake.ticketCalls.withLock { $0.isEmpty })
        #expect(fake.pullRequestCalls.withLock { $0.isEmpty })
    }
}

@Suite struct LauncherSelectionTests {
    private let a = OpenTarget.url(URL(string: "https://a.test")!)
    private let b = OpenTarget.url(URL(string: "https://b.test")!)
    private let c = OpenTarget.url(URL(string: "https://c.test")!)

    @Test func keepsTheSelectedRowWhenRowsAboveItGo() {
        #expect(LauncherSelection.index(keeping: 2, from: [a, b, c], to: [a, c]) == 1)
        #expect(LauncherSelection.index(keeping: 0, from: [a, b], to: [b, a]) == 1)
    }

    @Test func clampsWhenTheSelectedRowIsGone() {
        #expect(LauncherSelection.index(keeping: 2, from: [a, b, c], to: [a, b]) == 1)
        #expect(LauncherSelection.index(keeping: 1, from: [a, b], to: [c, a]) == 1)
        #expect(LauncherSelection.index(keeping: 1, from: [a, b], to: []) == 0)
        #expect(LauncherSelection.index(keeping: 5, from: [a], to: [a, b]) == 1)
    }
}
