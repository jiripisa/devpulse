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
        settings.githubRepos = ["acmecorp/store"]
        let result = items("gh 999", snapshot(), settings)
        #expect(result.map(\.target) == [url("https://github.com/acmecorp/store/pull/999")])
    }

    @Test func ghNumberWithoutMatchAndWithoutDefaultRepoHasNoItems() {
        #expect(items("gh 999", snapshot()).isEmpty)
    }

    @Test func ghNumberPrefillsTheDefaultRepoFromTheMostFrequentOne() {
        let snap = snapshot(mine: [makePR(repo: "a/x", number: 1), makePR(repo: "b/y", number: 2), makePR(repo: "b/y", number: 3)])
        #expect(items("gh 999", snap).map(\.target)
            == [url("https://github.com/b/y/pull/999"), url("https://github.com/a/x/pull/999")])
        // An explicit default wins and is not written back.
        var settings = AppSettings()
        settings.githubRepos = ["a/x"]
        #expect(items("gh 999", snap, settings).map(\.target) == [url("https://github.com/a/x/pull/999")])
        #expect(settings.githubRepos == ["a/x"])
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
        settings.jiraProjects = ["STORE"]
        #expect(items("jira 2290", snapshot(), settings).map(\.target) == [url("https://acme.atlassian.net/browse/STORE-2290")])
    }

    @Test func jiraNumberPrefillsTheDefaultProjectFromTheMostFrequentOne() {
        let snap = snapshot(tickets: ["WA-1", "STORE-2", "STORE-3"].map { makeTicket(key: $0) })
        #expect(items("jira 2290", snap).map(\.target) == [
            url("https://acme.atlassian.net/browse/STORE-2290"), url("https://acme.atlassian.net/browse/WA-2290"),
        ])
        #expect(items("jira 2290", snapshot()).isEmpty)
    }

    @Test func jiraSiteFromSettingsIsUsedAndMissingSiteOmitsTheItem() {
        var settings = AppSettings()
        settings.jiraSite = URL(string: "https://corp.atlassian.net")
        #expect(items("jira ABC-1", snapshot(jiraBaseURL: nil), settings).map(\.target)
            == [url("https://corp.atlassian.net/browse/ABC-1")])
        #expect(items("jira ABC-1", snapshot(jiraBaseURL: nil)).isEmpty)
        var withProject = AppSettings()
        withProject.jiraProjects = ["ABC"]
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
        settings.githubRepos = ["acme/store"]
        settings.jiraProjects = ["STORE"]
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
        #expect(items("2474", snap).map(\.title)
            == ["Open b/y#2474", "Open a/x#2474", "Open STORE-2474", "Open WA-2474"])
    }

    @Test func fallbacksAreLeftOutWhenTheirItemIsListed() {
        var settings = AppSettings()
        settings.githubRepos = ["acme/store"]
        settings.jiraProjects = ["STORE"]
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
        settings.jiraProjects = ["STORE"]
        #expect(items("2474", snapshot(jiraBaseURL: nil), settings).isEmpty)
    }

    @Test func prefixedQueriesKeepTheirKinds() {
        let snap = snapshot(mine: [makePR(number: 1)], review: [makePR(number: 2)], tickets: [makeTicket(key: "STORE-1")])
        #expect(items("gh", snap).map(\.kind) == [.pullRequest, .reviewRequest(direct: false)])
        #expect(items("jira", snap).map(\.kind) == [.ticket])
    }
}

@Suite struct LauncherLookupResolverTests {
    private func settings(projects: [String] = ["STORE", "WA"], repo: String? = "acme/store") -> AppSettings {
        var settings = AppSettings()
        settings.jiraProjects = projects
        settings.githubRepos = repo.map { [$0] } ?? []
        return settings
    }

    private func request(_ input: String, _ snapshot: Snapshot, _ settings: AppSettings) -> LookupRequest {
        LauncherResolver.lookupRequest(for: .parse(input), snapshot: snapshot, settings: settings)
    }

    private func items(
        _ input: String, _ snapshot: Snapshot, _ settings: AppSettings, _ lookup: LookupResults = LookupResults()
    ) -> [LauncherItem] {
        LauncherResolver.items(for: .parse(input), snapshot: snapshot, settings: settings, lookup: lookup)
    }

    private func ticket(_ key: String, _ summary: String, status: String = "In Progress") -> Ticket {
        var ticket = makeTicket(key: key)
        ticket.summary = summary
        ticket.status = status
        return ticket
    }

    private func found(_ ref: PullRequestRef, _ title: String, _ state: PullRequestSummary.State) -> PullRequestSummary {
        PullRequestSummary(
            repo: ref.repo, number: ref.number, title: title, state: state,
            url: "https://github.com/\(ref.repo)/pull/\(ref.number)")
    }

    @Test func aBareNumberLooksUpEveryProjectAndTheDefaultRepo() {
        let snap = snapshot(tickets: [makeTicket(key: "STORE-5")])
        #expect(request("2474", snap, settings()) == LookupRequest(
            ticketKeys: ["STORE-2474", "WA-2474"], pullRequests: [PullRequestRef(repo: "acme/store", number: 2474)]))
        #expect(items("2474", snap, settings()).map(\.title) == ["Open acme/store#2474", "Open STORE-2474", "Open WA-2474"])
    }

    @Test func knownTicketsAndPullRequestsNeedNoLookup() {
        var snap = snapshot(mine: [makePR(repo: "acme/store", number: 2474)])
        snap.linkedTickets = [ticket("WA-2474", "Fix login")]
        #expect(request("2474", snap, settings()) == LookupRequest(ticketKeys: ["STORE-2474"], pullRequests: []))
        // A PR's ticket that is not mine is listed like mine.
        #expect(items("2474", snap, settings()).map(\.title) == ["#2474 PR 2474", "WA-2474 Fix login", "Open STORE-2474"])
    }

    @Test func foundRowsShowTheTitleAndMissingOnesAreLeftOut() {
        let ref = PullRequestRef(repo: "acme/store", number: 2474)
        var lookup = LookupResults()
        lookup.tickets["WA-2474"] = ticket("WA-2474", "Fix login")
        lookup.missingTickets = ["STORE-2474"]
        lookup.pullRequests[ref] = found(ref, "Faster checkout", .merged)
        let result = items("2474", snapshot(), settings(), lookup)
        #expect(result.map(\.title) == ["#2474 Faster checkout", "WA-2474 Fix login"])
        #expect(result.map(\.subtitle) == ["acme/store · Merged", "In Progress"])
        #expect(result.map(\.kind) == [.pullRequest, .ticket])
        #expect(result[0].target == url("https://github.com/acme/store/pull/2474"))
        lookup.missingPullRequests = [ref]
        lookup.pullRequests = [:]
        #expect(items("2474", snapshot(), settings(), lookup).map(\.title) == ["WA-2474 Fix login"])
    }

    @Test func theRepoOfAPullRequestRefComparesWithoutCase() {
        #expect(PullRequestRef(repo: "Acme/Store", number: 1) == PullRequestRef(repo: "acme/store", number: 1))
        var lookup = LookupResults()
        let ref = PullRequestRef(repo: "acme/store", number: 7)
        lookup.pullRequests[ref] = found(ref, "Seven", .open)
        #expect(items("gh 7", snapshot(), settings(repo: "Acme/Store"), lookup).map(\.title) == ["#7 Seven"])
    }

    @Test func aTypedKeyOrRepoThatDoesNotExistSaysSo() {
        var lookup = LookupResults()
        lookup.missingTickets = ["WA-9", "STORE-9"]
        lookup.missingPullRequests = [PullRequestRef(repo: "acme/store", number: 9)]
        let jira = items("jira WA-9", snapshot(), settings(), lookup)
        #expect(jira.map(\.title) == ["Open WA-9"])
        #expect(jira.map(\.subtitle) == ["Not found in Jira"])
        let gh = items("gh 9", snapshot(), settings(), lookup)
        #expect(gh.map(\.title) == ["Open acme/store#9"])
        #expect(gh.map(\.subtitle) == ["Not found on GitHub"])
        // `jira <number>` keeps its default project's row, the other projects' rows go.
        let number = items("jira 9", snapshot(), settings(), lookup)
        #expect(number.map(\.title) == ["Open STORE-9"])
        #expect(number.map(\.subtitle) == ["Not found in Jira"])
    }

    @Test func jiraNumberLooksUpEveryProject() {
        #expect(request("jira 9", snapshot(), settings()) == LookupRequest(ticketKeys: ["STORE-9", "WA-9"], pullRequests: []))
        var lookup = LookupResults()
        lookup.tickets["WA-9"] = ticket("WA-9", "Nine")
        lookup.missingTickets = ["STORE-9"]
        #expect(items("jira 9", snapshot(), settings(), lookup).map(\.title) == ["Open STORE-9", "WA-9 Nine"])
    }

    @Test func listingsAndKnownItemsLookNothingUp() {
        let snap = snapshot(mine: [makePR(repo: "acme/store", number: 1)], tickets: [makeTicket(key: "STORE-1")])
        for input in ["gh", "gh login", "jira", "jira login", "jira STORE-1", "gh 1", "xyz", ""] {
            #expect(request(input, snap, settings()).isEmpty, "\(input)")
        }
        #expect(request("gh acme/api 4", snap, settings()) == LookupRequest(
            ticketKeys: [], pullRequests: [PullRequestRef(repo: "acme/api", number: 4)]))
        #expect(request("jira WA-4", snap, settings()) == LookupRequest(ticketKeys: ["WA-4"], pullRequests: []))
    }

    @Test func aBareNumberLooksUpEveryRepository() {
        var config = settings(projects: [])
        config.githubRepos = ["acme/store", "acme/api"]
        let snap = snapshot(review: [makePR(repo: "acme/api", number: 12)])
        #expect(request("12", snap, config).pullRequests == [PullRequestRef(repo: "acme/store", number: 12)])
        #expect(request("13", snap, config).pullRequests
            == [PullRequestRef(repo: "acme/store", number: 13), PullRequestRef(repo: "acme/api", number: 13)])
        var lookup = LookupResults()
        let api = PullRequestRef(repo: "acme/api", number: 13)
        lookup.pullRequests[api] = found(api, "Api thirteen", .draft)
        lookup.missingPullRequests = [PullRequestRef(repo: "acme/store", number: 13)]
        let result = items("13", snap, config, lookup)
        #expect(result.map(\.title) == ["#13 Api thirteen"])
        #expect(result.map(\.subtitle) == ["acme/api · Draft"])
    }

    @Test func ghNumberLooksUpEveryRepositoryAndKeepsTheFirstOne() {
        var config = settings(projects: [])
        config.githubRepos = ["acme/store", "acme/api"]
        #expect(request("gh 9", snapshot(), config).pullRequests
            == [PullRequestRef(repo: "acme/store", number: 9), PullRequestRef(repo: "acme/api", number: 9)])
        var lookup = LookupResults()
        lookup.missingPullRequests = [PullRequestRef(repo: "acme/store", number: 9), PullRequestRef(repo: "acme/api", number: 9)]
        let result = items("gh 9", snapshot(), config, lookup)
        #expect(result.map(\.title) == ["Open acme/store#9"])
        #expect(result.map(\.subtitle) == ["Not found on GitHub"])
        // A known PR of that number comes first; the repositories without it follow.
        let snap = snapshot(mine: [makePR(repo: "acme/api", number: 9)])
        #expect(items("gh 9", snap, config).map(\.title) == ["#9 PR 9", "Open acme/store#9"])
    }

    @Test func ghRepoNameResolvesFromTheRepositoryList() {
        var config = settings(projects: [])
        config.githubRepos = ["acme/store", "Acme/API"]
        #expect(request("gh api 4", snapshot(), config).pullRequests == [PullRequestRef(repo: "Acme/API", number: 4)])
        #expect(items("gh nowhere 4", snapshot(), config).isEmpty)
    }

    @Test func withoutAJiraSiteNoTicketIsLookedUp() {
        let snap = snapshot(jiraBaseURL: nil)
        #expect(request("2474", snap, settings()).ticketKeys.isEmpty)
        #expect(request("jira WA-1", snap, settings()).isEmpty)
    }
}
