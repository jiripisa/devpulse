import Foundation

/// The quick launcher's list and selection: what is shown, what is selected, and whether the
/// keyboard is in the result list or in the detail pane next to it.
///
/// While the query stays, the list only grows at the bottom: rows already shown keep their
/// place (their text may change, a looked-up title say), new ones are appended, so a lookup's
/// answer never moves the row under the selection.
public struct LauncherState: Equatable, Sendable {
    public enum Focus: Equatable, Sendable {
        case list
        case detail
    }

    public private(set) var query = ""
    public private(set) var items: [LauncherItem] = []
    public private(set) var selection = 0
    public private(set) var focus = Focus.list
    public private(set) var detailSelection = 0

    public init() {}

    public var selectedItem: LauncherItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    /// The resolver's rows for `query`. A new query starts over; the same query keeps the rows
    /// shown in their places, drops those gone and appends the new ones.
    public mutating func setResults(_ fresh: [LauncherItem], for query: String) {
        guard query == self.query else {
            self.query = query
            items = fresh
            selection = 0
            focus = .list
            detailSelection = 0
            return
        }
        let selectedID = selectedItem.map(Self.id)
        let freshByID = Dictionary(fresh.map { (Self.id($0), $0) }) { first, _ in first }
        var kept = items.compactMap { freshByID[Self.id($0)] }
        let keptIDs = Set(kept.map(Self.id))
        kept += fresh.filter { !keptIDs.contains(Self.id($0)) }
        let oldSelection = selection
        items = kept
        if let selectedID, let index = items.firstIndex(where: { Self.id($0) == selectedID }) {
            selection = index
        } else {
            // Another result is selected now: its detail starts from the list.
            selection = min(oldSelection, max(items.count - 1, 0))
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
