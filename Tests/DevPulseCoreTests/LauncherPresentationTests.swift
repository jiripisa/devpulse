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
        #expect(row.identifier == "STORE-7 · permission prompt")
        #expect(row.badges.map(\.text) == ["Waiting for input"])
        #expect(row.openLabel == "Open in Ghostty")
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
        let session = LauncherItem(title: "s", subtitle: "", kind: .session(.idle), target: .session(pid: 1))
        #expect(LauncherResolver.detail(for: session, snapshot: snap, settings: settings(), lookup: LookupResults()).heading
            == "Claude Code session")
    }
}
