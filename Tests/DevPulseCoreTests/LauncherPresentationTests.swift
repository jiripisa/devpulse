import Foundation
import Testing
@testable import DevPulseCore

private func snapshot(
    mine: [PullRequest] = [], review: [PullRequest] = [], tickets: [Ticket] = [], sessions: [ClaudeSession] = []
) -> Snapshot {
    let ok = SourceStatus(state: .ok)
    return Snapshot(
        appVersion: "1", generatedAt: Date(timeIntervalSince1970: 0), jiraBaseURL: "https://acme.atlassian.net",
        sources: Sources(github: ok, jira: ok, claude: ok),
        myPullRequests: mine, reviewRequests: review, tickets: tickets, sessions: sessions)
}

private func settings() -> AppSettings {
    var settings = AppSettings()
    settings.githubRepos = ["acme/store"]
    settings.jiraProjects = ["STORE"]
    return settings
}

@Suite struct LauncherPresentationTests {
    @Test func aPullRequestRowNamesItsRepoNumberAndTicketAndShowsCIAndReview() throws {
        var pr = makePR(repo: "acme/store", number: 812)
        pr.title = "Replace invoice order"
        pr.jiraKey = "STORE-2474"
        pr.checks = .success
        pr.reviewDecision = .reviewRequired
        let row = try #require(LauncherResolver.items(for: .parse("gh"), snapshot: snapshot(mine: [pr]), settings: settings()).first)
        #expect(row.identifier == "acme/store #812 · STORE-2474")
        // The list keeps the number and the key: the repository goes without its owner.
        #expect(row.compactIdentifier == "store #812 · STORE-2474")
        #expect(row.name == "Replace invoice order")
        #expect(row.badges.map(\.text) == ["CI passing", "Review required"])
        #expect(row.openLabel == "Open on GitHub")
    }

    @Test func aTicketRowNamesItsKeyAndStatus() throws {
        var ticket = makeTicket(key: "STORE-7")
        ticket.summary = "Fix totals"
        ticket.status = "In Review"
        ticket.statusCategory = .inProgress
        let row = try #require(LauncherResolver.items(for: .parse("jira"), snapshot: snapshot(tickets: [ticket]), settings: settings()).first)
        #expect(row.identifier == "STORE-7")
        #expect(row.name == "Fix totals")
        #expect(row.badges == [StatusBadge(text: "In Review", glyph: .diamond, tone: .review)])
        #expect(row.openLabel == "Open in Jira")
    }

    @Test func aSessionRowSaysWhatItWaitsFor() throws {
        var waiting = ClaudeSession(
            pid: 5, name: "webapp", cwd: "/w/webapp-7", status: .waiting, jiraKey: "STORE-7", updatedAt: Date(timeIntervalSince1970: 0))
        waiting.waitingFor = "permission prompt"
        let row = try #require(LauncherResolver.items(for: .parse("7"), snapshot: snapshot(sessions: [waiting]), settings: settings()).first)
        #expect(row.name == "webapp")
        #expect(row.identifier == "STORE-7 · Permission prompt")
        #expect(row.compactIdentifier == "STORE-7 · Permission prompt")
        #expect(row.badges.map(\.text) == ["Waiting for input"])
        #expect(row.openLabel == "Open in Ghostty")
    }

    @Test func aSessionWithoutKeyOrWaitShowsItsFolderWithTheTilde() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let idle = ClaudeSession(
            pid: 6, name: "tool-7", cwd: home + "/dev/tool-7", status: .idle, updatedAt: Date(timeIntervalSince1970: 0))
        #expect(idle.rowIdentifiers == ["~/dev/tool-7"])
        let row = try #require(LauncherResolver.items(for: .parse("7"), snapshot: snapshot(sessions: [idle]), settings: settings()).first)
        #expect(row.compactIdentifier == "~/dev/tool-7")
    }

    @Test func pullRequestRowsInTheListNameTheShortRepository() {
        var pr = makePR(repo: "acme/webapp", number: 812)
        pr.jiraKey = "STORE-1"
        #expect(pr.rowIdentifiers == ["webapp #812", "STORE-1"])
        pr.jiraKey = nil
        #expect(pr.rowIdentifiers == ["webapp #812"])
    }

    @Test func lookedUpAndLinkPullRequestRowsHaveIdentifiersAndState() throws {
        let ref = PullRequestRef(repo: "acme/store", number: 9)
        var lookup = LookupResults()
        lookup.pullRequests[ref] = PullRequestSummary(
            repo: "acme/store", number: 9, title: "Faster", state: .merged, url: "https://github.com/acme/store/pull/9")
        let found = try #require(LauncherResolver.items(for: .parse("gh 9"), snapshot: snapshot(), settings: settings(), lookup: lookup).first)
        #expect(found.identifier == "acme/store #9")
        #expect(found.compactIdentifier == "store #9")
        #expect(found.name == "Faster")
        #expect(found.badges.map(\.text) == ["Merged"])
        let link = try #require(LauncherResolver.items(for: .parse("gh 9"), snapshot: snapshot(), settings: settings()).first)
        #expect(link.identifier == "acme/store #9")
        #expect(link.name == "Open on GitHub")
        let detail = LauncherResolver.detail(for: found, snapshot: snapshot(), settings: settings(), lookup: lookup)
        #expect(detail.heading == "Pull request")
    }

    @Test func linkAndNotFoundRowsSayWhatTheyAre() throws {
        let open = try #require(LauncherResolver.items(for: .parse("jira STORE-9"), snapshot: snapshot(), settings: settings()).first)
        #expect(open.identifier == "STORE-9")
        #expect(open.name == "Open in Jira")
        #expect(open.badges.isEmpty)
        var lookup = LookupResults()
        lookup.missingTickets = ["STORE-9"]
        let missing = try #require(
            LauncherResolver.items(for: .parse("jira STORE-9"), snapshot: snapshot(), settings: settings(), lookup: lookup).first)
        #expect(missing.badges == [StatusBadge(text: "Not found in Jira", glyph: .exclamation, tone: .secondary)])
    }

    @Test func theDetailHeaderAndSectionsNameTheTicket() throws {
        var ticket = makeTicket(key: "STORE-7")
        ticket.related = [RelatedTicket(key: "WA-1", summary: "Linked", status: "Done", statusCategory: .done, relation: "is blocked by")]
        let snap = snapshot(tickets: [ticket])
        let row = try #require(LauncherResolver.items(for: .parse("jira STORE-7"), snapshot: snap, settings: settings()).first)
        let detail = LauncherResolver.detail(for: row, snapshot: snap, settings: settings(), lookup: LookupResults())
        #expect(detail.heading == "Jira ticket")
        #expect(detail.item == row)
        #expect(detail.sections.map(\.title) == ["Pull requests for STORE-7", "Related to STORE-7"])
        let related = try #require(detail.sections.last?.items.first)
        #expect(related.caption == "Is blocked by")
        var relates = makeTicket(key: "STORE-8")
        relates.related = [RelatedTicket(key: "WA-2", summary: "Other", status: "To Do", statusCategory: .todo, relation: "relates to")]
        let other = LauncherResolver.detail(
            for: LauncherItem(title: "x", subtitle: "", kind: .ticket, target: .url(URL(string: "https://x.test")!), subject: .ticket("STORE-8")),
            snapshot: snapshot(tickets: [relates]), settings: settings(), lookup: LookupResults())
        #expect(other.sections.last?.items.first?.caption == "Relates to")
        #expect(related.identifier == "WA-1")
        #expect(related.name == "Linked")
        #expect(related.badges.map(\.text) == ["Done"])
    }

    @Test func theDetailOfAPullRequestOrSessionShowsItsLinkedTicket() throws {
        var pr = makePR(repo: "acme/store", number: 5)
        pr.jiraKey = "STORE-7"
        let snap = snapshot(review: [pr], tickets: [makeTicket(key: "STORE-7")])
        let row = try #require(LauncherResolver.items(for: .parse("gh"), snapshot: snap, settings: settings()).first)
        let detail = LauncherResolver.detail(for: row, snapshot: snap, settings: settings(), lookup: LookupResults())
        #expect(detail.heading == "Review request")
        #expect(detail.sections.map(\.title) == ["Linked ticket"])
        let session = LauncherItem(
            title: "s", subtitle: "", kind: .session(.idle), target: .session(pid: 1), identifier: "STORE-7")
        let withSession = snapshot(sessions: [ClaudeSession(
            pid: 1, name: "s", cwd: "/work/store-7", status: .idle, jiraKey: "STORE-7", updatedAt: Date(timeIntervalSince1970: 0))])
        let sessionDetail = LauncherResolver.detail(for: session, snapshot: withSession, settings: settings(), lookup: LookupResults())
        #expect(sessionDetail.heading == "Claude Code session")
        // A session's header line is its folder; a ticket's or PR's is its identifier.
        #expect(sessionDetail.subheading == "/work/store-7")
        #expect(detail.subheading == "acme/store #5 · STORE-7")
    }
}
