import Foundation
import Observation

/// A PR the launcher names by repo and number, e.g. `acme/store#2474`. The repo compares
/// without case, as GitHub does.
public struct PullRequestRef: Hashable, Sendable {
    public var repo: String
    public var number: Int

    public init(repo: String, number: Int) {
        self.repo = repo
        self.number = number
    }

    public static func == (a: PullRequestRef, b: PullRequestRef) -> Bool {
        a.number == b.number && a.repo.lowercased() == b.repo.lowercased()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(repo.lowercased())
        hasher.combine(number)
    }
}

/// A PR found on GitHub by its number, for a launcher row of a PR that is not in my lists.
public struct PullRequestSummary: Equatable, Sendable {
    public enum State: String, Sendable {
        case open, draft, merged, closed

        public var text: String {
            switch self {
            case .open: "Open"
            case .draft: "Draft"
            case .merged: "Merged"
            case .closed: "Closed"
            }
        }
    }

    public var repo: String
    public var number: Int
    public var title: String
    public var state: State
    public var url: String

    public init(repo: String, number: Int, title: String, state: State, url: String) {
        self.repo = repo
        self.number = number
        self.title = title
        self.state = state
        self.url = url
    }
}

/// The tickets and PRs the launcher would show as bare "Open …" rows: what is worth asking
/// Jira and GitHub about, so the rows can show a title.
public struct LookupRequest: Equatable, Sendable {
    public var ticketKeys: [String]
    public var pullRequests: [PullRequestRef]

    public init(ticketKeys: [String] = [], pullRequests: [PullRequestRef] = []) {
        self.ticketKeys = ticketKeys
        self.pullRequests = pullRequests
    }

    public var isEmpty: Bool { ticketKeys.isEmpty && pullRequests.isEmpty }
}

/// What the lookups found, and what they found not to exist (or not visible to me).
public struct LookupResults: Equatable, Sendable {
    public var tickets: [String: Ticket] = [:]
    public var missingTickets: Set<String> = []
    public var pullRequests: [PullRequestRef: PullRequestSummary] = [:]
    public var missingPullRequests: Set<PullRequestRef> = []

    public init() {}
}

/// Looks up the launcher's "Open …" rows in Jira (one bulk fetch for all keys) and on GitHub
/// (one request per PR, normally one), and remembers the answers for `ttl` seconds, so typing
/// or reopening the launcher does not ask again. A failed lookup remembers nothing: its rows
/// stay "Open …" and the next query tries again.
@MainActor
@Observable
public final class LauncherLookup {
    public private(set) var results = LookupResults()

    public typealias TicketFetch = @Sendable ([String]) async throws -> [Ticket]
    public typealias PullRequestFetch = @Sendable (PullRequestRef) async throws -> PullRequestSummary?

    @ObservationIgnored private let fetchTickets: TicketFetch
    @ObservationIgnored private let fetchPullRequest: PullRequestFetch
    @ObservationIgnored private let ttl: TimeInterval
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var ticketsFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var pullRequestsFetchedAt: [PullRequestRef: Date] = [:]
    @ObservationIgnored private var ticketsInFlight: Set<String> = []
    @ObservationIgnored private var pullRequestsInFlight: Set<PullRequestRef> = []

    public init(
        ttl: TimeInterval = 300, now: @escaping () -> Date = { Date() },
        fetchTickets: @escaping TicketFetch, fetchPullRequest: @escaping PullRequestFetch
    ) {
        self.ttl = ttl
        self.now = now
        self.fetchTickets = fetchTickets
        self.fetchPullRequest = fetchPullRequest
    }

    /// Fetches what the request names and is neither fresh in the cache nor being fetched.
    public func resolve(_ request: LookupRequest) async {
        let moment = now()
        let keys = request.ticketKeys.filter { key in
            !ticketsInFlight.contains(key) && !(ticketsFetchedAt[key].map { moment.timeIntervalSince($0) < ttl } ?? false)
        }
        let refs = request.pullRequests.filter { ref in
            !pullRequestsInFlight.contains(ref)
                && !(pullRequestsFetchedAt[ref].map { moment.timeIntervalSince($0) < ttl } ?? false)
        }
        async let tickets: Void = lookUpTickets(keys)
        async let pullRequests: Void = lookUpPullRequests(refs)
        _ = await (tickets, pullRequests)
    }

    private func lookUpTickets(_ keys: [String]) async {
        guard !keys.isEmpty else { return }
        ticketsInFlight.formUnion(keys)
        defer { ticketsInFlight.subtract(keys) }
        guard let found = try? await fetchTickets(keys) else { return }
        let byKey = Dictionary(found.map { ($0.key, $0) }) { first, _ in first }
        let moment = now()
        for key in keys {
            ticketsFetchedAt[key] = moment
            if let ticket = byKey[key] {
                results.tickets[key] = ticket
                results.missingTickets.remove(key)
            } else {
                results.tickets.removeValue(forKey: key)
                results.missingTickets.insert(key)
            }
        }
    }

    private func lookUpPullRequests(_ refs: [PullRequestRef]) async {
        for ref in refs {
            pullRequestsInFlight.insert(ref)
            defer { pullRequestsInFlight.remove(ref) }
            // Not `try?`: it would flatten "not found" (nil) and "failed" into one.
            let answer: PullRequestSummary?
            do {
                answer = try await fetchPullRequest(ref)
            } catch {
                continue
            }
            pullRequestsFetchedAt[ref] = now()
            if let summary = answer {
                results.pullRequests[ref] = summary
                results.missingPullRequests.remove(ref)
            } else {
                results.pullRequests.removeValue(forKey: ref)
                results.missingPullRequests.insert(ref)
            }
        }
    }
}
