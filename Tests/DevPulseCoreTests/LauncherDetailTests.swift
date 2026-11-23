import Foundation
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

private func ticket(_ key: String, _ summary: String = "S", related: [RelatedTicket] = []) -> Ticket {
    var ticket = makeTicket(key: key)
    ticket.summary = summary
    ticket.related = related
    return ticket
}

private func pr(_ repo: String, _ number: Int, key: String? = nil) -> PullRequest {
    var pr = makePR(repo: repo, number: number)
    pr.jiraKey = key
    return pr
}

private func summary(_ repo: String, _ number: Int, _ title: String, branch: String? = nil) -> PullRequestSummary {
    PullRequestSummary(
        repo: repo, number: number, title: title, state: .merged,
        url: "https://github.com/\(repo)/pull/\(number)", headBranch: branch)
}

private let relates = RelatedTicket(key: "WA-1", summary: "Linked", status: "Done", statusCategory: .done, relation: "relates to")

private func settings(repos: [String] = ["acme/store", "acme/api"], projects: [String] = ["STORE", "WA"]) -> AppSettings {
    var settings = AppSettings()
    settings.githubRepos = repos
    settings.jiraProjects = projects
    return settings
}

private func row(_ subject: LauncherItem.Subject?, target: OpenTarget = .url(URL(string: "https://x.test")!)) -> LauncherItem {
    LauncherItem(title: "Row", subtitle: "Sub", kind: .ticket, target: target, subject: subject)
}

@Suite struct LauncherSubjectTests {
    @Test func rowsNameTheTicketOrPullRequestTheyShow() {
        let snap = snapshot(mine: [pr("acme/store", 7)], tickets: [ticket("STORE-7")])
        var lookup = LookupResults()
        lookup.tickets["WA-7"] = ticket("WA-7")
        let items = LauncherResolver.items(for: .parse("7"), snapshot: snap, settings: settings(), lookup: lookup)
        #expect(items.map(\.subject) == [
            .pullRequest(PullRequestRef(repo: "acme/store", number: 7)), .ticket("STORE-7"), .ticket("WA-7"),
        ])
    }

    @Test func aNotFoundRowKeepsItsSubjectButHasNoDetail() {
        var lookup = LookupResults()
        lookup.missingTickets = ["STORE-9"]
        let items = LauncherResolver.items(for: .parse("jira STORE-9"), snapshot: snapshot(), settings: settings(), lookup: lookup)
        #expect(items.map(\.subject) == [.ticket("STORE-9")])
        #expect(items.map(\.subtitle) == ["Not found in Jira"])
        let detail = LauncherResolver.detail(for: items[0], snapshot: snapshot(), settings: settings(), lookup: lookup)
        #expect(detail.sections.isEmpty)
        #expect(LauncherResolver.detailLookupRequest(for: items[0], snapshot: snapshot(), settings: settings(), lookup: lookup).isEmpty)
    }

    @Test func aMovedTicketKeepsTheKeyAskedFor() {
        var lookup = LookupResults()
        lookup.tickets["OLD-3"] = ticket("NEW-9", "Moved")
        let rows = LauncherResolver.items(for: .parse("jira OLD-3"), snapshot: snapshot(), settings: settings(), lookup: lookup)
        #expect(rows.map(\.title) == ["NEW-9 Moved"])
        #expect(rows.map(\.subject) == [.ticket("OLD-3")])
    }
}

@Suite struct LauncherDetailTests {
    private func detail(
        _ item: LauncherItem, _ snap: Snapshot, _ lookup: LookupResults = LookupResults(), settings: AppSettings = settings()
    ) -> LauncherDetail {
        LauncherResolver.detail(for: item, snapshot: snap, settings: settings, lookup: lookup)
    }

    private func request(
        _ item: LauncherItem, _ snap: Snapshot, _ lookup: LookupResults = LookupResults(), settings: AppSettings = settings()
    ) -> LookupRequest {
        LauncherResolver.detailLookupRequest(for: item, snapshot: snap, settings: settings, lookup: lookup)
    }

    @Test func aTicketShowsItsPullRequestsAndRelatedTickets() {
        let snap = snapshot(
            mine: [pr("acme/store", 5, key: "STORE-7")], review: [pr("acme/api", 6, key: "OTHER-1")],
            tickets: [ticket("STORE-7", related: [relates])])
        var lookup = LookupResults()
        lookup.pullRequestsForTicket["STORE-7"] = [summary("acme/store", 5, "Dup"), summary("acme/api", 9, "Api fix")]
        let result = detail(row(.ticket("STORE-7")), snap, lookup)
        #expect(result.title == "Row")
        #expect(result.subtitle == "Sub")
        #expect(result.sections.map(\.title) == ["Pull requests", "Related tickets"])
        #expect(result.sections.map(\.isLoading) == [false, false])
        #expect(result.items.map(\.title) == ["#5 PR 5", "#9 Api fix", "WA-1 Linked"])
        #expect(result.items.map(\.subtitle) == ["acme/store", "acme/api · Merged", "relates to · Done"])
        #expect(result.items[2].target == .url(URL(string: "https://acme.atlassian.net/browse/WA-1")!))
    }

    @Test func aTicketsPullRequestsLoadUntilGitHubAnswers() {
        let snap = snapshot(tickets: [ticket("STORE-7")])
        let pending = detail(row(.ticket("STORE-7")), snap)
        #expect(pending.sections.map(\.title) == ["Pull requests"])
        #expect(pending.sections[0].isLoading)
        #expect(request(row(.ticket("STORE-7")), snap)
            == LookupRequest(pullRequestSearches: [PullRequestSearch(key: "STORE-7", repos: ["acme/store", "acme/api"])]))
        var lookup = LookupResults()
        lookup.pullRequestsForTicket["STORE-7"] = []
        let answered = detail(row(.ticket("STORE-7")), snap, lookup)
        #expect(!answered.sections[0].isLoading)
        #expect(answered.sections[0].emptyText == "No pull requests")
        // Without repositories there is nothing to search: nothing loads.
        let none = detail(row(.ticket("STORE-7")), snap, settings: settings(repos: []))
        #expect(!none.sections[0].isLoading)
        #expect(request(row(.ticket("STORE-7")), snap, settings: settings(repos: [])).isEmpty)
    }

    @Test func aDetailStopsLoadingWhenJiraOrGitHubCannotBeReached() {
        var lookup = LookupResults()
        lookup.unreachableSearches = ["STORE-7"]
        let ticketDetail = detail(row(.ticket("STORE-7")), snapshot(tickets: [ticket("STORE-7")]), lookup)
        #expect(!ticketDetail.sections[0].isLoading)
        #expect(ticketDetail.sections[0].emptyText == "GitHub could not be searched")
        let ref = PullRequestRef(repo: "acme/api", number: 9)
        lookup.pullRequests[ref] = summary("acme/api", 9, "Fix", branch: "WA-3-x")
        lookup.unreachableTickets = ["WA-3"]
        let prDetail = detail(row(.pullRequest(ref)), snapshot(), lookup)
        #expect(prDetail.items.map(\.title) == ["Open WA-3"])
        #expect(!prDetail.sections[0].isLoading)
    }

    @Test func aSwitchedOffSourceShowsNothingAndAsksNothing() {
        var off = settings()
        off.sourceEnabled[.github] = false
        let snap = snapshot(tickets: [ticket("STORE-7", related: [relates])])
        let ticketDetail = detail(row(.ticket("STORE-7")), snap, settings: off)
        #expect(ticketDetail.sections.map(\.title) == ["Related tickets"])
        #expect(request(row(.ticket("STORE-7")), snap, settings: off).isEmpty)
        var jiraOff = settings()
        jiraOff.sourceEnabled[.jira] = false
        let ref = PullRequestRef(repo: "acme/api", number: 9)
        var lookup = LookupResults()
        lookup.pullRequests[ref] = summary("acme/api", 9, "Fix", branch: "WA-3-x")
        let prDetail = detail(row(.pullRequest(ref)), snapshot(), lookup, settings: jiraOff)
        #expect(prDetail.items.map(\.title) == ["Open WA-3"])
        #expect(!prDetail.sections[0].isLoading)
        #expect(request(row(.pullRequest(ref)), snapshot(), lookup, settings: jiraOff).isEmpty)
    }

    @Test func aMovedTicketListsThePullRequestsOfBothKeys() {
        var lookup = LookupResults()
        lookup.tickets["OLD-3"] = ticket("NEW-9", "Moved", related: [relates])
        lookup.pullRequestsForTicket["OLD-3"] = [summary("acme/store", 1, "Old")]
        lookup.pullRequestsForTicket["NEW-9"] = [summary("acme/store", 2, "New"), summary("acme/store", 1, "Old")]
        let snap = snapshot(mine: [pr("acme/api", 5, key: "OLD-3")])
        #expect(detail(row(.ticket("OLD-3")), snap, lookup).items.map(\.title) == ["#5 PR 5", "#1 Old", "#2 New", "WA-1 Linked"])
        #expect(request(row(.ticket("OLD-3")), snap, lookup).pullRequestSearches.map(\.key) == ["OLD-3", "NEW-9"])
    }

    @Test func aPullRequestShowsItsTicketAndThatTicketsRelatedTickets() {
        let snap = snapshot(mine: [pr("acme/store", 5, key: "STORE-7")], linked: [ticket("STORE-7", "Seven", related: [relates])])
        let item = row(.pullRequest(PullRequestRef(repo: "acme/store", number: 5)))
        let result = detail(item, snap)
        #expect(result.sections.map(\.title) == ["Ticket", "Related tickets"])
        #expect(result.items.map(\.title) == ["STORE-7 Seven", "WA-1 Linked"])
        #expect(request(item, snap).isEmpty)
    }

    @Test func aLookedUpPullRequestFindsItsTicketInTheBranchAndLoadsIt() {
        let ref = PullRequestRef(repo: "acme/api", number: 9)
        var lookup = LookupResults()
        lookup.pullRequests[ref] = summary("acme/api", 9, "Fix", branch: "feature/WA-3-login")
        let item = row(.pullRequest(ref))
        #expect(request(item, snapshot(), lookup) == LookupRequest(ticketKeys: ["WA-3"]))
        let pending = detail(item, snapshot(), lookup)
        #expect(pending.items.map(\.title) == ["Open WA-3"])
        #expect(pending.sections[0].isLoading)
        lookup.tickets["WA-3"] = ticket("WA-3", "Three", related: [relates])
        #expect(detail(item, snapshot(), lookup).items.map(\.title) == ["WA-3 Three", "WA-1 Linked"])
    }

    @Test func aPullRequestTakesItsTicketKeyFromTheTitle() {
        let ref = PullRequestRef(repo: "acme/api", number: 9)
        var lookup = LookupResults()
        lookup.pullRequests[ref] = summary("acme/api", 9, "WA-4 Faster login", branch: "fix-login")
        lookup.tickets["WA-4"] = ticket("WA-4", "Four")
        #expect(detail(row(.pullRequest(ref)), snapshot(), lookup).items.map(\.title) == ["WA-4 Four"])
    }

    @Test func aPullRequestWhoseTicketDoesNotExistSaysSo() {
        let ref = PullRequestRef(repo: "acme/api", number: 9)
        var lookup = LookupResults()
        lookup.pullRequests[ref] = summary("acme/api", 9, "Fix", branch: "WA-4-login")
        lookup.missingTickets = ["WA-4"]
        let result = detail(row(.pullRequest(ref)), snapshot(), lookup)
        #expect(result.items.isEmpty)
        #expect(result.sections.map(\.emptyText) == ["WA-4 is not in Jira"])
        #expect(request(row(.pullRequest(ref)), snapshot(), lookup).isEmpty)
    }

    @Test func aPullRequestWithoutATicketSaysSo() {
        let snap = snapshot(mine: [pr("acme/store", 5)])
        let result = detail(row(.pullRequest(PullRequestRef(repo: "acme/store", number: 5))), snap)
        #expect(result.items.isEmpty)
        #expect(result.sections.map(\.emptyText) == ["No Jira key in its title or branch"])
    }

    @Test func aSessionShowsItsTicket() {
        let session = ClaudeSession(
            pid: 42, name: "s", cwd: "/w/store-7", status: .idle, jiraKey: "STORE-7", updatedAt: Date(timeIntervalSince1970: 0))
        let snap = snapshot(tickets: [ticket("STORE-7", "Seven", related: [relates])], sessions: [session])
        let item = row(nil, target: .session(pid: 42))
        #expect(detail(item, snap).items.map(\.title) == ["STORE-7 Seven", "WA-1 Linked"])
        let unknown = snapshot(sessions: [session])
        #expect(request(item, unknown) == LookupRequest(ticketKeys: ["STORE-7"]))
    }

    @Test func aPullRequestsTicketWithoutAJiraSiteSaysSo() {
        var snap = snapshot(mine: [pr("acme/store", 5, key: "STORE-7")])
        snap.jiraBaseURL = nil
        let result = detail(row(.pullRequest(PullRequestRef(repo: "acme/store", number: 5))), snap)
        #expect(result.items.isEmpty)
        #expect(result.sections.map(\.emptyText) == ["STORE-7 · set up Jira in Settings to see it"])
    }

    @Test func detailsAreCapped() {
        let many = (1...30).map {
            RelatedTicket(key: "WA-\($0)", summary: "R", status: "To Do", statusCategory: .todo, relation: "blocks")
        }
        var lookup = LookupResults()
        lookup.pullRequestsForTicket["STORE-7"] = (1...30).map { summary("acme/store", $0, "P") }
        let result = detail(row(.ticket("STORE-7")), snapshot(tickets: [ticket("STORE-7", related: many)]), lookup)
        #expect(result.sections.map(\.items.count) == [LauncherResolver.maxDetailRows, LauncherResolver.maxDetailRows])
    }
}
