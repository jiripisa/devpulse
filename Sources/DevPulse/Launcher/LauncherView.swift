import AppKit
import DevPulseCore
import SwiftUI

/// The quick launcher: the search field, the results on the left, and on the right the detail
/// of the selected result (a ticket's pull requests and related tickets, a PR's ticket).
///
/// The list never moves under the selection: while the query stays, results only get appended
/// (`LauncherState`), guesses show only once Jira or GitHub confirms them, and the detail lives
/// in its own pane.
struct LauncherView: View {
    let model: AppModel
    let onOpen: (OpenTarget) -> Void
    let onClose: () -> Void
    let onHeight: (CGFloat) -> Void

    /// Typed in once the field has focus, so the caret follows it as after typing.
    private let initialQuery: String
    /// The demo's row to select once the results are there.
    private let initialSelection: Int?

    @State private var query = ""
    @State private var state = LauncherState()
    /// Jira or GitHub is being asked about the query's results.
    @State private var searching = false
    @State private var appliedInitialSelection = false
    /// Not observed: hovering must not redraw the launcher on every mouse move.
    @State private var mouse = MouseTracker()
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

    static let width: CGFloat = 860
    private static let listWidth: CGFloat = 380
    private static let placeholder = "Number, gh … or jira …"
    private static let headerHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 46
    private static let visibleRows = 8
    /// How long typing pauses before Jira and GitHub are asked about the results.
    private static let lookupDelay: Duration = .milliseconds(300)
    /// How long the selection rests before the detail asks for what it does not know.
    private static let detailDelay: Duration = .milliseconds(150)

    /// The panel height: the field alone, or the field over both panes. Fixed while results
    /// show, so the panel does not resize as they come in.
    static func height(showsContent: Bool) -> CGFloat {
        headerHeight + (showsContent ? 1 + CGFloat(visibleRows) * rowHeight + 8 : 0)
    }

    private var parsed: LauncherQuery { .parse(query) }

    private var freshItems: [LauncherItem] {
        LauncherResolver.items(
            for: parsed, snapshot: model.snapshot, settings: model.settings, lookup: model.launcherLookup.results)
    }

    private var detail: LauncherDetail? {
        state.selectedItem.map {
            LauncherResolver.detail(
                for: $0, snapshot: model.snapshot, settings: model.settings, lookup: model.launcherLookup.results)
        }
    }

    private var detailRequest: LookupRequest? {
        state.selectedItem.map {
            LauncherResolver.detailLookupRequest(
                for: $0, snapshot: model.snapshot, settings: model.settings, lookup: model.launcherLookup.results)
        }
    }

    private var showsContent: Bool { parsed != .empty }

    private struct Results: Equatable {
        var query: String
        var items: [LauncherItem]
    }

    var body: some View {
        let detail = detail
        let detailItems = detail?.items ?? []
        VStack(spacing: 0) {
            field(detailItems: detailItems)
            if showsContent {
                Divider()
                HStack(spacing: 0) {
                    list.frame(width: Self.listWidth)
                    Divider()
                    detailPane(detail)
                }
            }
        }
        .frame(width: Self.width, height: Self.height(showsContent: showsContent), alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { focused = true }
        // Not before: a field that takes focus with text in it selects all of it.
        .onChange(of: focused) { if focused, query.isEmpty { query = initialQuery } }
        .onChange(of: Results(query: query, items: freshItems), initial: true) { _, results in
            state.setResults(results.items, for: results.query)
            if let initialSelection, !appliedInitialSelection, query == initialQuery,
               state.items.indices.contains(initialSelection) {
                state.select(initialSelection)
                appliedInitialSelection = true
            }
        }
        .onChange(of: detailItems.count) { state.detailChanged(count: detailItems.count) }
        .onChange(of: showsContent, initial: true) { onHeight(Self.height(showsContent: showsContent)) }
        .task(id: query) { await lookUp() }
        .task(id: detailRequest) { await lookUpDetail() }
    }

    // MARK: Field

    private func field(detailItems: [LauncherItem]) -> some View {
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
                .onKeyPress(.upArrow) {
                    state.move(-1, detailCount: detailItems.count)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    state.move(1, detailCount: detailItems.count)
                    return .handled
                }
                // → and ← like Tab and Shift-Tab; otherwise they move the caret.
                .onKeyPress(.rightArrow) {
                    state.enterDetail(detailCount: detailItems.count) ? .handled : .ignored
                }
                .onKeyPress(.leftArrow) { state.leaveDetail() ? .handled : .ignored }
                // Tab into the detail and back; Shift-Tab arrives as a back tab.
                .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { press in
                    let back = press.key == KeyEquivalent("\u{19}") || press.modifiers.contains(.shift)
                    if back {
                        if state.focus == .detail { state.toggleFocus(detailCount: detailItems.count) }
                    } else {
                        state.toggleFocus(detailCount: detailItems.count)
                    }
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if let target = state.target(secondary: press.modifiers.contains(.command), detail: detailItems) {
                        onOpen(target)
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    if state.escape() { onClose() }
                    return .handled
                }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.headerHeight)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.items.enumerated()), id: \.offset) { index, item in
                        row(item, selected: index == state.selection, active: state.focus == .list)
                            .id(index)
                            .onTapGesture { onOpen(item.target) }
                            .onContinuousHover { phase in
                                if case .active = phase, mouse.moved(),
                                   index != state.selection || state.focus != .list {
                                    state.select(index)
                                }
                            }
                    }
                    footer
                }
                .padding(.vertical, 4)
            }
            .onChange(of: state.selection) { proxy.scrollTo(state.selection) }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if searching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching Jira and GitHub…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .padding(.horizontal, 18)
        } else if state.items.isEmpty {
            Text("No results").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, 18)
        }
    }

    private func row(_ item: LauncherItem, selected: Bool, active: Bool) -> some View {
        HStack(spacing: 10) {
            icon(item.kind).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        .padding(.horizontal, 12)
        .background(
            selected ? Color.accentColor.opacity(active ? 0.25 : 0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .help(item.title)
    }

    // MARK: Detail

    @ViewBuilder
    private func detailPane(_ detail: LauncherDetail?) -> some View {
        if let detail {
            let offsets = sectionOffsets(detail)
            let count = detail.items.count
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detail.title).font(.title3.weight(.semibold)).lineLimit(3)
                        Text(detail.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        ForEach(Array(detail.sections.enumerated()), id: \.offset) { number, section in
                            sectionView(section, offset: offsets[number], count: count)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.detailSelection) { proxy.scrollTo("detail-\(state.detailSelection)") }
            }
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    private func sectionOffsets(_ detail: LauncherDetail) -> [Int] {
        var offsets: [Int] = []
        var total = 0
        for section in detail.sections {
            offsets.append(total)
            total += section.items.count
        }
        return offsets
    }

    private func sectionView(_ section: LauncherDetail.Section, offset: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 14).padding(.bottom, 4)
            ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                let flat = offset + index
                row(item, selected: state.focus == .detail && state.detailSelection == flat, active: true)
                    .padding(.horizontal, -6)
                    .id("detail-\(flat)")
                    .onTapGesture { onOpen(item.target) }
                    .onContinuousHover { phase in
                        if case .active = phase, mouse.moved(),
                           state.focus != .detail || state.detailSelection != flat {
                            state.selectDetail(flat, detailCount: count)
                        }
                    }
            }
            if section.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else if section.items.isEmpty, let empty = section.emptyText {
                Text(empty).font(.callout).foregroundStyle(.tertiary).padding(.vertical, 6)
            }
        }
    }

    // MARK: Icons

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

    // MARK: Lookups

    /// Asks Jira and GitHub about the query's guesses and typed rows once typing pauses; a new
    /// key cancels the wait. `searching` shows from the first key until the answer.
    private func lookUp() async {
        let request = LauncherResolver.lookupRequest(for: parsed, snapshot: model.snapshot, settings: model.settings)
        searching = !request.isEmpty
        guard !request.isEmpty else { return }
        do {
            try await Task.sleep(for: Self.lookupDelay)
        } catch {
            return
        }
        await resolveUncancelled(request)
        // A newer query's task owns the flag by now.
        if !Task.isCancelled { searching = false }
    }

    /// Asks for what the selected result's detail does not know, once the selection rests.
    private func lookUpDetail() async {
        guard let request = detailRequest, !request.isEmpty else { return }
        do {
            try await Task.sleep(for: Self.detailDelay)
        } catch {
            return
        }
        await resolveUncancelled(request)
    }

    /// A lookup once sent runs to its end even when the selection or the query moves on: its
    /// answer is cached for the next time, and a cut-off request would only be asked again.
    private func resolveUncancelled(_ request: LookupRequest) async {
        let lookup = model.launcherLookup
        await Task { await lookup.resolve(request) }.value
    }
}

/// Where the mouse was at the last hover event. A class, so remembering it redraws nothing;
/// only a mouse that really moved selects a row, not rows changing under a still one.
private final class MouseTracker {
    private var last: CGPoint?

    func moved() -> Bool {
        let now = NSEvent.mouseLocation
        defer { last = now }
        guard let last else { return false }
        return last != now
    }
}
