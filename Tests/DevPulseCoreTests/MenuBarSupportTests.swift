import Foundation
import Testing
@testable import DevPulseCore

private let now = Date(timeIntervalSince1970: 10_000)

private func makeSession(pid: Int, status: SessionStatus) -> ClaudeSession {
    ClaudeSession(pid: pid, name: "s\(pid)", cwd: "/tmp", status: status, updatedAt: now)
}

private func makeSnapshot(
    reviewRequests: [PullRequest] = [], sessions: [ClaudeSession] = []
) -> Snapshot {
    let ok = SourceStatus(state: .ok)
    return Snapshot(
        appVersion: "0.1.0", generatedAt: now, sources: Sources(github: ok, jira: ok, claude: ok),
        myPullRequests: [makePR(number: 99)], reviewRequests: reviewRequests, tickets: [],
        sessions: sessions)
}

@Suite struct AttentionCountTests {
    @Test func emptySnapshotNeedsNothing() {
        #expect(makeSnapshot().attentionCount == 0)
    }

    @Test func countsDirectReviewRequestsAndWaitingSessions() {
        var direct = makePR(number: 1)
        direct.requestedDirectly = true
        let team = makePR(number: 2)
        let snapshot = makeSnapshot(
            reviewRequests: [direct, team],
            sessions: [
                makeSession(pid: 1, status: .waiting), makeSession(pid: 2, status: .busy),
                makeSession(pid: 3, status: .idle), makeSession(pid: 4, status: .waiting),
                makeSession(pid: 5, status: .unknown),
            ])
        #expect(snapshot.attentionCount == 3)
    }
}

@Suite struct SessionStateTextTests {
    @Test func saysWhatTheSessionDoes() {
        var waiting = makeSession(pid: 1, status: .waiting)
        #expect(waiting.stateText == "waiting for input")
        waiting.waitingFor = "permission"
        #expect(waiting.stateText == "waiting: permission")
        #expect(makeSession(pid: 2, status: .busy).stateText == "busy")
        #expect(makeSession(pid: 3, status: .idle).stateText == "idle")
        #expect(makeSession(pid: 4, status: .unknown).stateText == "unknown")
    }
}

@Suite struct RelativeAgeTests {
    @Test func formatsMinutesHoursAndDays() {
        let text = { (seconds: TimeInterval) in RelativeAge.text(since: now.addingTimeInterval(-seconds), now: now) }
        #expect(text(0) == "just now")
        #expect(text(59) == "just now")
        #expect(text(60) == "1 min ago")
        #expect(text(119) == "1 min ago")
        #expect(text(120) == "2 min ago")
        #expect(text(59 * 60) == "59 min ago")
        #expect(text(3600) == "1 h ago")
        #expect(text(23 * 3600 + 3599) == "23 h ago")
        #expect(text(86_400) == "1 d ago")
        #expect(text(3 * 86_400) == "3 d ago")
    }

    @Test func aFutureDateCountsAsJustNow() {
        #expect(RelativeAge.text(since: now.addingTimeInterval(30), now: now) == "just now")
    }
}

@Suite struct SourceStatusTextTests {
    let fiveMinutesAgo = now.addingTimeInterval(-300)

    @Test func okShowsTheAge() {
        #expect(SourceStatusText.text(for: SourceStatus(state: .ok, lastSuccess: fiveMinutesAgo), now: now)
            == "5 min ago")
        #expect(SourceStatusText.text(for: SourceStatus(state: .ok), now: now) == "OK")
    }

    @Test func okWithAWarningShowsBoth() {
        let status = SourceStatus(state: .ok, lastSuccess: fiveMinutesAgo, message: "partial data")
        #expect(SourceStatusText.text(for: status, now: now) == "partial data · 5 min ago")
    }

    @Test func errorShowsTheMessageAndTheDataAge() {
        let status = SourceStatus(state: .error, lastSuccess: fiveMinutesAgo, message: "Offline")
        #expect(SourceStatusText.text(for: status, now: now) == "Offline · data from 5 min ago")
        #expect(SourceStatusText.text(for: SourceStatus(state: .error), now: now) == "Error")
    }

    @Test func otherStates() {
        #expect(SourceStatusText.text(for: SourceStatus(state: .fetching), now: now) == "Loading…")
        #expect(SourceStatusText.text(for: SourceStatus(state: .disabled), now: now) == "Off")
        #expect(SourceStatusText.text(for: SourceStatus(state: .unconfigured), now: now) == "Not configured")
    }
}

@Suite struct SectionPlaceholderTests {
    private func placeholder(_ state: SourceState, lastSuccess: Date? = nil) -> SectionPlaceholder {
        SourceStatusText.placeholder(for: SourceStatus(state: state, lastSuccess: lastSuccess), empty: "No review requests")
    }

    @Test func followsTheSourceState() {
        #expect(placeholder(.unconfigured) == .setUp)
        #expect(placeholder(.disabled) == .text("Turned off in Settings"))
        #expect(placeholder(.fetching) == .text("Loading…"))
        #expect(placeholder(.ok) == .text("No review requests"))
    }

    @Test func errorClaimsNothingWithoutData() {
        #expect(placeholder(.error) == .text("Could not load"))
        // After an earlier success the (empty) list is real, only possibly stale.
        #expect(placeholder(.error, lastSuccess: now) == .text("No review requests"))
    }
}

@Suite struct JiraCredentialsResolveTests {
    private let site = URL(string: "https://acme.atlassian.net")!

    @Test func needsSiteEmailAndToken() {
        var settings = AppSettings(jiraSite: site, jiraEmail: "me@acme.io")
        var asked: [String] = []
        let credentials = JiraCredentials.resolve(settings: settings) { account in
            asked.append(account)
            return "tok"
        }
        #expect(asked == ["me@acme.io"])
        #expect(credentials?.site == site)
        #expect(credentials?.email == "me@acme.io")
        #expect(credentials?.token == "tok")

        #expect(JiraCredentials.resolve(settings: settings) { _ in nil } == nil)
        #expect(JiraCredentials.resolve(settings: settings) { _ in "" } == nil)
        settings.jiraEmail = ""
        #expect(JiraCredentials.resolve(settings: settings) { _ in "tok" } == nil)
        settings.jiraEmail = nil
        #expect(JiraCredentials.resolve(settings: settings) { _ in "tok" } == nil)
        #expect(JiraCredentials.resolve(settings: AppSettings(jiraEmail: "me@acme.io")) { _ in "tok" } == nil)
    }

    @Test func keychainServiceName() {
        #expect(JiraCredentials.keychainService == "io.jp4.devpulse.jira")
    }
}

@Suite struct SettingsRefetchTests {
    @Test func onlySourceRelatedChangesNeedARefetch() {
        let base = AppSettings()
        var changed = base
        changed.refreshInterval = 600
        changed.defaultRepo = "acme/app"
        changed.triggers[.ciFinished] = false
        changed.launchAtLogin = false
        changed.notificationsEnabled[.claude] = false
        #expect(!changed.requiresRefetch(comparedTo: base))

        for change: (inout AppSettings) -> Void in [
            { $0.sourceEnabled[.jira] = false },
            { $0.includeTeamReviewRequests = true },
            { $0.jiraSite = URL(string: "https://acme.atlassian.net") },
            { $0.jiraEmail = "me@acme.io" },
        ] {
            var settings = base
            change(&settings)
            #expect(settings.requiresRefetch(comparedTo: base))
        }
    }
}
