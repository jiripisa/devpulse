import Testing
@testable import DevPulseCore

@Suite struct StatusBadgeTests {
    @Test func checksReadAsCI() {
        #expect(StatusBadge.ci(.success) == StatusBadge(text: "CI passing", glyph: .check, tone: .success))
        #expect(StatusBadge.ci(.failure) == StatusBadge(text: "CI failing", glyph: .cross, tone: .failure))
        #expect(StatusBadge.ci(.error) == StatusBadge(text: "CI failing", glyph: .cross, tone: .failure))
        #expect(StatusBadge.ci(.pending) == StatusBadge(text: "CI pending", glyph: .clock, tone: .attention))
        #expect(StatusBadge.ci(.none) == nil)
    }

    @Test func reviewsAreSeparateFromCI() {
        #expect(StatusBadge.review(.approved) == StatusBadge(text: "Approved", glyph: .check, tone: .success))
        #expect(StatusBadge.review(.changesRequested) == StatusBadge(text: "Changes requested", glyph: .exclamation, tone: .failure))
        #expect(StatusBadge.review(.reviewRequired) == StatusBadge(text: "Review required", glyph: .diamond, tone: .attention))
        #expect(StatusBadge.review(.none) == nil)
        var pr = makePR()
        pr.checks = .success
        pr.reviewDecision = .reviewRequired
        #expect(StatusBadge.pullRequest(pr).map(\.text) == ["CI passing", "Review required"])
        pr.checks = .none
        pr.reviewDecision = .none
        #expect(StatusBadge.pullRequest(pr).isEmpty)
    }

    @Test func ticketsReadByCategoryAndInReviewStandsOut() {
        #expect(StatusBadge.ticket(status: "To Do", category: .todo) == StatusBadge(text: "To Do", glyph: .openCircle, tone: .secondary))
        #expect(StatusBadge.ticket(status: "In Progress", category: .inProgress)
            == StatusBadge(text: "In Progress", glyph: .halfCircle, tone: .activity))
        #expect(StatusBadge.ticket(status: "In Review", category: .inProgress)
            == StatusBadge(text: "In Review", glyph: .diamond, tone: .review))
        #expect(StatusBadge.ticket(status: "Code review", category: .inProgress).tone == .review)
        #expect(StatusBadge.ticket(status: "Done", category: .done) == StatusBadge(text: "Done", glyph: .checkCircle, tone: .success))
        #expect(StatusBadge.ticket(status: "", category: .todo).text == "To Do")
    }

    @Test func sessionsSayWhatTheyDo() {
        #expect(StatusBadge.session(.busy) == StatusBadge(text: "Working", glyph: .halfCircle, tone: .activity))
        #expect(StatusBadge.session(.waiting) == StatusBadge(text: "Waiting for input", glyph: .diamond, tone: .attention))
        #expect(StatusBadge.session(.idle) == StatusBadge(text: "Idle", glyph: .openCircle, tone: .secondary))
        #expect(StatusBadge.session(.unknown) == StatusBadge(text: "Unknown", glyph: .openCircle, tone: .secondary))
    }

    @Test func lookedUpPullRequestsShowTheirState() {
        #expect(StatusBadge.pullRequest(.open) == StatusBadge(text: "Open", glyph: .openCircle, tone: .activity))
        #expect(StatusBadge.pullRequest(.draft) == StatusBadge(text: "Draft", glyph: .openCircle, tone: .secondary))
        #expect(StatusBadge.pullRequest(.merged) == StatusBadge(text: "Merged", glyph: .checkCircle, tone: .review))
        #expect(StatusBadge.pullRequest(.closed) == StatusBadge(text: "Closed", glyph: .cross, tone: .secondary))
    }

    @Test func kindsHaveShortLabels() {
        #expect(LauncherItem.Kind.ticket.label == "Jira")
        #expect(LauncherItem.Kind.pullRequest.label == "PR")
        #expect(LauncherItem.Kind.reviewRequest(direct: true).label == "Review")
        #expect(LauncherItem.Kind.reviewRequest(direct: false).label == "Team review")
        #expect(LauncherItem.Kind.session(.idle).label == "Claude")
    }
}
