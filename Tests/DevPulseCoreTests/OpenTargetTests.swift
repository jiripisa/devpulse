import Foundation
import Testing
@testable import DevPulseCore

private func makeSnapshot(jiraBaseURL: String? = "https://acme.atlassian.net") -> Snapshot {
    let ok = SourceStatus(state: .ok)
    var mine = makePR(repo: "acme/app", number: 1, id: "PR_mine")
    mine.jiraKey = "ABC-12"
    let review = makePR(repo: "acme/api", number: 2, id: "PR_review")
    return Snapshot(
        appVersion: "1", generatedAt: Date(timeIntervalSince1970: 0), jiraBaseURL: jiraBaseURL,
        sources: Sources(github: ok, jira: ok, claude: ok),
        myPullRequests: [mine], reviewRequests: [review], tickets: [makeTicket(key: "ABC-7")],
        sessions: [ClaudeSession(pid: 4242, name: "s", cwd: "/x", status: .idle, updatedAt: Date())])
}

@Suite struct OpenResolverTests {
    @Test func prOpensItsURL() {
        #expect(OpenResolver.target(for: .pr, id: "PR_mine", in: makeSnapshot())
            == .url(URL(string: "https://github.com/acme/app/pull/1")!))
    }

    @Test func prAlsoFindsReviewRequests() {
        #expect(OpenResolver.target(for: .pr, id: "PR_review", in: makeSnapshot())
            == .url(URL(string: "https://github.com/acme/api/pull/2")!))
    }

    @Test func jiraForPrOpensTheLinkedTicket() {
        #expect(OpenResolver.target(for: .jiraForPr, id: "PR_mine", in: makeSnapshot())
            == .url(URL(string: "https://acme.atlassian.net/browse/ABC-12")!))
    }

    @Test func jiraForPrToleratesATrailingSlash() {
        #expect(OpenResolver.target(for: .jiraForPr, id: "PR_mine", in: makeSnapshot(jiraBaseURL: "https://acme.atlassian.net/"))
            == .url(URL(string: "https://acme.atlassian.net/browse/ABC-12")!))
    }

    @Test func jiraForPrWithoutKeyOrSiteIsNil() {
        #expect(OpenResolver.target(for: .jiraForPr, id: "PR_review", in: makeSnapshot()) == nil)
        #expect(OpenResolver.target(for: .jiraForPr, id: "PR_mine", in: makeSnapshot(jiraBaseURL: nil)) == nil)
    }

    @Test func ticketOpensItsURL() {
        #expect(OpenResolver.target(for: .ticket, id: "ABC-7", in: makeSnapshot())
            == .url(URL(string: "https://acme.atlassian.net/browse/ABC-7")!))
    }

    @Test func ticketNotInMyListOpensByKeyOnTheSite() {
        // A Claude session's key (TUI `J`) need not be one of my tickets.
        #expect(OpenResolver.target(for: .ticket, id: "OTHER-3", in: makeSnapshot())
            == .url(URL(string: "https://acme.atlassian.net/browse/OTHER-3")!))
        #expect(OpenResolver.target(for: .ticket, id: "OTHER-3", in: makeSnapshot(jiraBaseURL: nil)) == nil)
        #expect(OpenResolver.target(for: .ticket, id: "OTHER-3 x", in: makeSnapshot()) == nil)
    }

    @Test func sessionFocusesItsPid() {
        #expect(OpenResolver.target(for: .session, id: "4242", in: makeSnapshot()) == .session(pid: 4242))
    }

    @Test(arguments: [OpenKind.pr, .jiraForPr, .ticket, .session])
    func unknownIdIsNil(kind: OpenKind) {
        #expect(OpenResolver.target(for: kind, id: "nope", in: makeSnapshot()) == nil)
        #expect(OpenResolver.target(for: kind, id: "999", in: makeSnapshot()) == nil)
    }
}

@Suite struct OpenTargetUserInfoTests {
    @Test(arguments: [OpenTarget.url(URL(string: "https://github.com/acme/app/pull/1")!), .session(pid: 77)])
    func roundTrips(target: OpenTarget) {
        let info: [AnyHashable: Any] = target.userInfo
        #expect(OpenTarget(userInfo: info) == target)
    }

    @Test func garbageIsNil() {
        #expect(OpenTarget(userInfo: [:]) == nil)
        #expect(OpenTarget(userInfo: ["target": "session", "pid": "x"]) == nil)
        #expect(OpenTarget(userInfo: ["target": "url"]) == nil)
        #expect(OpenTarget(userInfo: ["target": "other", "url": "https://a.b"]) == nil)
    }
}
