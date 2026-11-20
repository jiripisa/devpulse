import Foundation
import Testing
@testable import DevPulseCore

private func snapshot(
    mine: [PullRequest] = [], review: [PullRequest] = [], tickets: [Ticket] = [],
    sessions: [ClaudeSession] = [], jiraBaseURL: String? = "https://acme.atlassian.net"
) -> Snapshot {
    let ok = SourceStatus(state: .ok)
    return Snapshot(
        appVersion: "1", generatedAt: Date(timeIntervalSince1970: 0), jiraBaseURL: jiraBaseURL,
        sources: Sources(github: ok, jira: ok, claude: ok),
        myPullRequests: mine, reviewRequests: review, tickets: tickets, sessions: sessions)
}

private func session(
    pid: Int, cwd: String, jiraKey: String? = nil, status: SessionStatus = .idle
) -> ClaudeSession {
    ClaudeSession(
        pid: pid, name: "s\(pid)", cwd: cwd, status: status, jiraKey: jiraKey,
        updatedAt: Date(timeIntervalSince1970: 0))
}

private func url(_ string: String) -> OpenTarget { .url(URL(string: string)!) }

@Suite struct LauncherQueryTests {
    @Test func parsesGitHubForms() {
        #expect(LauncherQuery.parse("gh") == .github(repo: nil, number: nil, text: ""))
        #expect(LauncherQuery.parse("gh invoice") == .github(repo: nil, number: nil, text: "invoice"))
        #expect(LauncherQuery.parse("gh fix login") == .github(repo: nil, number: nil, text: "fix login"))
        #expect(LauncherQuery.parse("gh 812") == .github(repo: nil, number: 812, text: ""))
        #expect(LauncherQuery.parse("gh webapp 455") == .github(repo: "webapp", number: 455, text: ""))
        #expect(LauncherQuery.parse("gh acmecorp/webapp 455") == .github(repo: "acmecorp/webapp", number: 455, text: ""))
    }

    @Test func parsesJiraForms() {
        #expect(LauncherQuery.parse("jira") == .jira(key: nil, number: nil, text: ""))
        #expect(LauncherQuery.parse("jira login bug") == .jira(key: nil, number: nil, text: "login bug"))
        #expect(LauncherQuery.parse("jira STORE-2290") == .jira(key: "STORE-2290", number: nil, text: ""))
        #expect(LauncherQuery.parse("jira 2290") == .jira(key: nil, number: 2290, text: ""))
        #expect(LauncherQuery.parse("JIRA store-2290") == .jira(key: "STORE-2290", number: nil, text: ""))
    }

    @Test func parsesABareNumber() {
        #expect(LauncherQuery.parse("2474") == .number(2474))
        #expect(LauncherQuery.parse("  2474 ") == .number(2474))
        #expect(LauncherQuery.parse("2474 12") == .empty)
        #expect(LauncherQuery.parse("2474a") == .empty)
        #expect(LauncherQuery.parse("-2474") == .empty)
    }

    @Test func otherInputIsEmpty() {
        #expect(LauncherQuery.parse("xyz") == .empty)
        #expect(LauncherQuery.parse("") == .empty)
        #expect(LauncherQuery.parse("ghost") == .empty)
    }

    @Test func toleratesSurroundingAndRepeatedWhitespace() {
        #expect(LauncherQuery.parse("  gh   webapp   455 ") == .github(repo: "webapp", number: 455, text: ""))
    }
}

@Suite struct LauncherResolverTests {
    private func items(_ input: String, _ snapshot: Snapshot, _ settings: AppSettings = AppSettings()) -> [LauncherItem] {
        LauncherResolver.items(for: .parse(input), snapshot: snapshot, settings: settings)
    }

    @Test func emptyQueryHasNoItems() {
        #expect(items("xyz", snapshot(mine: [makePR()])).isEmpty)
    }

    @Test func ghListsMyPullRequestsThenReviewRequests() {
        let result = items("gh", snapshot(mine: [makePR(number: 1)], review: [makePR(number: 2)]))
        #expect(result.map(\.target) == [url("https://github.com/acme/app/pull/1"), url("https://github.com/acme/app/pull/2")])
    }

    @Test func ghDeduplicatesAPullRequestInBothLists() {
        let pr = makePR(number: 1)
        #expect(items("gh", snapshot(mine: [pr], review: [pr])).count == 1)
    }

    @Test func ghTextFiltersTitleAndRepoCaseInsensitively() {
        var invoice = makePR(repo: "acme/webapp", number: 1)
        invoice.title = "Fix Invoice order"
        let other = makePR(repo: "acme/api", number: 2)
        let snap = snapshot(mine: [invoice, other])
        #expect(items("gh INVOICE", snap).map(\.title) == ["#1 Fix Invoice order"])
        #expect(items("gh webAPP", snap).map(\.title) == ["#1 Fix Invoice order"])
    }

    @Test func resultsAreCappedAtTwenty() {
        let prs = (1...30).map { makePR(number: $0) }
        #expect(items("gh", snapshot(mine: prs)).count == 20)
    }

    @Test func ghNumberFindsTheKnownPullRequest() {
        let result = items("gh 812", snapshot(mine: [makePR(number: 812), makePR(number: 5)]))
        #expect(result.map(\.target) == [url("https://github.com/acme/app/pull/812")])
    }

    @Test func ghNumberWithoutMatchOpensTheDefaultRepo() {
        var settings = AppSettings()
        settings.defaultRepo = "acmecorp/store"
        let result = items("gh 999", snapshot(), settings)
        #expect(result.map(\.target) == [url("https://github.com/acmecorp/store/pull/999")])
    }

    @Test func ghNumberWithoutMatchAndWithoutDefaultRepoHasNoItems() {
        #expect(items("gh 999", snapshot()).isEmpty)
    }

    @Test func ghNumberPrefillsTheDefaultRepoFromTheMostFrequentOne() {
        let snap = snapshot(mine: [makePR(repo: "a/x", number: 1), makePR(repo: "b/y", number: 2), makePR(repo: "b/y", number: 3)])
        #expect(items("gh 999", snap).map(\.target) == [url("https://github.com/b/y/pull/999")])
        // An explicit default wins and is not written back.
        var settings = AppSettings()
        settings.defaultRepo = "a/x"
        #expect(items("gh 999", snap, settings).map(\.target) == [url("https://github.com/a/x/pull/999")])
        #expect(settings.defaultRepo == "a/x")
    }

    @Test func ghRepoAndNumberTakesTheOwnerFromAKnownPullRequest() {
        let snap = snapshot(mine: [makePR(repo: "acmecorp/webapp", number: 1)])
        #expect(items("gh webapp 455", snap).map(\.target) == [url("https://github.com/acmecorp/webapp/pull/455")])
        #expect(items("gh WebApp 455", snap).map(\.target) == [url("https://github.com/acmecorp/webapp/pull/455")])
    }

    @Test func ghFullRepoAndNumberNeedsNoKnownPullRequest() {
        #expect(items("gh acmecorp/webapp 455", snapshot()).map(\.target)
            == [url("https://github.com/acmecorp/webapp/pull/455")])
    }

    @Test func ghUnknownRepoNameHasNoItems() {
        #expect(items("gh nowhere 455", snapshot(mine: [makePR(repo: "acmecorp/webapp", number: 1)])).isEmpty)
    }

    @Test func ghRepoAndNumberPrefersTheKnownPullRequest() {
        let snap = snapshot(mine: [makePR(repo: "acmecorp/webapp", number: 455)])
        #expect(items("gh webapp 455", snap).map(\.title) == ["#455 PR 455"])
    }

    @Test func aPullRequestItemHasTheLinkedJiraTicketAsSecondary() {
        var pr = makePR(number: 1)
        pr.jiraKey = "STORE-7"
        let snap = snapshot(mine: [pr, makePR(number: 2)])
        let result = items("gh", snap)
        #expect(result[0].secondary == url("https://acme.atlassian.net/browse/STORE-7"))
        #expect(result[1].secondary == nil)
        #expect(items("gh", snapshot(mine: [pr], jiraBaseURL: nil))[0].secondary == nil)
    }

    @Test func jiraListsTicketsAndFiltersBySummaryOrKey() {
        var a = makeTicket(key: "STORE-1")
        a.summary = "Invoice Orders"
        let b = makeTicket(key: "WA-2")
        let snap = snapshot(tickets: [a, b])
        #expect(items("jira", snap).count == 2)
        #expect(items("jira invoice", snap).map(\.title) == ["STORE-1 Invoice Orders"])
        #expect(items("jira wa-", snap).map(\.title) == ["WA-2 S"])
    }

    @Test func jiraKeyOpensTheKnownTicketOrTheSiteURL() {
        let snap = snapshot(tickets: [makeTicket(key: "STORE-1")])
        #expect(items("jira store-1", snap).map(\.title) == ["STORE-1 S"])
        #expect(items("jira STORE-2290", snap).map(\.target) == [url("https://acme.atlassian.net/browse/STORE-2290")])
    }

    @Test func jiraNumberExpandsToTheDefaultProject() {
        var settings = AppSettings()
        settings.defaultJiraProject = "STORE"
        #expect(items("jira 2290", snapshot(), settings).map(\.target) == [url("https://acme.atlassian.net/browse/STORE-2290")])
    }

    @Test func jiraNumberPrefillsTheDefaultProjectFromTheMostFrequentOne() {
        let snap = snapshot(tickets: ["WA-1", "STORE-2", "STORE-3"].map { makeTicket(key: $0) })
        #expect(items("jira 2290", snap).map(\.target) == [url("https://acme.atlassian.net/browse/STORE-2290")])
        #expect(items("jira 2290", snapshot()).isEmpty)
    }

    @Test func jiraSiteFromSettingsIsUsedAndMissingSiteOmitsTheItem() {
        var settings = AppSettings()
        settings.jiraSite = URL(string: "https://corp.atlassian.net")
        #expect(items("jira ABC-1", snapshot(jiraBaseURL: nil), settings).map(\.target)
            == [url("https://corp.atlassian.net/browse/ABC-1")])
        #expect(items("jira ABC-1", snapshot(jiraBaseURL: nil)).isEmpty)
        var withProject = AppSettings()
        withProject.defaultJiraProject = "ABC"
        #expect(items("jira 1", snapshot(jiraBaseURL: nil), withProject).isEmpty)
    }
}

@Suite struct LauncherNumberTests {
    private func items(_ input: String, _ snapshot: Snapshot, _ settings: AppSettings = AppSettings()) -> [LauncherItem] {
        LauncherResolver.items(for: .parse(input), snapshot: snapshot, settings: settings)
    }

    @Test func anEmptySnapshotWithoutDefaultsHasNoItems() {
        #expect(items("2474", snapshot()).isEmpty)
    }

    @Test func findsMyPullRequestsAndReviewRequestsWithTheNumberInAnyRepo() {
        var review = makePR(repo: "acme/api", number: 2474)
        review.requestedDirectly = true
        let snap = snapshot(
            mine: [makePR(repo: "acme/web", number: 2474), makePR(repo: "acme/web", number: 5)],
            review: [review, makePR(repo: "acme/api", number: 24)])
        let result = items("2474", snap)
        #expect(result.map(\.title) == ["#2474 PR 2474", "#2474 PR 2474"])
        #expect(result.map(\.subtitle) == ["acme/web", "acme/api"])
        #expect(result.map(\.kind) == [.pullRequest, .reviewRequest(direct: true)])
    }

    @Test func aPullRequestInBothListsShowsOnceAsMine() {
        let pr = makePR(number: 7)
        #expect(items("7", snapshot(mine: [pr], review: [pr])).map(\.kind) == [.pullRequest])
    }

    @Test func aPullRequestRowKeepsItsJiraTicketForCommandEnter() {
        var pr = makePR(number: 7)
        pr.jiraKey = "STORE-1"
        #expect(items("7", snapshot(mine: [pr]))[0].secondary == url("https://acme.atlassian.net/browse/STORE-1"))
    }

    @Test func findsTicketsWithTheIssueNumberInAnyProject() {
        let snap = snapshot(tickets: ["STORE-2474", "WA-2474", "STORE-24740", "WA-247"].map { makeTicket(key: $0) })
        let result = items("2474", snap)
        #expect(result.map(\.title) == ["STORE-2474 S", "WA-2474 S"])
        #expect(result.map(\.kind) == [.ticket, .ticket])
    }

    @Test func findsSessionsByJiraKeyOrFolderName() {
        let snap = snapshot(sessions: [
            session(pid: 1, cwd: "/work/anything", jiraKey: "STORE-2474", status: .waiting),
            session(pid: 2, cwd: "/work/store-2474-fix", status: .busy),
            session(pid: 3, cwd: "/work/2474"),
            session(pid: 4, cwd: "/2474/other"),
            session(pid: 5, cwd: "/work/other", jiraKey: "STORE-24"),
        ])
        let result = items("2474", snap)
        #expect(result.map(\.target) == [.session(pid: 1), .session(pid: 2), .session(pid: 3)])
        #expect(result.map(\.kind) == [.session(.waiting), .session(.busy), .session(.idle)])
        #expect(result[0].title == "s1 STORE-2474")
        #expect(result[0].subtitle == "Claude Code session · waiting for input · /work/anything")
        #expect(result[1].subtitle == "Claude Code session · busy · /work/store-2474-fix")
    }

    @Test func matchesOnlyTheWholeNumber() {
        let snap = snapshot(
            mine: [makePR(number: 2474)],
            tickets: [makeTicket(key: "STORE-2474")],
            sessions: [
                session(pid: 1, cwd: "/work/store-2474"), session(pid: 2, cwd: "/work/x", jiraKey: "STORE-2474"),
                session(pid: 3, cwd: "/work/1247"), session(pid: 4, cwd: "/work/v247-b"),
            ])
        // Only the session matches; the rest are the fallbacks (most frequent repo and project).
        #expect(items("247", snap).map(\.target) == [
            .session(pid: 4), url("https://github.com/acme/app/pull/247"), url("https://acme.atlassian.net/browse/STORE-247"),
        ])
    }

    @Test func listsPullRequestsThenTicketsThenSessions() {
        let snap = snapshot(
            review: [makePR(repo: "acme/api", number: 12)], tickets: [makeTicket(key: "STORE-12")],
            sessions: [session(pid: 9, cwd: "/work/store-12")])
        #expect(items("12", snap).map(\.kind) == [.reviewRequest(direct: false), .ticket, .session(.idle)])
    }

    @Test func addsFallbackRowsForTheDefaultRepoAndProject() {
        var settings = AppSettings()
        settings.defaultRepo = "acme/store"
        settings.defaultJiraProject = "STORE"
        let result = items("2474", snapshot(), settings)
        #expect(result.map(\.title) == ["Open acme/store#2474", "Open STORE-2474"])
        #expect(result.map(\.target) == [
            url("https://github.com/acme/store/pull/2474"), url("https://acme.atlassian.net/browse/STORE-2474"),
        ])
        #expect(result.map(\.kind) == [.pullRequest, .ticket])
    }

    @Test func fallbacksUseTheMostFrequentRepoAndProject() {
        let snap = snapshot(
            mine: [makePR(repo: "a/x", number: 1), makePR(repo: "b/y", number: 2), makePR(repo: "b/y", number: 3)],
            tickets: ["WA-1", "STORE-2", "STORE-3"].map { makeTicket(key: $0) })
        #expect(items("2474", snap).map(\.title) == ["Open b/y#2474", "Open STORE-2474"])
    }

    @Test func fallbacksAreLeftOutWhenTheirItemIsListed() {
        var settings = AppSettings()
        settings.defaultRepo = "acme/store"
        settings.defaultJiraProject = "STORE"
        let snap = snapshot(mine: [makePR(repo: "acme/store", number: 2474)], tickets: [makeTicket(key: "STORE-2474")])
        #expect(items("2474", snap, settings).map(\.title) == ["#2474 PR 2474", "STORE-2474 S"])
        // A match in another repo or project keeps the fallback.
        let other = snapshot(mine: [makePR(repo: "acme/api", number: 2474)], tickets: [makeTicket(key: "WA-2474")])
        #expect(items("2474", other, settings).map(\.title)
            == ["#2474 PR 2474", "WA-2474 S", "Open acme/store#2474", "Open STORE-2474"])
        // The repo compares without case, like `gh`.
        let upper = snapshot(mine: [makePR(repo: "Acme/Store", number: 2474)])
        #expect(items("2474", upper, settings).map(\.title) == ["#2474 PR 2474", "Open STORE-2474"])
    }

    @Test func theJiraFallbackNeedsASite() {
        var settings = AppSettings()
        settings.defaultJiraProject = "STORE"
        #expect(items("2474", snapshot(jiraBaseURL: nil), settings).isEmpty)
    }

    @Test func prefixedQueriesKeepTheirKinds() {
        let snap = snapshot(mine: [makePR(number: 1)], review: [makePR(number: 2)], tickets: [makeTicket(key: "STORE-1")])
        #expect(items("gh", snap).map(\.kind) == [.pullRequest, .reviewRequest(direct: false)])
        #expect(items("jira", snap).map(\.kind) == [.ticket])
    }
}
