import Foundation

/// Which kinds of result the launcher's list shows. Sessions show under All only.
public enum LauncherFilter: CaseIterable, Equatable, Sendable {
    case all
    case pullRequests
    case tickets

    public var title: String {
        switch self {
        case .all: "All"
        case .pullRequests: "PR"
        case .tickets: "Jira"
        }
    }

    /// ⌘1–⌘3 go by the key's place, not by what it types: a Czech layout types + ě š on the top
    /// row's 1 2 3, with ⌘ too. `numberKeyCode` is a macOS virtual key code; the keypad's 1 2 3
    /// count as well.
    public init?(numberKeyCode: UInt16) {
        switch numberKeyCode {
        case 18, 83: self = .all
        case 19, 84: self = .pullRequests
        case 20, 85: self = .tickets
        default: return nil
        }
    }

    public func matches(_ item: LauncherItem) -> Bool {
        switch (self, item.kind) {
        case (.all, _), (.pullRequests, .pullRequest), (.pullRequests, .reviewRequest), (.tickets, .ticket): true
        default: false
        }
    }
}

/// The quick launcher's list and selection: what is shown, what is selected, and whether the
/// keyboard is in the result list or in the detail pane next to it.
///
/// While the query stays, the list only grows at the bottom: rows already shown keep their
/// place (their text may change, a looked-up title say), new ones are appended, so a lookup's
/// answer never moves the row under the selection.
///
/// The filter hides rows without forgetting them: `items` and `selection` are the rows it
/// shows, and they come back in their places when it shows them again.
public struct LauncherState: Equatable, Sendable {
    public enum Focus: Equatable, Sendable {
        case list
        case detail
    }

    public private(set) var query = ""
    public private(set) var filter = LauncherFilter.all
    /// Every row of the query, the filter's hidden ones too.
    private var allItems: [LauncherItem] = []
    public private(set) var selection = 0
    public private(set) var focus = Focus.list
    public private(set) var detailSelection = 0

    public init() {}

    /// The rows the filter shows.
    public var items: [LauncherItem] {
        filter == .all ? allItems : allItems.filter(filter.matches)
    }

    /// How many rows `filter` would show.
    public func count(_ filter: LauncherFilter) -> Int {
        filter == .all ? allItems.count : allItems.count(where: filter.matches)
    }

    public var selectedItem: LauncherItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    /// The resolver's rows for `query`. A new query starts over; the same query keeps the rows
    /// shown in their places, drops those gone and appends the new ones.
    public mutating func setResults(_ fresh: [LauncherItem], for query: String) {
        guard query == self.query else {
            self.query = query
            allItems = fresh
            selection = 0
            focus = .list
            detailSelection = 0
            return
        }
        let selectedID = selectedItem.map(Self.id)
        let freshByID = Dictionary(fresh.map { (Self.id($0), $0) }) { first, _ in first }
        var kept = allItems.compactMap { freshByID[Self.id($0)] }
        let keptIDs = Set(kept.map(Self.id))
        kept += fresh.filter { !keptIDs.contains(Self.id($0)) }
        allItems = kept
        reselect(selectedID, fallback: selection)
    }

    /// The filter chips and ⌘1–⌘3. The selected row stays selected when the filter shows it.
    public mutating func setFilter(_ filter: LauncherFilter) {
        guard filter != self.filter else { return }
        let selectedID = selectedItem.map(Self.id)
        self.filter = filter
        reselect(selectedID, fallback: 0)
    }

    /// Selects the row `selectedID` again, or the row at `fallback` (kept in the list) when it
    /// is gone or hidden.
    private mutating func reselect(_ selectedID: String?, fallback: Int) {
        let shown = items
        if let selectedID, let index = shown.firstIndex(where: { Self.id($0) == selectedID }) {
            selection = index
        } else {
            // Another result is selected now: its detail starts from the list.
            selection = min(fallback, max(shown.count - 1, 0))
            focus = .list
            detailSelection = 0
        }
    }

    /// ↑ / ↓ in the focused pane.
    public mutating func move(_ delta: Int, detailCount: Int) {
        switch focus {
        case .list:
            guard !items.isEmpty else { return }
            let next = min(max(selection + delta, 0), items.count - 1)
            if next != selection {
                selection = next
                detailSelection = 0
            }
        case .detail:
            guard detailCount > 0 else { return }
            detailSelection = min(max(detailSelection + delta, 0), detailCount - 1)
        }
    }

    /// Tab: into the detail when it has rows, and back.
    public mutating func toggleFocus(detailCount: Int) {
        switch focus {
        case .list where detailCount > 0:
            focus = .detail
            detailSelection = 0
        case .list:
            break
        case .detail:
            focus = .list
        }
    }

    /// →: into the detail when it has rows. False lets the search field have the key (the
    /// caret moves), which is the case only in the list with an empty detail.
    public mutating func enterDetail(detailCount: Int) -> Bool {
        if focus == .detail { return true }
        guard detailCount > 0 else { return false }
        focus = .detail
        detailSelection = 0
        return true
    }

    /// ←: back from the detail to the list. False in the list, where the caret moves.
    public mutating func leaveDetail() -> Bool {
        guard focus == .detail else { return false }
        focus = .list
        return true
    }

    /// A result chosen with the mouse.
    public mutating func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        if index != selection { detailSelection = 0 }
        selection = index
        focus = .list
    }

    /// A detail row chosen with the mouse.
    public mutating func selectDetail(_ index: Int, detailCount: Int) {
        guard (0..<detailCount).contains(index) else { return }
        focus = .detail
        detailSelection = index
    }

    /// Esc: back from the detail to the list; true when the launcher should close.
    public mutating func escape() -> Bool {
        guard focus == .detail else { return true }
        focus = .list
        return false
    }

    /// The detail of the selected result changed (an answer came in, or another result).
    public mutating func detailChanged(count: Int) {
        if count == 0 {
            focus = .list
            detailSelection = 0
        } else {
            detailSelection = min(detailSelection, count - 1)
        }
    }

    /// What Enter (or ⌘Enter, `secondary`) opens: the selected row of the focused pane.
    public func target(secondary: Bool, detail: [LauncherItem]) -> OpenTarget? {
        let row: LauncherItem?
        switch focus {
        case .list: row = selectedItem
        case .detail: row = detail.indices.contains(detailSelection) ? detail[detailSelection] : nil
        }
        return secondary ? row?.secondary : row?.target
    }

    /// A row is the same row while it shows the same ticket or PR, whatever its URL; others go
    /// by what they open.
    static func id(_ item: LauncherItem) -> String {
        switch item.subject {
        case .ticket(let key)?: "ticket:\(key)"
        case .pullRequest(let ref)?: "pr:\(ref.repo.lowercased())#\(ref.number)"
        case nil:
            switch item.target {
            case .url(let url): url.absoluteString
            case .session(let pid): "session:\(pid)"
            }
        }
    }
}
