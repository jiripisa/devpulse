import DevPulseCore
import SwiftUI

/// The search field and the result list of the quick launcher.
struct LauncherView: View {
    let model: AppModel
    let onOpen: (OpenTarget) -> Void
    let onClose: () -> Void
    let onHeight: (CGFloat) -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private static let headerHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 46
    private static let maxVisibleRows = 8

    /// The panel height for a number of result rows.
    static func height(rows: Int) -> CGFloat {
        let visible = min(rows, maxVisibleRows)
        return headerHeight + (visible > 0 ? CGFloat(visible) * rowHeight + 9 : 0)
    }

    private var items: [LauncherItem] {
        LauncherResolver.items(for: .parse(query), snapshot: model.snapshot, settings: model.settings)
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("gh … or jira …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
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
        .onChange(of: query) { selection = 0 }
        .onChange(of: items.count, initial: true) { onHeight(Self.height(rows: items.count)) }
    }

    private func row(_ item: LauncherItem, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).lineLimit(1)
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        .padding(.horizontal, 12)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
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
