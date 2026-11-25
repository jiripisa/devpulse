import Foundation
import Testing
@testable import DevPulseCore

private typealias Comment = DevPulseCore.Comment

private let t0 = Date(timeIntervalSince1970: 0)

private func comment(
    _ id: String, by author: String = "alice", kind: AuthorKind = .human, name: String? = nil,
    at: Date = t0
) -> Comment {
    Comment(id: id, author: author, authorName: name, authorKind: kind, createdAt: at)
}

private func pr(
    _ number: Int = 1, oid: String = "abc", checks: CheckState = .none, direct: Bool = true,
    comments: [Comment] = []
) -> PullRequest {
    var p = makePR(number: number)
    p.headOid = oid
    p.checks = checks
    p.requestedDirectly = direct
    p.recentComments = comments
    return p
}

private func ticket(_ key: String = "ABC-1", comments: [Comment] = []) -> Ticket {
    var t = makeTicket(key: key)
    t.recentComments = comments
    return t
}

private func session(_ pid: Int, _ status: SessionStatus, waitingFor: String? = nil) -> ClaudeSession {
    ClaudeSession(pid: pid, name: "proj", cwd: "/x", status: status, waitingFor: waitingFor, updatedAt: t0)
}

private func snap(
    github: SourceState = .ok, jira: SourceState = .ok, claude: SourceState = .ok,
    mine: [PullRequest] = [], reviews: [PullRequest] = [], tickets: [Ticket] = [],
    sessions: [ClaudeSession] = [], at: Date = t0
) -> Snapshot {
    Snapshot(
        appVersion: "1", generatedAt: at,
        sources: Sources(
            github: SourceStatus(state: github, lastSuccess: at), jira: SourceStatus(state: jira, lastSuccess: at),
            claude: SourceStatus(state: claude)),
        myPullRequests: mine, reviewRequests: reviews, tickets: tickets, sessions: sessions)
}

private func run(
    _ old: Snapshot?, _ new: Snapshot, _ seen: inout SeenState,
    settings: AppSettings = AppSettings(), login: String? = "me", account: String? = "acc"
) -> [NotificationEvent] {
    ChangeDetector.events(
        old: old, new: new, myGitHubLogin: login, myJiraAccountId: account, settings: settings, seen: &seen)
}

@Suite struct ChangeDetectorTests {
    // MARK: Baseline

    @Test func firstOkSnapshotBaselinesWithoutEvents() {
        var seen = SeenState()
        let s = snap(mine: [pr(comments: [comment("1"), comment("2"), comment("3")])], reviews: [pr(2)])
        #expect(run(nil, s, &seen).isEmpty)
        #expect(seen.baselined.contains(.github))
        #expect(seen.comments.count == 3)
    }

    @Test func disabledSourceIsRemovedFromBaselineSoReenablingBaselinesAgain() {
        var seen = SeenState()
        _ = run(nil, snap(), &seen)
        #expect(seen.baselined.contains(.github))
        _ = run(nil, snap(github: .disabled), &seen)
        #expect(!seen.baselined.contains(.github))
        #expect(run(nil, snap(reviews: [pr(5)]), &seen).isEmpty)
    }

    @Test func unconfiguredSourceIsRemovedFromBaseline() {
        var seen = SeenState(baselined: [.jira])
        _ = run(nil, snap(jira: .unconfigured), &seen)
        #expect(!seen.baselined.contains(.jira))
    }

    // MARK: Review requests

    @Test func newDirectReviewRequestNotifiesOnce() {
        var seen = SeenState()
        let first = snap()
        _ = run(nil, first, &seen)
        let second = snap(reviews: [pr(7)])
        let events = run(first, second, &seen)
        #expect(events == [.reviewRequested(pr(7), direct: true)])
        #expect(run(second, snap(reviews: [pr(7)], at: Date(timeIntervalSince1970: 60)), &seen).isEmpty)
    }

    @Test func teamRequestWithTriggerOffGivesNothing() {
        var seen = SeenState()
        _ = run(nil, snap(), &seen)
        #expect(run(nil, snap(reviews: [pr(7, direct: false)]), &seen).isEmpty)
        var settings = AppSettings()
        settings.triggers[.teamReviewRequest] = true
        #expect(run(nil, snap(reviews: [pr(8, direct: false)]), &seen, settings: settings).count == 1)
    }

    // MARK: PR comments

    @Test func ownPrCommentGivesNothing() {
        var seen = SeenState()
        _ = run(nil, snap(mine: [pr()]), &seen)
        #expect(run(nil, snap(mine: [pr(comments: [comment("1", by: "me")])]), &seen).isEmpty)
    }

    @Test func copilotCommentUsesCopilotTrigger() {
        var seen = SeenState()
        _ = run(nil, snap(mine: [pr()]), &seen)
        let c = comment("1", by: "copilot", kind: .copilot)
        let events = run(nil, snap(mine: [pr(comments: [c])]), &seen)
        #expect(events.count == 1)
        #expect(events.first?.trigger == .prCopilotComment)
    }

    @Test func botCommentWithDefaultsGivesNothingButIsRemembered() {
        var seen = SeenState()
        _ = run(nil, snap(mine: [pr()]), &seen)
        #expect(run(nil, snap(mine: [pr(comments: [comment("1", kind: .bot)])]), &seen).isEmpty)
        #expect(seen.comments.contains("github:1"))
    }

    @Test func humanCommentNotifiesOnce() {
        var seen = SeenState()
        _ = run(nil, snap(mine: [pr()]), &seen)
        let s = snap(mine: [pr(comments: [comment("1")])])
        #expect(run(nil, s, &seen).first?.trigger == .prHumanComment)
        #expect(run(nil, s, &seen).isEmpty)
    }

    // MARK: CI

    @Test func ciPendingToSuccessNotifiesOnce() {
        var seen = SeenState()
        let pending = snap(mine: [pr(checks: .pending)])
        _ = run(nil, pending, &seen)
        let done = snap(mine: [pr(checks: .success)])
        #expect(run(pending, done, &seen) == [.ciFinished(pr(checks: .success), .success)])
        #expect(run(done, done, &seen).isEmpty)
    }

    @Test func newHeadAlreadyFailedNotifies() {
        var seen = SeenState()
        let ok = snap(mine: [pr(oid: "abc", checks: .success)])
        _ = run(nil, ok, &seen)
        let failed = snap(mine: [pr(oid: "def", checks: .failure)])
        #expect(run(ok, failed, &seen) == [.ciFinished(pr(oid: "def", checks: .failure), .failure)])
    }

    @Test func finalCiStateAtBaselineIsSilent() {
        var seen = SeenState()
        #expect(run(nil, snap(mine: [pr(checks: .failure)]), &seen).isEmpty)
        #expect(seen.ciNotified == ["acme/app#1@abc:failure"])
    }

    // MARK: Jira

    @Test func ticketCommentsMapKindsAndSkipOwn() {
        var seen = SeenState()
        _ = run(nil, snap(tickets: [ticket()]), &seen)
        let s = snap(tickets: [ticket(comments: [
            comment("1"), comment("2", by: "acc"), comment("3", kind: .bot)])])
        let events = run(nil, s, &seen)
        #expect(events.map(\.trigger) == [.jiraHumanComment])
    }

    @Test func linkedTicketsNeverNotify() {
        var seen = SeenState()
        _ = run(nil, snap(tickets: [ticket()]), &seen)
        // Someone else's ticket that a PR links to: a new human comment there stays silent,
        // and its ticket and comment are not remembered.
        var s = snap(tickets: [ticket()])
        s.linkedTickets = [ticket("OTHER-1", comments: [comment("1"), comment("2", kind: .bot)])]
        let before = seen
        #expect(run(nil, s, &seen).isEmpty)
        #expect(seen.comments == before.comments)
        // The same ticket becoming mine notifies as usual.
        let mine = snap(tickets: [ticket("OTHER-1", comments: [comment("1"), comment("3")])])
        #expect(run(nil, mine, &seen).map(\.trigger) == [.jiraHumanComment, .jiraHumanComment])
    }

    // MARK: Tickets I created

    private func made(_ key: String, _ status: String = "In Review") -> Ticket {
        var t = makeTicket(key: key)
        t.status = status
        return t
    }

    private func created(_ tickets: [Ticket], statuses: [String] = ["In Review"], at: Date = t0) -> Snapshot {
        var s = snap(at: at)
        s.createdTickets = tickets
        s.createdTicketStatuses = statuses
        return s
    }

    @Test func aTicketICreatedReachingAWatchedStatusNotifiesOnce() {
        var seen = SeenState()
        #expect(run(nil, created([made("MADE-1")]), &seen).isEmpty)
        let events = run(nil, created([made("MADE-1"), made("MADE-2")]), &seen)
        #expect(events == [.createdTicketReachedStatus(made("MADE-2"))])
        #expect(events.first?.trigger == .jiraCreatedTicketStatus)
        #expect(run(nil, created([made("MADE-1"), made("MADE-2")]), &seen).isEmpty)
    }

    @Test func aTicketThatLeavesAndComesBackNotifiesAgainAsDoesAnotherWatchedStatus() {
        var seen = SeenState()
        _ = run(nil, created([made("MADE-1")], statuses: ["In Review", "QA"]), &seen)
        #expect(run(nil, created([], statuses: ["In Review", "QA"]), &seen).isEmpty)
        #expect(run(nil, created([made("MADE-1")], statuses: ["In Review", "QA"]), &seen).count == 1)
        // From one watched status straight to another.
        let events = run(nil, created([made("MADE-1", "QA")], statuses: ["In Review", "QA"]), &seen)
        #expect(events == [.createdTicketReachedStatus(made("MADE-1", "QA"))])
    }

    @Test func switchingTheViewOnOrChangingTheStatusesStartsSilently() {
        var seen = SeenState()
        _ = run(nil, created([], statuses: []), &seen)
        // Turned on: what is already in review is the baseline, not news.
        #expect(run(nil, created([made("MADE-1"), made("MADE-2")]), &seen).isEmpty)
        #expect(run(nil, created([made("MADE-3", "QA")], statuses: ["QA"]), &seen).isEmpty)
        #expect(run(nil, created([made("MADE-3", "QA"), made("MADE-4", "QA")], statuses: ["QA"]), &seen).count == 1)
        // Off: nothing is remembered.
        _ = run(nil, created([], statuses: []), &seen)
        #expect(seen.createdTickets.isEmpty)
    }

    @Test func aFailedCreatedSearchChangesNothing() {
        var seen = SeenState()
        _ = run(nil, created([made("MADE-1")]), &seen)
        // Other statuses, but the first search for them failed: the list is empty meanwhile.
        var failed = created([], statuses: ["QA"])
        failed.createdTicketsError = "HTTP 503"
        #expect(run(nil, failed, &seen).isEmpty)
        #expect(seen.createdTicketStatuses == ["In Review"])
        // The first answer for the new statuses is still the baseline, not a burst.
        #expect(run(nil, created([made("MADE-5", "QA"), made("MADE-6", "QA")], statuses: ["QA"]), &seen).isEmpty)
    }

    @Test func theCreatedTicketTriggerCanBeSwitchedOff() {
        var seen = SeenState()
        var settings = AppSettings()
        settings.triggers[.jiraCreatedTicketStatus] = false
        _ = run(nil, created([]), &seen, settings: settings)
        #expect(run(nil, created([made("MADE-1")]), &seen, settings: settings).isEmpty)
        // Remembered all the same: switching it back on gives no burst.
        #expect(run(nil, created([made("MADE-1")]), &seen).isEmpty)
    }

    @Test func unknownIdentitySilencesSourceAndDoesNotBaseline() {
        var seen = SeenState()
        let s = snap(mine: [pr(comments: [comment("1")])], reviews: [pr(2)], tickets: [ticket(comments: [comment("9")])])
        #expect(run(nil, s, &seen, login: nil, account: nil).isEmpty)
        #expect(seen == SeenState(baselined: [.claude]))
        // Once the identity is known, the first pass is the baseline.
        #expect(run(nil, s, &seen).isEmpty)
        #expect(seen.baselined == [.github, .jira, .claude])
    }

    // MARK: Newly appearing PRs and tickets

    @Test func newTicketWithOldCommentsIsSilentButFreshCommentNotifies() {
        var seen = SeenState()
        let base = snap(at: Date(timeIntervalSince1970: 10_000))
        _ = run(nil, base, &seen)
        let now = Date(timeIntervalSince1970: 11_000)
        let old = (1...3).map { comment("o\($0)", at: Date(timeIntervalSince1970: 100)) }
        #expect(run(base, snap(tickets: [ticket(comments: old)], at: now), &seen).isEmpty)
        let fresh = comment("new", at: Date(timeIntervalSince1970: 11_500))
        let events = run(nil, snap(tickets: [ticket("ABC-2", comments: [fresh])], at: Date(timeIntervalSince1970: 12_000)), &seen)
        #expect(events == [.ticketComment(ticket("ABC-2", comments: [fresh]), fresh)])
    }

    @Test func newPrWithOldCommentsIsSilentButFreshCommentNotifies() {
        var seen = SeenState()
        let base = snap(at: Date(timeIntervalSince1970: 10_000))
        _ = run(nil, base, &seen)
        let old = comment("o", at: Date(timeIntervalSince1970: 100))
        #expect(run(base, snap(mine: [pr(1, comments: [old])], at: Date(timeIntervalSince1970: 11_000)), &seen).isEmpty)
        let fresh = comment("new", at: Date(timeIntervalSince1970: 11_500))
        let events = run(nil, snap(mine: [pr(2, comments: [fresh])], at: Date(timeIntervalSince1970: 12_000)), &seen)
        #expect(events.count == 1)
        #expect(events.first?.trigger == .prHumanComment)
    }

    @Test func teamRequestLaterRequestedDirectlyNotifiesAsDirect() {
        var seen = SeenState()
        var settings = AppSettings()
        settings.triggers[.teamReviewRequest] = true
        _ = run(nil, snap(), &seen, settings: settings)
        #expect(run(nil, snap(reviews: [pr(7, direct: false)]), &seen, settings: settings).count == 1)
        let events = run(nil, snap(reviews: [pr(7, direct: true)]), &seen, settings: settings)
        #expect(events == [.reviewRequested(pr(7, direct: true), direct: true)])
    }

    @Test func oldSeenFileWithoutLastCheckedStillDecodes() throws {
        let json = #"{"baselined":["github"],"reviewRequests":[],"comments":[],"ciNotified":[]}"#
        let state = try JSONDecoder().decode(SeenState.self, from: Data(json.utf8))
        #expect(state.lastChecked.isEmpty && state.baselined == [.github])
        #expect(state.createdTickets.isEmpty && state.createdTicketStatuses == nil)
    }

    // MARK: Claude

    @Test func claudeUnknownToWaitingNotifies() {
        var seen = SeenState()
        let events = run(
            snap(sessions: [session(1, .unknown)]), snap(sessions: [session(1, .waiting)]), &seen)
        #expect(events == [.claudeWaiting(session(1, .waiting))])
    }

    @Test func claudeSwitchOrTriggerOffSilencesWaiting() {
        var seen = SeenState()
        let old = snap(sessions: [session(1, .idle)])
        let new = snap(sessions: [session(1, .waiting)])
        var source = AppSettings()
        source.notificationsEnabled[.claude] = false
        #expect(run(old, new, &seen, settings: source).isEmpty)
        var trigger = AppSettings()
        trigger.triggers[.claudeWaiting] = false
        #expect(run(old, new, &seen, settings: trigger).isEmpty)
    }

    @Test func claudeIdleToWaitingNotifiesWaitingToWaitingDoesNot() {
        var seen = SeenState()
        let idle = snap(sessions: [session(77424, .idle)])
        let waiting = snap(sessions: [session(77424, .waiting, waitingFor: "approve")])
        #expect(run(idle, waiting, &seen) == [.claudeWaiting(session(77424, .waiting, waitingFor: "approve"))])
        #expect(run(waiting, waiting, &seen).isEmpty)
    }

    @Test func claudeBusyToIdleFinishes() {
        var seen = SeenState()
        let events = run(
            snap(sessions: [session(1, .busy)]), snap(sessions: [session(1, .idle)]), &seen)
        #expect(events == [.claudeFinished(session(1, .idle))])
    }

    @Test func claudeNoEventsOnLaunch() {
        var seen = SeenState()
        #expect(run(nil, snap(sessions: [session(1, .waiting)]), &seen).isEmpty)
    }

    // MARK: Switches, errors, pruning

    @Test func masterSwitchOffSilencesSource() {
        var seen = SeenState()
        _ = run(nil, snap(), &seen)
        var settings = AppSettings()
        settings.notificationsEnabled[.github] = false
        #expect(run(nil, snap(reviews: [pr(3)]), &seen, settings: settings).isEmpty)
    }

    @Test func notificationsOffSilenceOnlyThatSource() {
        var seen = SeenState()
        _ = run(nil, snap(sessions: [session(1, .idle)]), &seen)
        var settings = AppSettings()
        settings.notificationsEnabled[.claude] = false
        let events = run(
            snap(sessions: [session(1, .idle)]), snap(reviews: [pr(3)], sessions: [session(1, .waiting)]), &seen,
            settings: settings)
        #expect(events == [.reviewRequested(pr(3), direct: true)])
    }

    @Test func turningNotificationsBackOnGivesNoBurst() {
        var seen = SeenState()
        _ = run(nil, snap(), &seen)
        var off = AppSettings()
        off.notificationsEnabled[.github] = false
        let later = Date(timeIntervalSince1970: 60)
        let busy = snap(mine: [pr(checks: .success, comments: [comment("c1", at: later)])], reviews: [pr(5)], at: later)
        // New items while off: nothing posted, but they are recorded as seen.
        #expect(run(nil, busy, &seen, settings: off).isEmpty)
        // Back on, nothing new since: still nothing.
        #expect(run(nil, busy, &seen).isEmpty)
    }

    @Test func errorSourceGivesNoEventsAndChangesNothing() {
        var seen = SeenState()
        _ = run(nil, snap(mine: [pr(comments: [comment("1")])], tickets: [ticket(comments: [comment("2")])]), &seen)
        let before = seen
        let bad = snap(github: .error, jira: .error, claude: .error, reviews: [pr(9)])
        #expect(run(nil, bad, &seen).isEmpty)
        #expect(seen == before)
    }

    @Test func prunesToPresentIdsOnlyForOkSources() {
        var seen = SeenState()
        _ = run(nil, snap(mine: [pr(checks: .success, comments: [comment("1")])], reviews: [pr(2)],
                          tickets: [ticket(comments: [comment("2")])]), &seen)
        // GitHub ok but empty, Jira in error: only GitHub entries disappear.
        _ = run(nil, snap(jira: .error), &seen)
        #expect(seen.reviewRequests.isEmpty)
        #expect(seen.ciNotified.isEmpty)
        #expect(seen.comments == ["jira:2"])
    }

    @Test func timestampOnlyChangeGivesNothing() {
        var seen = SeenState()
        let a = snap(mine: [pr(checks: .success, comments: [comment("1")])], reviews: [pr(2)])
        _ = run(nil, a, &seen)
        #expect(run(a, snap(mine: a.myPullRequests, reviews: a.reviewRequests, at: Date(timeIntervalSince1970: 99)), &seen).isEmpty)
    }

    // MARK: Copy

    @Test func notificationCopy() {
        let p = pr(4, checks: .failure)
        #expect(NotificationEvent.reviewRequested(p, direct: true).title == "Review requested")
        #expect(NotificationEvent.reviewRequested(p, direct: true).body == "acme/app#4 PR 4")
        let c = comment("1", by: "alice", name: "Alice A")
        #expect(NotificationEvent.prComment(p, c).title == "New comment on #4")
        #expect(NotificationEvent.prComment(p, c).body == "Alice A: PR 4")
        #expect(NotificationEvent.ciFinished(p, .failure).title == "CI failed on #4")
        #expect(NotificationEvent.ciFinished(p, .success).title == "CI passed on #4")
        #expect(NotificationEvent.ciFinished(p, .error).title == "CI error on #4")
        #expect(NotificationEvent.ciFinished(p, .error).body == "acme/app PR 4")
        let t = ticket("ABC-9")
        #expect(NotificationEvent.ticketComment(t, comment("1")).title == "New comment on ABC-9")
        #expect(NotificationEvent.ticketComment(t, comment("1")).body == "alice: S")
        var review = ticket("ABC-7")
        review.status = "In Review"
        #expect(NotificationEvent.createdTicketReachedStatus(review).title == "ABC-7 is In Review")
        #expect(NotificationEvent.createdTicketReachedStatus(review).body == "S")
        #expect(NotificationEvent.createdTicketReachedStatus(review).target == .url(URL(string: review.url)!))
        #expect(NotificationEvent.claudeWaiting(session(5, .waiting)).body == "proj — needs your input")
        #expect(NotificationEvent.claudeWaiting(session(5, .waiting, waitingFor: "x")).body == "proj — x")
        #expect(NotificationEvent.claudeFinished(session(5, .idle)).body == "proj")
        #expect(NotificationEvent.claudeFinished(session(5, .idle)).target == .session(pid: 5))
        #expect(NotificationEvent.prComment(p, c).target == .url(URL(string: p.url)!))
    }

    // MARK: SeenState persistence

    @Test func seenStateRoundTripsAndToleratesMissingOrCorruptFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "nested/seen.json")
        #expect(SeenState.load(from: url) == SeenState())
        let state = SeenState(baselined: [.github], reviewRequests: ["a"], comments: ["github:1"], ciNotified: ["k"])
        try state.save(to: url)
        #expect(SeenState.load(from: url) == state)
        try Data("not json".utf8).write(to: url)
        #expect(SeenState.load(from: url) == SeenState())
    }

    @Test func seenStateIsSavedWhenTheSetsChangeAndLastCheckedOnlyEveryTenMinutes() {
        let t = Date(timeIntervalSince1970: 1_000)
        let saved = SeenState(baselined: [.github], comments: ["github:1"], lastChecked: [.github: t])
        var later = saved
        later.lastChecked[.github] = t.addingTimeInterval(120)
        // Only the timestamp moved: not before 10 minutes have passed since the last save.
        #expect(!later.needsSaving(comparedTo: saved, savedAt: t, now: t.addingTimeInterval(120)))
        #expect(later.needsSaving(comparedTo: saved, savedAt: t, now: t.addingTimeInterval(600)))
        // Never saved in this run: save.
        #expect(later.needsSaving(comparedTo: saved, savedAt: nil, now: t))
        // A changed set is saved at once.
        var seenMore = later
        seenMore.comments.insert("github:2")
        #expect(seenMore.needsSaving(comparedTo: saved, savedAt: t, now: t.addingTimeInterval(1)))
        // Nothing changed: nothing to save, however long ago.
        #expect(!saved.needsSaving(comparedTo: saved, savedAt: t, now: t.addingTimeInterval(3_600)))
    }
}
