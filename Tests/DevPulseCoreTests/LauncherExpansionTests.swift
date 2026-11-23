import Foundation
import Testing
@testable import DevPulseCore

private func snapshot(
    mine: [PullRequest] = [], review: [PullRequest] = [], tickets: [Ticket] = [], linked: [Ticket] = []
) -> Snapshot {
    let ok = SourceStatus(state: .ok)
    return Snapshot(
        appVersion: "1", generatedAt: Date(timeIntervalSince1970: 0), jiraBaseURL: "https://acme.atlassian.net",
        sources: Sources(github: ok, jira: ok, claude: ok),
        myPullRequests: mine, reviewRequests: review, tickets: tickets, linkedTickets: linked, sessions: [])
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

@Suite struct LauncherSubjectTests {
    @Test func rowsNameTheTicketOrPullRequestTheyShow() {
        let snap = snapshot(mine: [pr("acme/store", 7)], tickets: [ticket("STORE-7")])
        let items = LauncherResolver.items(for: .parse("7"), snapshot: snap, settings: settings())
        #expect(items.map(\.subject) == [
            .pullRequest(PullRequestRef(repo: "acme/store", number: 7)), .ticket("STORE-7"),
            .pullRequest(PullRequestRef(repo: "acme/api", number: 7)), .ticket("WA-7"),
        ])
    }

    @Test func aNotFoundRowHasNothingToExpand() {
        var lookup = LookupResults()
        lookup.missingTickets = ["STORE-9"]
        let items = LauncherResolver.items(for: .parse("jira STORE-9"), snapshot: snapshot(), settings: settings(), lookup: lookup)
        #expect(items.map(\.subject) == [nil])
    }
}

@Suite struct LauncherChildrenTests {
    private func children(
        _ subject: LauncherItem.Subject, _ snap: Snapshot, _ lookup: LookupResults = LookupResults(),
        settings: AppSettings = settings()
    ) -> [LauncherItem] {
        LauncherResolver.children(of: subject, snapshot: snap, settings: settings, lookup: lookup)
    }

    @Test func aTicketShowsItsPullRequestsThenItsRelatedTickets() {
        let snap = snapshot(
            mine: [pr("acme/store", 5, key: "STORE-7")], review: [pr("acme/api", 6, key: "OTHER-1")],
            tickets: [ticket("STORE-7", related: [relates])])
        var lookup = LookupResults()
        lookup.pullRequestsForTicket["STORE-7"] = [summary("acme/store", 5, "Dup"), summary("acme/api", 9, "Api fix")]
        let result = children(.ticket("STORE-7"), snap, lookup)
        #expect(result.map(\.title) == ["#5 PR 5", "#9 Api fix", "WA-1 Linked"])
        #expect(result.map(\.subtitle) == ["acme/store", "acme/api · Merged", "relates to · Done"])
        #expect(result.map(\.kind) == [.pullRequest, .pullRequest, .ticket])
        #expect(result[2].target == .url(URL(string: "https://acme.atlassian.net/browse/WA-1")!))
        #expect(result.allSatisfy { $0.subject == nil })
    }

    @Test func aTicketAsksGitHubForItsPullRequestsInTheRepositories() {
        let request = LauncherResolver.childLookupRequest(
            for: .ticket("STORE-7"), snapshot: snapshot(), settings: settings(), lookup: LookupResults())
        #expect(request == LookupRequest(
            pullRequestSearches: [PullRequestSearch(key: "STORE-7", repos: ["acme/store", "acme/api"])]))
        // Without repositories (and none of my own PRs to take them from) there is nowhere to search.
        let none = LauncherResolver.childLookupRequest(
            for: .ticket("STORE-7"), snapshot: snapshot(), settings: settings(repos: []), lookup: LookupResults())
        #expect(none.isEmpty)
    }

    @Test func aTicketFoundByTheLookupShowsItsRelatedTickets() {
        var lookup = LookupResults()
        lookup.tickets["WA-3"] = ticket("WA-3", related: [relates])
        #expect(children(.ticket("WA-3"), snapshot(), lookup).map(\.title) == ["WA-1 Linked"])
    }

    @Test func aPullRequestShowsItsTicketThenItsRelatedTickets() {
        let snap = snapshot(mine: [pr("acme/store", 5, key: "STORE-7")], linked: [ticket("STORE-7", "Seven", related: [relates])])
        let result = children(.pullRequest(PullRequestRef(repo: "acme/store", number: 5)), snap)
        #expect(result.map(\.title) == ["STORE-7 Seven", "WA-1 Linked"])
        #expect(result.map(\.subtitle) == ["To Do", "relates to · Done"])
        #expect(LauncherResolver.childLookupRequest(
            for: .pullRequest(PullRequestRef(repo: "acme/store", number: 5)), snapshot: snap, settings: settings(),
            lookup: LookupResults()).isEmpty)
    }

    @Test func aLookedUpPullRequestFindsItsTicketInTheBranchAndLooksItUp() {
        let ref = PullRequestRef(repo: "acme/api", number: 9)
        var lookup = LookupResults()
        lookup.pullRequests[ref] = summary("acme/api", 9, "Fix", branch: "feature/WA-3-login")
        #expect(LauncherResolver.childLookupRequest(for: .pullRequest(ref), snapshot: snapshot(), settings: settings(), lookup: lookup)
            == LookupRequest(ticketKeys: ["WA-3"]))
        #expect(children(.pullRequest(ref), snapshot(), lookup).map(\.title) == ["Open WA-3"])
        lookup.tickets["WA-3"] = ticket("WA-3", "Three", related: [relates])
        #expect(children(.pullRequest(ref), snapshot(), lookup).map(\.title) == ["WA-3 Three", "WA-1 Linked"])
    }

    @Test func aPullRequestWithoutATicketHasNoChildren() {
        let snap = snapshot(mine: [pr("acme/store", 5)])
        #expect(children(.pullRequest(PullRequestRef(repo: "acme/store", number: 5)), snap).isEmpty)
    }

    @Test func childrenAreCapped() {
        let many = (1...30).map {
            RelatedTicket(key: "WA-\($0)", summary: "R", status: "To Do", statusCategory: .todo, relation: "blocks")
        }
        var lookup = LookupResults()
        lookup.pullRequestsForTicket["STORE-7"] = (1...30).map { summary("acme/store", $0, "P") }
        let result = children(.ticket("STORE-7"), snapshot(tickets: [ticket("STORE-7", related: many)]), lookup)
        #expect(result.filter { $0.kind == .pullRequest }.count == LauncherResolver.maxChildren)
        #expect(result.filter { $0.kind == .ticket }.count == LauncherResolver.maxChildren)
    }
}

@Suite struct LauncherRowsTests {
    private let a = LauncherItem(title: "A", subtitle: "", kind: .ticket, target: .url(URL(string: "https://a.test")!), subject: .ticket("A-1"))
    private let b = LauncherItem(title: "B", subtitle: "", kind: .ticket, target: .url(URL(string: "https://b.test")!), subject: .ticket("B-1"))
    private let c1 = LauncherItem(title: "C1", subtitle: "", kind: .pullRequest, target: .url(URL(string: "https://c1.test")!))
    private let c2 = LauncherItem(title: "C2", subtitle: "", kind: .ticket, target: .url(URL(string: "https://a.test")!))

    @Test func childrenGoRightUnderTheExpandedRow() {
        let rows = LauncherRows.build([a, b], expanded: .ticket("A-1"), children: [c1, c2])
        #expect(rows.map(\.item.title) == ["A", "C1", "C2", "B"])
        #expect(rows.map(\.depth) == [0, 1, 1, 0])
        // A child may open the same thing as a top row; the ids still differ.
        #expect(Set(rows.map(\.id)).count == 4)
        #expect(LauncherRows.topSubject(at: 2, in: rows) == .ticket("A-1"))
        #expect(LauncherRows.topSubject(at: 3, in: rows) == .ticket("B-1"))
        #expect(LauncherRows.topSubject(at: 9, in: rows) == nil)
    }

    @Test func nothingExpandsWithoutAMatchingRow() {
        #expect(LauncherRows.build([a, b], expanded: nil, children: [c1]).map(\.depth) == [0, 0])
        #expect(LauncherRows.build([a, b], expanded: .ticket("Z-1"), children: [c1]).map(\.depth) == [0, 0])
    }

    @Test func idsStayUniqueForTheSameThingTwice() {
        let rows = LauncherRows.build([a, b], expanded: .ticket("A-1"), children: [c2, c2])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
}
