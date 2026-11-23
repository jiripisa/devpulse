import Foundation
import Synchronization
import Testing
@testable import DevPulseCore

private func snapshot(
    mine: [PullRequest] = [], review: [PullRequest] = [], tickets: [Ticket] = [], linked: [Ticket] = [],
    sessions: [ClaudeSession] = []
) -> Snapshot {
    let ok = SourceStatus(state: .ok)
    return Snapshot(
        appVersion: "1", generatedAt: Date(timeIntervalSince1970: 0), jiraBaseURL: "https://acme.atlassian.net",
        sources: Sources(github: ok, jira: ok, claude: ok),
        myPullRequests: mine, reviewRequests: review, tickets: tickets, linkedTickets: linked, sessions: sessions)
}

private func settings(repos: [String] = ["acme/store"], projects: [String] = ["STORE", "WA"]) -> AppSettings {
    var settings = AppSettings()
    settings.githubRepos = repos
    settings.jiraProjects = projects
    return settings
}

private func pr(_ number: Int, _ title: String, repo: String = "acme/store") -> PullRequest {
    var pr = makePR(repo: repo, number: number)
    pr.title = title
    return pr
}

private func ticket(_ key: String, _ summary: String) -> Ticket {
    var ticket = makeTicket(key: key)
    ticket.summary = summary
    return ticket
}

@Suite struct SearchWordsTests {
    @Test func wordsAreFoldedAndCleaned() {
        #expect(SearchWords.words(in: "  Invoice   ORDER ") == ["invoice", "order"])
        #expect(SearchWords.words(in: "Objednávka účtu") == ["objednavka", "uctu"])
        // Search syntax never gets through: quotes, colons and brackets split words.
        #expect(SearchWords.words(in: "repo:evil \"x\" (a) STORE-12") == ["repo", "evil", "x", "a", "store-12"])
    }

    @Test func everyWordMustAppearSomewhere() {
        let words = SearchWords.words(in: "invoice ord")
        #expect(SearchWords.matches(words, in: ["Replace invoice order on update"]))
        #expect(SearchWords.matches(words, in: ["Replace invoice", "acme/order-api"]))
        #expect(!SearchWords.matches(words, in: ["Replace invoice"]))
        #expect(SearchWords.matches(["objednavka"], in: ["Nová Objednávka"]))
        #expect(!SearchWords.matches([], in: ["anything"]))
    }
}

@Suite struct LauncherTextTests {
    private func items(_ input: String, _ snap: Snapshot, _ lookup: LookupResults = LookupResults(),
                       settings: AppSettings = settings()) -> [LauncherItem] {
        LauncherResolver.items(for: .parse(input), snapshot: snap, settings: settings, lookup: lookup)
    }

    @Test func wordsFindKnownPullRequestsTicketsAndSessions() {
        let session = ClaudeSession(
            pid: 3, name: "invoice-fix", cwd: "/w/invoice-fix", status: .idle, updatedAt: Date(timeIntervalSince1970: 0))
        let snap = snapshot(
            mine: [pr(1, "Replace invoice order"), pr(2, "Dark mode")], review: [pr(3, "Invoice totals")],
            tickets: [ticket("STORE-7", "Invoice numbers repeat"), ticket("STORE-8", "Onboarding")],
            linked: [ticket("WA-9", "Old invoice export")], sessions: [session])
        let result = items("invoice", snap)
        #expect(result.map(\.title) == [
            "#1 Replace invoice order", "#3 Invoice totals", "STORE-7 Invoice numbers repeat",
            "WA-9 Old invoice export", "invoice-fix",
        ])
        #expect(items("invoice order", snap).map(\.title) == ["#1 Replace invoice order"])
        // A key or repository counts as words too.
        #expect(items("store-8", snap).map(\.title) == ["STORE-8 Onboarding"])
    }

    @Test func jiraAndGitHubAreAskedAboutTheWords() {
        let request = LauncherResolver.lookupRequest(for: .parse("invoice order"), snapshot: snapshot(), settings: settings())
        #expect(request.textSearch == TextSearch(words: ["invoice", "order"], projects: ["STORE", "WA"], repos: ["acme/store"]))
        var off = settings()
        off.sourceEnabled[.jira] = false
        off.sourceEnabled[.github] = false
        #expect(LauncherResolver.lookupRequest(for: .parse("invoice"), snapshot: snapshot(), settings: off).isEmpty)
        // No projects and no repositories (and none from my items): nothing to ask.
        #expect(LauncherResolver.lookupRequest(
            for: .parse("invoice"), snapshot: snapshot(), settings: settings(repos: [], projects: [])).isEmpty)
    }

    @Test func foundItemsAreAddedAfterTheKnownOnesEachOnce() throws {
        let snap = snapshot(mine: [pr(1, "Replace invoice order")], tickets: [ticket("STORE-7", "Invoice numbers")])
        let search = TextSearch(words: ["invoice"], projects: ["STORE", "WA"], repos: ["acme/store"])
        var lookup = LookupResults()
        lookup.ticketsForText[search.words] = [ticket("STORE-7", "Invoice numbers"), ticket("WA-4", "Invoice archive")]
        lookup.pullRequestsForText[search.words] = [
            PullRequestSummary(repo: "acme/store", number: 1, title: "Replace invoice order", state: .open,
                               url: "https://github.com/acme/store/pull/1"),
            PullRequestSummary(repo: "acme/store", number: 44, title: "Invoice PDF", state: .merged,
                               url: "https://github.com/acme/store/pull/44"),
        ]
        let result = items("invoice", snap, lookup)
        #expect(result.map(\.title) == ["#1 Replace invoice order", "STORE-7 Invoice numbers", "#44 Invoice PDF", "WA-4 Invoice archive"])
        // A found ticket's detail has its data.
        var found = ticket("WA-4", "Invoice archive")
        found.related = [RelatedTicket(key: "WA-1", summary: "R", status: "Done", statusCategory: .done, relation: "relates to")]
        lookup.ticketsForText[search.words] = [found]
        let row = try #require(items("invoice", snap, lookup).last)
        let detail = LauncherResolver.detail(for: row, snapshot: snap, settings: settings(), lookup: lookup)
        #expect(detail.items.map(\.title).contains("WA-1 R"))
    }
}

@Suite @MainActor struct LauncherTextLookupTests {
    @Test func searchesOnceForTheTTLAndRemembersNothingOnFailure() async {
        let tickets = Mutex(0)
        let prs = Mutex(0)
        let fail = Mutex(false)
        struct Offline: Error {}
        let lookup = LauncherLookup(
            ttl: 300,
            fetchTickets: { _ in TicketLookup(tickets: [], missingKeys: []) },
            fetchPullRequests: { _ in PullRequestLookup() },
            searchPullRequests: { _ in [] },
            searchTicketsByText: { _, _ in
                tickets.withLock { $0 += 1 }
                if fail.withLock({ $0 }) { throw Offline() }
                return [makeTicket(key: "WA-4")]
            },
            searchPullRequestsByText: { _, _ in
                prs.withLock { $0 += 1 }
                return []
            })
        let search = TextSearch(words: ["invoice"], projects: ["WA"], repos: ["acme/store"])
        await lookup.resolve(LookupRequest(textSearch: search))
        await lookup.resolve(LookupRequest(textSearch: search))
        #expect(tickets.withLock { $0 } == 1)
        #expect(prs.withLock { $0 } == 1)
        #expect(lookup.results.ticketsForText[["invoice"]]?.map(\.key) == ["WA-4"])
        fail.withLock { $0 = true }
        let other = TextSearch(words: ["order"], projects: ["WA"], repos: [])
        await lookup.resolve(LookupRequest(textSearch: other))
        #expect(lookup.results.ticketsForText[["order"]] == nil)
        // No repositories: GitHub is not asked.
        #expect(prs.withLock { $0 } == 1)
    }
}
