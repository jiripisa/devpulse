import Foundation
import Testing
@testable import DevPulseCore

private func item(_ name: String, subject: LauncherItem.Subject? = nil, title: String? = nil) -> LauncherItem {
    LauncherItem(
        title: title ?? name, subtitle: "", kind: .ticket, target: .url(URL(string: "https://\(name).test")!),
        secondary: .url(URL(string: "https://\(name).test/second")!), subject: subject)
}

@Suite struct LauncherStateTests {
    @Test func aNewQueryReplacesTheListAndStartsAtTheTop() {
        var state = LauncherState()
        state.setResults([item("a"), item("b")], for: "1")
        state.move(1, detailCount: 0)
        state.setResults([item("c")], for: "19")
        #expect(state.items.map(\.title) == ["c"])
        #expect(state.selection == 0)
        #expect(state.focus == .list)
    }

    @Test func newResultsForTheSameQueryOnlyGetAppended() {
        var state = LauncherState()
        state.setResults([item("a"), item("b")], for: "7")
        state.move(1, detailCount: 0)
        // A lookup answer: "c" is new and belongs before "b" in the resolver's order, "a" got a title.
        state.setResults([item("a", title: "A titled"), item("c"), item("b")], for: "7")
        #expect(state.items.map(\.title) == ["A titled", "b", "c"])
        #expect(state.selectedItem?.title == "b")
    }

    @Test func aVanishedResultGoesAndTheSelectionStaysOnItsRow() {
        var state = LauncherState()
        state.setResults([item("a"), item("b"), item("c")], for: "7")
        state.move(2, detailCount: 0)
        state.setResults([item("b"), item("c")], for: "7")
        #expect(state.items.map(\.title) == ["b", "c"])
        #expect(state.selectedItem?.title == "c")
        state.setResults([item("b")], for: "7")
        #expect(state.selection == 0)
    }

    @Test func losingTheSelectedRowLeavesTheDetail() {
        var state = LauncherState()
        state.setResults([item("a"), item("b")], for: "q")
        state.move(1, detailCount: 0)
        state.toggleFocus(detailCount: 2)
        state.move(1, detailCount: 2)
        state.setResults([item("a")], for: "q")
        #expect(state.focus == .list)
        #expect(state.detailSelection == 0)
        #expect(state.selectedItem?.title == "a")
    }

    @Test func aRowIsKnownByItsSubjectWhenItHasOne() {
        // A typed "Open STORE-9" row becomes the ticket's row with a Jira URL of its own.
        var state = LauncherState()
        state.setResults([item("x"), item("open", subject: .ticket("STORE-9"))], for: "jira STORE-9")
        state.move(1, detailCount: 0)
        state.setResults([item("x"), item("found", subject: .ticket("STORE-9"), title: "STORE-9 Fix")], for: "jira STORE-9")
        #expect(state.items.map(\.title) == ["x", "STORE-9 Fix"])
        #expect(state.selection == 1)
    }

    @Test func movingStaysWithinTheList() {
        var state = LauncherState()
        state.setResults([item("a"), item("b")], for: "q")
        state.move(-1, detailCount: 0)
        #expect(state.selection == 0)
        state.move(5, detailCount: 0)
        #expect(state.selection == 1)
    }

    @Test func tabMovesIntoTheDetailOnlyWhenItHasRows() {
        var state = LauncherState()
        state.setResults([item("a"), item("b")], for: "q")
        state.toggleFocus(detailCount: 0)
        #expect(state.focus == .list)
        state.toggleFocus(detailCount: 3)
        #expect(state.focus == .detail)
        #expect(state.detailSelection == 0)
        state.move(1, detailCount: 3)
        state.move(5, detailCount: 3)
        #expect(state.detailSelection == 2)
        #expect(state.selection == 0)
        state.toggleFocus(detailCount: 3)
        #expect(state.focus == .list)
    }

    @Test func rightArrowEntersTheDetailAndLeftArrowLeavesIt() {
        var state = LauncherState()
        state.setResults([item("a")], for: "q")
        // With nothing in the detail, → and ← belong to the text field's caret.
        #expect(state.enterDetail(detailCount: 0) == false)
        #expect(state.leaveDetail() == false)
        #expect(state.enterDetail(detailCount: 2) == true)
        #expect(state.focus == .detail)
        #expect(state.detailSelection == 0)
        state.move(1, detailCount: 2)
        // → again stays in the detail and keeps the row; the caret does not move either.
        #expect(state.enterDetail(detailCount: 2) == true)
        #expect(state.detailSelection == 1)
        #expect(state.leaveDetail() == true)
        #expect(state.focus == .list)
        #expect(state.leaveDetail() == false)
    }

    @Test func selectingAnotherResultLeavesTheDetail() {
        var state = LauncherState()
        state.setResults([item("a"), item("b")], for: "q")
        state.toggleFocus(detailCount: 2)
        state.move(1, detailCount: 2)
        state.select(1)
        #expect(state.focus == .list)
        #expect(state.selection == 1)
        #expect(state.detailSelection == 0)
    }

    @Test func escapeLeavesTheDetailFirst() {
        var state = LauncherState()
        state.setResults([item("a")], for: "q")
        state.toggleFocus(detailCount: 1)
        #expect(state.escape() == false)
        #expect(state.focus == .list)
        #expect(state.escape() == true)
    }

    @Test func aDetailThatShrinksOrEmptiesKeepsTheFocusSensible() {
        var state = LauncherState()
        state.setResults([item("a")], for: "q")
        state.toggleFocus(detailCount: 3)
        state.move(2, detailCount: 3)
        state.detailChanged(count: 1)
        #expect(state.detailSelection == 0)
        state.detailChanged(count: 0)
        #expect(state.focus == .list)
    }

    @Test func enterOpensTheSelectedRowOfTheFocusedPane() {
        var state = LauncherState()
        state.setResults([item("a"), item("b")], for: "q")
        let detail = [item("d1"), item("d2")]
        #expect(state.target(secondary: false, detail: detail) == .url(URL(string: "https://a.test")!))
        #expect(state.target(secondary: true, detail: detail) == .url(URL(string: "https://a.test/second")!))
        state.toggleFocus(detailCount: 2)
        state.move(1, detailCount: 2)
        #expect(state.target(secondary: false, detail: detail) == .url(URL(string: "https://d2.test")!))
        #expect(state.target(secondary: false, detail: []) == nil)
    }

    @Test func anEmptyListHasNothingToOpen() {
        let state = LauncherState()
        #expect(state.selectedItem == nil)
        #expect(state.target(secondary: false, detail: []) == nil)
    }
}

private func row(_ name: String, _ kind: LauncherItem.Kind) -> LauncherItem {
    LauncherItem(
        title: name, subtitle: "", kind: kind, target: .url(URL(string: "https://\(name).test")!),
        secondary: .url(URL(string: "https://\(name).test/second")!))
}

@Suite struct LauncherFilterTests {
    private let mixed = [
        row("pr", .pullRequest), row("ticket", .ticket), row("review", .reviewRequest(direct: true)),
        row("session", .session(.busy)), row("ticket2", .ticket),
    ]

    @Test func eachFilterKeepsItsKinds() {
        #expect(mixed.filter(LauncherFilter.all.matches).count == 5)
        #expect(mixed.filter(LauncherFilter.pullRequests.matches).map(\.title) == ["pr", "review"])
        #expect(mixed.filter(LauncherFilter.tickets.matches).map(\.title) == ["ticket", "ticket2"])
    }

    @Test func theListShowsOnlyTheFilteredRowsAndCountsEveryFilter() {
        var state = LauncherState()
        state.setResults(mixed, for: "7")
        state.setFilter(.tickets)
        #expect(state.items.map(\.title) == ["ticket", "ticket2"])
        #expect(state.count(.all) == 5)
        #expect(state.count(.pullRequests) == 2)
        #expect(state.count(.tickets) == 2)
    }

    @Test func theSelectedRowStaysSelectedWhenTheFilterKeepsIt() {
        var state = LauncherState()
        state.setResults(mixed, for: "7")
        state.move(4, detailCount: 0)
        state.setFilter(.tickets)
        #expect(state.selectedItem?.title == "ticket2")
        state.setFilter(.all)
        #expect(state.selectedItem?.title == "ticket2")
        #expect(state.items.map(\.title) == mixed.map(\.title))
    }

    @Test func aFilterThatHidesTheSelectedRowStartsAtTheTopOfTheList() {
        var state = LauncherState()
        state.setResults(mixed, for: "7")
        state.toggleFocus(detailCount: 2)
        state.move(1, detailCount: 2)
        state.setFilter(.pullRequests)
        #expect(state.selectedItem?.title == "pr")
        state.setFilter(.tickets)
        #expect(state.selection == 0)
        #expect(state.selectedItem?.title == "ticket")
        #expect(state.focus == .list)
        #expect(state.detailSelection == 0)
    }

    @Test func aFilterThatHidesTheSelectedRowJumpsToTheTopFromLowerDown() {
        var state = LauncherState()
        state.setResults(mixed, for: "7")
        state.move(2, detailCount: 0)
        #expect(state.selectedItem?.title == "review")
        state.setFilter(.tickets)
        #expect(state.selection == 0)
        #expect(state.selectedItem?.title == "ticket")
    }

    @Test func theFilterKeepsTheDetailWhenItKeepsTheSelectedRow() {
        var state = LauncherState()
        state.setResults(mixed, for: "7")
        state.move(1, detailCount: 0)
        state.toggleFocus(detailCount: 3)
        state.move(2, detailCount: 3)
        state.setFilter(.tickets)
        #expect(state.selectedItem?.title == "ticket")
        #expect(state.focus == .detail)
        #expect(state.detailSelection == 2)
    }

    @Test func newResultsDroppingTheSelectedRowUnderAFilterStayWithinTheShownRows() {
        var state = LauncherState()
        state.setResults([row("t1", .ticket), row("p1", .pullRequest), row("t2", .ticket)], for: "7")
        state.setFilter(.tickets)
        state.move(1, detailCount: 0)
        state.toggleFocus(detailCount: 1)
        state.setResults([row("t1", .ticket), row("p1", .pullRequest)], for: "7")
        #expect(state.items.map(\.title) == ["t1"])
        #expect(state.selectedItem?.title == "t1")
        #expect(state.focus == .list)
        #expect(state.detailSelection == 0)
    }

    @Test func theFilterOutlivesANewQuery() {
        var state = LauncherState()
        state.setResults(mixed, for: "7")
        state.setFilter(.pullRequests)
        state.setResults([row("t", .ticket), row("p", .pullRequest)], for: "70")
        #expect(state.filter == .pullRequests)
        #expect(state.items.map(\.title) == ["p"])
        #expect(state.selection == 0)
    }

    @Test func rowsArrivingUnderAFilterKeepTheSelectionAndTheResolversOrder() {
        var state = LauncherState()
        state.setResults([row("t1", .ticket), row("p1", .pullRequest)], for: "7")
        state.setFilter(.tickets)
        state.setResults([row("t1", .ticket), row("p1", .pullRequest), row("t2", .ticket)], for: "7")
        state.move(1, detailCount: 0)
        #expect(state.selectedItem?.title == "t2")
        // A PR arriving under the ticket filter neither shows nor moves the selection.
        state.setResults(
            [row("t1", .ticket), row("p1", .pullRequest), row("t2", .ticket), row("p2", .pullRequest)], for: "7")
        #expect(state.items.map(\.title) == ["t1", "t2"])
        #expect(state.selectedItem?.title == "t2")
        state.setFilter(.all)
        #expect(state.items.map(\.title) == ["t1", "p1", "t2", "p2"])
        #expect(state.selectedItem?.title == "t2")
    }

    @Test func aFilterWithNoRowsHasNothingSelected() {
        var state = LauncherState()
        state.setResults([row("t1", .ticket)], for: "7")
        state.setFilter(.pullRequests)
        #expect(state.items.isEmpty)
        #expect(state.selectedItem == nil)
        #expect(state.target(secondary: false, detail: []) == nil)
        state.move(1, detailCount: 0)
        #expect(state.selection == 0)
    }
}

@Suite struct LauncherFilterKeyTests {
    @Test func theNumberKeysPickTheFilterByPositionWhateverTheLayoutTypes() {
        // The keys 1, 2 and 3 of the top row, which a Czech layout types as + ě š.
        #expect(LauncherFilter(numberKeyCode: 18) == .all)
        #expect(LauncherFilter(numberKeyCode: 19) == .pullRequests)
        #expect(LauncherFilter(numberKeyCode: 20) == .tickets)
        // The keypad's 1, 2 and 3.
        #expect(LauncherFilter(numberKeyCode: 83) == .all)
        #expect(LauncherFilter(numberKeyCode: 84) == .pullRequests)
        #expect(LauncherFilter(numberKeyCode: 85) == .tickets)
        #expect(LauncherFilter(numberKeyCode: 21) == nil)
        #expect(LauncherFilter(numberKeyCode: 0) == nil)
    }
}
