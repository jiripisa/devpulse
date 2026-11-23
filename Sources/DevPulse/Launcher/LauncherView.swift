import DevPulseCore
import SwiftUI

/// The search field and the result list of the quick launcher.
struct LauncherView: View {
    let model: AppModel
    let onOpen: (OpenTarget) -> Void
    let onClose: () -> Void
    let onHeight: (CGFloat) -> Void

    /// Typed in once the field has focus, so the caret follows it as after typing.
    private let initialQuery: String
    /// The demo's row to select once the rows are there, as if moved to.
    private let initialSelection: Int?

    @State private var query = ""
    @State private var selection = 0
    /// The query the rows were last listed for: new rows for the same query (a lookup's
    /// answer) keep the selected row, a new query starts at the top.
    @State private var rowsQuery = ""
    /// The result whose PRs, ticket and related tickets show indented under it.
    @State private var expanded: LauncherItem.Subject?
    /// Whether the user has moved the selection since typing: only then does a resting
    /// selection expand, not the first row that is selected by itself.
    @State private var navigated = false
    /// Where the mouse was at the last hover event: only a moving mouse selects a row, not
    /// rows moving under a still one (an expansion, a lookup's answer, the panel opening).
    @State private var lastMouse: CGPoint?
    @FocusState private var focused: Bool

    init(
        model: AppModel, query: String = "", select: Int? = nil, onOpen: @escaping (OpenTarget) -> Void,
        onClose: @escaping () -> Void, onHeight: @escaping (CGFloat) -> Void
    ) {
        self.model = model
        self.onOpen = onOpen
        self.onClose = onClose
        self.onHeight = onHeight
        initialQuery = query
        initialSelection = select
    }

    private static let placeholder = "Number, gh … or jira …"
    private static let headerHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 46
    private static let maxVisibleRows = 10
    /// How long the selection rests on a result before it expands.
    private static let expandDelay: Duration = .milliseconds(500)

    /// The panel height for a number of result rows.
    static func height(rows: Int) -> CGFloat {
        let visible = min(rows, maxVisibleRows)
        return headerHeight + (visible > 0 ? CGFloat(visible) * rowHeight + 9 : 0)
    }

    private var rows: [LauncherRow] {
        let lookup = model.launcherLookup.results
        let items = LauncherResolver.items(
            for: .parse(query), snapshot: model.snapshot, settings: model.settings, lookup: lookup)
        let children = expanded.map {
            LauncherResolver.children(of: $0, snapshot: model.snapshot, settings: model.settings, lookup: lookup)
        } ?? []
        return LauncherRows.build(items, expanded: expanded, children: children)
    }

    /// What the expanded result still needs from Jira and GitHub; it changes as answers come in
    /// (a PR's ticket key is known only once the PR is).
    private var childRequest: LookupRequest? {
        expanded.map {
            LauncherResolver.childLookupRequest(
                for: $0, snapshot: model.snapshot, settings: model.settings, lookup: model.launcherLookup.results)
        }
    }

    private struct Resting: Equatable {
        var query: String
        var subject: LauncherItem.Subject?
    }

    /// Expands the result the selection rests on, folding the one expanded before in the same
    /// step. Not earlier: folding as soon as the mouse leaves would pull the next result up
    /// under a mouse still moving down, and it would land rows further on.
    private func expand(_ subject: LauncherItem.Subject?) async {
        guard subject != expanded else { return }
        do {
            try await Task.sleep(for: Self.expandDelay)
        } catch {
            return
        }
        expanded = subject
    }

    /// Asks Jira and GitHub for the titles of the "Open …" rows once typing pauses; a new key
    /// cancels the wait.
    private func lookUp() async {
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        let request = LauncherResolver.lookupRequest(for: .parse(query), snapshot: model.snapshot, settings: model.settings)
        guard !request.isEmpty else { return }
        await model.launcherLookup.resolve(request)
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(Self.placeholder, text: $query, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                    // Its own lighter text: the field's placeholder looked like typed input.
                    .overlay(alignment: .leading) {
                        if query.isEmpty {
                            Text(Self.placeholder)
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(.tertiary)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .onKeyPress(.upArrow) { move(-1, in: rows.count) }
                    .onKeyPress(.downArrow) { move(1, in: rows.count) }
                    .onKeyPress(.return, phases: .down) { press in
                        open(rows, secondary: press.modifiers.contains(.command))
                    }
                    .onKeyPress(.escape) {
                        onClose()
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .frame(height: Self.headerHeight)
            if !rows.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                self.row(row, selected: index == selection)
                                    .id(index)
                                    .onTapGesture { onOpen(row.item.target) }
                                    .onContinuousHover { phase in hover(phase, over: index) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
        }
        .frame(width: 640, height: Self.height(rows: rows.count), alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { focused = true }
        // Not before: a field that takes focus with text in it selects all of it.
        .onChange(of: focused) { if focused, query.isEmpty { query = initialQuery } }
        .task(id: query) { await lookUp() }
        .task(id: Resting(query: query, subject: restingSubject(rows))) {
            await expand(restingSubject(rows))
        }
        .task(id: childRequest) {
            if let request = childRequest, !request.isEmpty { await model.launcherLookup.resolve(request) }
        }
        .onChange(of: rows.map(\.id), initial: true) { old, new in
            if rowsQuery == query {
                selection = LauncherSelection.index(keeping: selection, from: old, to: new)
            } else {
                rowsQuery = query
                selection = 0
                expanded = nil
                navigated = false
            }
            if let initialSelection, query == initialQuery, !navigated, new.indices.contains(initialSelection) {
                selection = initialSelection
                navigated = true
            }
            onHeight(Self.height(rows: new.count))
        }
    }

    private func row(_ row: LauncherRow, selected: Bool) -> some View {
        let item = row.item
        let isChild = row.depth > 0
        return HStack(spacing: 10) {
            icon(item.kind).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).font(isChild ? .callout : .body)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        .padding(.leading, isChild ? 40 : 12)
        .padding(.trailing, 12)
        .overlay(alignment: .leading) {
            // A thin line ties the children to their result.
            if isChild { Rectangle().fill(.quaternary).frame(width: 2).padding(.leading, 22) }
        }
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    /// What the row is, so a bare number's mixed results read apart; the popover's icons
    /// where it has one.
    @ViewBuilder
    private func icon(_ kind: LauncherItem.Kind) -> some View {
        switch kind {
        case .pullRequest: Image(systemName: "arrow.triangle.pull").foregroundStyle(.secondary).help("Pull request")
        case .reviewRequest(let direct): ReviewRequestIcon(direct: direct)
        case .ticket: Image(systemName: "ticket").foregroundStyle(.secondary).help("Jira ticket")
        case .session(let status): SessionStatusIcon(status: status).help("Claude Code session")
        }
    }

    private func move(_ delta: Int, in count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        selection = min(max(selection + delta, 0), count - 1)
        navigated = true
        return .handled
    }

    private func hover(_ phase: HoverPhase, over index: Int) {
        guard case .active = phase else { return }
        let mouse = NSEvent.mouseLocation
        if let lastMouse, lastMouse != mouse {
            selection = index
            navigated = true
        }
        lastMouse = mouse
    }

    /// The result the selection rests on, once the user has moved it.
    private func restingSubject(_ rows: [LauncherRow]) -> LauncherItem.Subject? {
        navigated ? LauncherRows.topSubject(at: selection, in: rows) : nil
    }

    private func open(_ rows: [LauncherRow], secondary: Bool) -> KeyPress.Result {
        guard rows.indices.contains(selection) else { return .handled }
        let item = rows[selection].item
        if secondary {
            if let target = item.secondary { onOpen(target) }
        } else {
            onOpen(item.target)
        }
        return .handled
    }
}
