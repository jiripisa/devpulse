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

    static let width: CGFloat = 1040
    /// The results' share of the width; the detail gets the rest.
    private static let listWidth: CGFloat = 436
    private static let placeholder = "Number, gh … or jira …"
    private static let toolbarHeight: CGFloat = 64
    private static let contentHeight: CGFloat = 500
    private static let keyLineHeight: CGFloat = 38
    private static let cornerRadius: CGFloat = 18
    /// How long typing pauses before Jira and GitHub are asked about the results.
    private static let lookupDelay: Duration = .milliseconds(300)
    /// How long the selection rests before the detail asks for what it does not know.
    private static let detailDelay: Duration = .milliseconds(150)

    /// The panel height: the search bar alone, like Spotlight, or the bar over both panes and
    /// the key line. Fixed while results show, so the panel does not resize as they come in.
    static func height(showsContent: Bool) -> CGFloat {
        toolbarHeight + (showsContent ? 1 + contentHeight + 1 + keyLineHeight : 0)
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
            toolbar(detailItems: detailItems)
            if showsContent {
                Rectangle().fill(Lookout.divider).frame(height: 1)
                HStack(spacing: 0) {
                    results.frame(width: Self.listWidth)
                    Rectangle().fill(Lookout.divider).frame(width: 1)
                    detailPane(detail)
                }
                .frame(height: Self.contentHeight)
                Rectangle().fill(Lookout.divider).frame(height: 1)
                keyLine(detailItems: detailItems)
            }
        }
        .frame(width: Self.width, height: Self.height(showsContent: showsContent), alignment: .top)
        .background(Lookout.surface)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(Lookout.divider))
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

    // MARK: Toolbar

    /// The DevPulse mark, the search field and Esc: all there is until something is typed.
    private func toolbar(detailItems: [LauncherItem]) -> some View {
        HStack(spacing: 14) {
            BrandMark()
            Rectangle().fill(Lookout.divider).frame(width: 1, height: 26)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Lookout.secondary)
                field(detailItems: detailItems)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Lookout.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Lookout.divider))
            Keycap(text: "esc")
        }
        .padding(.horizontal, 18)
        .frame(height: Self.toolbarHeight)
        .background(Lookout.chrome)
    }

    private func field(detailItems: [LauncherItem]) -> some View {
        TextField(Self.placeholder, text: $query, prompt: Text(""))
            .textFieldStyle(.plain)
            .font(.system(size: 19))
            .foregroundStyle(Lookout.primary)
            .focused($focused)
            // Its own lighter text: the field's placeholder looked like typed input.
            .overlay(alignment: .leading) {
                if query.isEmpty {
                    Text(Self.placeholder)
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(Lookout.secondary.opacity(0.7))
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

    // MARK: Results

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Results").font(.system(size: 15, weight: .semibold)).foregroundStyle(Lookout.primary)
                if !state.items.isEmpty {
                    Text("\(state.items.count)")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Lookout.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Lookout.chrome, in: Capsule())
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 42)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(state.items.enumerated()), id: \.offset) { index, item in
                            ResultRow(
                                item: item, selected: index == state.selection, focused: state.focus == .list)
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
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .onChange(of: state.selection) { proxy.scrollTo(state.selection) }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if searching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching Jira and GitHub…").font(.system(size: 12)).foregroundStyle(Lookout.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 10)
        } else if state.items.isEmpty {
            Text("No results").font(.system(size: 13)).foregroundStyle(Lookout.secondary)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 10)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detailPane(_ detail: LauncherDetail?) -> some View {
        if let detail {
            let offsets = sectionOffsets(detail)
            let count = detail.items.count
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        detailHeader(detail)
                        ForEach(Array(detail.sections.enumerated()), id: \.offset) { number, section in
                            sectionView(section, offset: offsets[number], count: count)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.detailSelection) { proxy.scrollTo("detail-\(state.detailSelection)") }
            }
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    /// What the selected result is, its name and identifier, its status, and how to open it.
    private func detailHeader(_ detail: LauncherDetail) -> some View {
        let item = detail.item
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                KindIcon(kind: item.kind, size: 16)
                Text(detail.heading).font(.system(size: 14, weight: .semibold)).foregroundStyle(Lookout.primary)
                Spacer(minLength: 12)
                BadgeStack(badges: item.badges, size: 13)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name ?? item.title)
                        .font(.system(size: 22, weight: .semibold)).foregroundStyle(Lookout.primary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    if let subheading = detail.subheading {
                        Text(subheading)
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(Lookout.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Button { onOpen(item.target) } label: {
                    HStack(spacing: 6) {
                        Text(item.openLabel)
                        Image(systemName: "return")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Lookout.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Lookout.divider))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        }
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(Lookout.divider).frame(height: 1) }
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

    /// A titled group of related rows, tied together by a thin tree line on the left.
    private func sectionView(_ section: LauncherDetail.Section, offset: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Lookout.primary)
                .padding(.top, 20).padding(.bottom, 8)
            ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                let flat = offset + index
                DetailRow(
                    item: item, selected: state.focus == .detail && state.detailSelection == flat,
                    isLast: index == section.items.count - 1 && !section.isLoading)
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
                    Text("Loading…").font(.system(size: 12)).foregroundStyle(Lookout.secondary)
                }
                .padding(.leading, 22).padding(.vertical, 8)
            } else if section.items.isEmpty, let empty = section.emptyText {
                Text(empty).font(.system(size: 13)).foregroundStyle(Lookout.secondary)
                    .padding(.leading, 22).padding(.vertical, 6)
            }
        }
    }

    // MARK: Key line

    /// The keys that work now; Enter says where it goes for the focused row.
    private func keyLine(detailItems: [LauncherItem]) -> some View {
        let focusedRow: LauncherItem? = switch state.focus {
        case .list: state.selectedItem
        case .detail: detailItems.indices.contains(state.detailSelection) ? detailItems[state.detailSelection] : nil
        }
        return HStack(spacing: 18) {
            keyHint(["↑", "↓"], "Navigate")
            keyHint(["tab"], "Switch pane")
            if let focusedRow { keyHint(["↵"], focusedRow.openLabel) }
            Spacer()
            keyHint(["esc"], state.focus == .detail ? "Back" : "Close")
        }
        .padding(.horizontal, 18)
        .frame(height: Self.keyLineHeight)
        .background(Lookout.chrome)
    }

    private func keyHint(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) { ForEach(keys, id: \.self) { Keycap(text: $0) } }
            Text(text).font(.system(size: 12)).foregroundStyle(Lookout.secondary)
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

/// A result: the kind's icon, the kind and identifier over the name, and the status on the
/// right. The selected row is filled; while the keyboard is in the results it also has a frame.
private struct ResultRow: View {
    let item: LauncherItem
    let selected: Bool
    let focused: Bool

    private var waits: Bool { item.kind == .session(.waiting) }

    private var background: Color {
        if selected { return Lookout.selection }
        return waits ? Lookout.attentionWash : .clear
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            KindIcon(kind: item.kind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.kind.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Lookout.color(item.kind))
                    if let identifier = item.compactIdentifier {
                        Text(identifier)
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Lookout.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Text(item.name ?? item.title).font(.system(size: 14)).foregroundStyle(Lookout.primary).lineLimit(1)
            }
            Spacer(minLength: 8)
            BadgeStack(badges: item.badges, size: 12)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        // A session waiting for the user stands out, as in the popover.
        .overlay(alignment: .leading) {
            if waits { RoundedRectangle(cornerRadius: 1.5).fill(Lookout.attention).frame(width: 3).padding(.vertical, 8) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected && focused ? Lookout.interaction : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .help(item.title)
    }
}

/// A row of the detail: a tree line on the left, how it relates, its identifier and name, and
/// its status.
private struct DetailRow: View {
    let item: LauncherItem
    let selected: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            TreeLine(isLast: isLast).frame(width: 22)
            HStack(alignment: .center, spacing: 10) {
                KindIcon(kind: item.kind, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    if let caption = item.caption {
                        Text(caption).font(.system(size: 12)).foregroundStyle(Lookout.secondary)
                    }
                    if let identifier = item.identifier {
                        Text(identifier).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Lookout.primary).lineLimit(1).truncationMode(.middle)
                    }
                    Text(item.name ?? item.title).font(.system(size: 13))
                        .foregroundStyle(item.identifier == nil ? Lookout.primary : Lookout.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                BadgeStack(badges: item.badges, size: 12)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Lookout.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Lookout.interaction : .clear, lineWidth: 1.5))
        }
        .contentShape(Rectangle())
        .help(item.title)
    }
}

/// The thin rule that ties a section's rows: down the left, with a tick to each row.
private struct TreeLine: View {
    let isLast: Bool

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let x: CGFloat = 6
                let mid = geometry.size.height / 2
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: isLast ? mid : geometry.size.height))
                path.move(to: CGPoint(x: x, y: mid))
                path.addLine(to: CGPoint(x: geometry.size.width - 2, y: mid))
            }
            .stroke(Lookout.divider, lineWidth: 1.5)
        }
    }
}
