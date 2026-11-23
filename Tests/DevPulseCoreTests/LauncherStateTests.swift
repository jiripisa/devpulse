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
