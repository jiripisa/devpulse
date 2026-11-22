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

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    init(
        model: AppModel, query: String = "", onOpen: @escaping (OpenTarget) -> Void,
        onClose: @escaping () -> Void, onHeight: @escaping (CGFloat) -> Void
    ) {
        self.model = model
        self.onOpen = onOpen
        self.onClose = onClose
        self.onHeight = onHeight
        initialQuery = query
    }

    private static let placeholder = "Number, gh … or jira …"
    private static let headerHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 46
    private static let maxVisibleRows = 8

    /// The panel height for a number of result rows.
    static func height(rows: Int) -> CGFloat {
        let visible = min(rows, maxVisibleRows)
        return headerHeight + (visible > 0 ? CGFloat(visible) * rowHeight + 9 : 0)
    }

    private var items: [LauncherItem] {
        LauncherResolver.items(
            for: .parse(query), snapshot: model.snapshot, settings: model.settings, lookup: model.launcherLookup.results)
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
        let items = items
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
                    .onKeyPress(.upArrow) { move(-1, in: items.count) }
                    .onKeyPress(.downArrow) { move(1, in: items.count) }
                    .onKeyPress(.return, phases: .down) { press in
                        open(items, secondary: press.modifiers.contains(.command))
                    }
                    .onKeyPress(.escape) {
                        onClose()
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .frame(height: Self.headerHeight)
            if !items.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                row(item, selected: index == selection)
                                    .id(index)
                                    .onTapGesture { onOpen(item.target) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
        }
        .frame(width: 640, height: Self.height(rows: items.count), alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { focused = true }
        // Not before: a field that takes focus with text in it selects all of it.
        .onChange(of: focused) { if focused, query.isEmpty { query = initialQuery } }
        .onChange(of: query) { selection = 0 }
        .task(id: query) { await lookUp() }
        .onChange(of: items.count, initial: true) {
            // A lookup can drop rows (tickets that do not exist) under the selection.
            selection = min(selection, max(items.count - 1, 0))
            onHeight(Self.height(rows: items.count))
        }
    }

    private func row(_ item: LauncherItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            icon(item.kind).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        .padding(.horizontal, 12)
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
        return .handled
    }

    private func open(_ items: [LauncherItem], secondary: Bool) -> KeyPress.Result {
        guard items.indices.contains(selection) else { return .handled }
        let item = items[selection]
        if secondary {
            if let target = item.secondary { onOpen(target) }
        } else {
            onOpen(item.target)
        }
        return .handled
    }
}
