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
    /// The PR's branch, where its Jira key often is.
    public var headBranch: String?

    public init(repo: String, number: Int, title: String, state: State, url: String, headBranch: String? = nil) {
        self.repo = repo
        self.number = number
        self.title = title
        self.state = state
        self.url = url
        self.headBranch = headBranch
    }

    public var ref: PullRequestRef { PullRequestRef(repo: repo, number: number) }

    /// The Jira key in the title or branch, as for my own PRs.
    public func jiraKey(knownProjects: Set<String>) -> String? {
        JiraKey.find(inAny: [title, headBranch].compactMap { $0 }, knownProjects: knownProjects)
    }
}

/// A search for the PRs that name a Jira ticket, in these repositories.
public struct PullRequestSearch: Hashable, Sendable {
    public var key: String
    public var repos: [String]

    public init(key: String, repos: [String]) {
        self.key = key
        self.repos = repos
    }
}

/// The answer to a launcher lookup of PRs: those GitHub found, and those it says do not exist
/// (or that I may not see). A ref in neither is one the answer said nothing about.
public struct PullRequestLookup: Sendable, Equatable {
    public var found: [PullRequestRef: PullRequestSummary] = [:]
    public var missing: Set<PullRequestRef> = []

    public init(found: [PullRequestRef: PullRequestSummary] = [:], missing: Set<PullRequestRef> = []) {
        self.found = found
        self.missing = missing
    }
}

/// The tickets and PRs the launcher would show as bare "Open …" rows: what is worth asking
/// Jira and GitHub about, so the rows can show a title.
public struct LookupRequest: Equatable, Sendable {
    public var ticketKeys: [String]
    public var pullRequests: [PullRequestRef]
    /// The tickets whose PRs to search for, for an expanded ticket row.
    public var pullRequestSearches: [PullRequestSearch]

    public init(
        ticketKeys: [String] = [], pullRequests: [PullRequestRef] = [], pullRequestSearches: [PullRequestSearch] = []
    ) {
        self.ticketKeys = ticketKeys
        self.pullRequests = pullRequests
        self.pullRequestSearches = pullRequestSearches
    }

    public var isEmpty: Bool { ticketKeys.isEmpty && pullRequests.isEmpty && pullRequestSearches.isEmpty }
}

/// What the lookups found, and what they found not to exist (or not visible to me).
public struct LookupResults: Equatable, Sendable {
    public var tickets: [String: Ticket] = [:]
    public var missingTickets: Set<String> = []
    public var pullRequests: [PullRequestRef: PullRequestSummary] = [:]
    public var missingPullRequests: Set<PullRequestRef> = []
    /// The PRs GitHub's search found for a ticket key.
    public var pullRequestsForTicket: [String: [PullRequestSummary]] = [:]

    public init() {}
}

/// Looks up the launcher's "Open …" rows in Jira (one bulk fetch for all keys) and on GitHub
/// (one GraphQL request for all PRs), and remembers the answers for `ttl` seconds, so typing
/// or reopening the launcher does not ask again. A failed lookup remembers nothing: its rows
/// stay "Open …" and the next query tries again.
@MainActor
@Observable
public final class LauncherLookup {
    public private(set) var results = LookupResults()

    public typealias TicketFetch = @Sendable ([String]) async throws -> TicketLookup
    public typealias PullRequestFetch = @Sendable ([PullRequestRef]) async throws -> PullRequestLookup
    public typealias PullRequestSearchFetch = @Sendable (PullRequestSearch) async throws -> [PullRequestSummary]

    @ObservationIgnored private let fetchTickets: TicketFetch
    @ObservationIgnored private let fetchPullRequests: PullRequestFetch
    @ObservationIgnored private let searchPullRequests: PullRequestSearchFetch
    @ObservationIgnored private var searchedAt: [PullRequestSearch: Date] = [:]
    @ObservationIgnored private var searchesInFlight: Set<PullRequestSearch> = []
    @ObservationIgnored private let ttl: TimeInterval
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var ticketsFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var pullRequestsFetchedAt: [PullRequestRef: Date] = [:]
    @ObservationIgnored private var ticketsInFlight: Set<String> = []
    @ObservationIgnored private var pullRequestsInFlight: Set<PullRequestRef> = []

    public init(
        ttl: TimeInterval = 300, now: @escaping () -> Date = { Date() },
        fetchTickets: @escaping TicketFetch, fetchPullRequests: @escaping PullRequestFetch,
        searchPullRequests: @escaping PullRequestSearchFetch
    ) {
        self.searchPullRequests = searchPullRequests
        self.ttl = ttl
        self.now = now
        self.fetchTickets = fetchTickets
        self.fetchPullRequests = fetchPullRequests
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
        let searches = request.pullRequestSearches.filter { search in
            !searchesInFlight.contains(search) && !(searchedAt[search].map { moment.timeIntervalSince($0) < ttl } ?? false)
        }
        async let tickets: Void = lookUpTickets(keys)
        async let pullRequests: Void = lookUpPullRequests(refs)
        async let searched: Void = search(searches)
        _ = await (tickets, pullRequests, searched)
    }

    private func search(_ searches: [PullRequestSearch]) async {
        for search in searches {
            searchesInFlight.insert(search)
            defer { searchesInFlight.remove(search) }
            guard let found = try? await searchPullRequests(search) else { continue }
            searchedAt[search] = now()
            results.pullRequestsForTicket[search.key] = found
        }
    }

    private func lookUpTickets(_ keys: [String]) async {
        guard !keys.isEmpty else { return }
        ticketsInFlight.formUnion(keys)
        defer { ticketsInFlight.subtract(keys) }
        guard let answer = try? await fetchTickets(keys) else { return }
        let byKey = Dictionary(answer.tickets.map { ($0.key, $0) }) { first, _ in first }
        // A ticket moved to another project comes back under its new key: when exactly one
        // asked-for key is unaccounted for and exactly one ticket was not asked for, they are
        // the same ticket.
        let unaccounted = keys.filter { byKey[$0] == nil && !answer.missingKeys.contains($0) }
        let unasked = answer.tickets.filter { !keys.contains($0.key) }
        let moved = unaccounted.count == 1 && unasked.count == 1 ? [unaccounted[0]: unasked[0]] : [:]
        let moment = now()
        for key in keys {
            ticketsFetchedAt[key] = moment
            if let ticket = byKey[key] ?? moved[key] {
                results.tickets[key] = ticket
                results.missingTickets.remove(key)
            } else if answer.missingKeys.contains(key) {
                results.tickets.removeValue(forKey: key)
                results.missingTickets.insert(key)
            }
            // Otherwise Jira said nothing about it: the row stays "Open …".
        }
    }

    private func lookUpPullRequests(_ refs: [PullRequestRef]) async {
        guard !refs.isEmpty else { return }
        pullRequestsInFlight.formUnion(refs)
        defer { pullRequestsInFlight.subtract(refs) }
        guard let answer = try? await fetchPullRequests(refs) else { return }
        let moment = now()
        for ref in refs {
            pullRequestsFetchedAt[ref] = moment
            if let summary = answer.found[ref] {
                results.pullRequests[ref] = summary
                results.missingPullRequests.remove(ref)
            } else if answer.missing.contains(ref) {
                results.pullRequests.removeValue(forKey: ref)
                results.missingPullRequests.insert(ref)
            }
            // Otherwise GitHub said nothing about it: the row stays "Open …".
        }
    }
}

/// Where the launcher's selection goes when its rows change while the query stays: a lookup
/// can add titles or drop rows under the selection.
public enum LauncherSelection {
    /// The new index of the row that was selected, when it is still listed; else the old index,
    /// clamped to the new rows.
    public static func index<Row: Equatable>(keeping selection: Int, from old: [Row], to new: [Row]) -> Int {
        if old.indices.contains(selection), let moved = new.firstIndex(of: old[selection]) { return moved }
        return min(selection, max(new.count - 1, 0))
    }
}
