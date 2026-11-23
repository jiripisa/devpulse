import DevPulseCore
import SwiftUI

/// A titled list with its source's state (age, or the error) on the right; the header sits on
/// the chrome colour, the rows on the reading surface.
struct SectionView<Rows: View>: View {
    let title: String
    let count: Int
    let status: SourceStatus
    /// False for a section that shares its source with the section above: the state line is
    /// shown once, the empty state still follows the source.
    var showsStatus = true
    let now: Date
    let emptyText: String
    var onSetUp: (() -> Void)?
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Lookout.primary)
                if count > 0 {
                    Text("\(count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Lookout.secondary)
                }
                Spacer(minLength: 8)
                if showsStatus {
                    Text(SourceStatusText.text(for: status, now: now))
                        .font(.system(size: 11))
                        .foregroundStyle(status.state == .error ? Lookout.failure : Lookout.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 30)
            .background(Lookout.chrome)
            .overlay(alignment: .top) { Rectangle().fill(Lookout.divider).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Lookout.divider).frame(height: 1) }

            if count > 0 {
                VStack(spacing: 0) { rows }.padding(.vertical, 2)
            } else {
                placeholder
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch SourceStatusText.placeholder(for: status, empty: emptyText) {
        case .setUp:
            Button("Set up in Settings…") { onSetUp?() }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .padding(.horizontal, 16).padding(.vertical, 10)
        case .text(let text):
            Text(text).font(.system(size: 12)).foregroundStyle(Lookout.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
}

/// A full-width plain button with a hover highlight; `attention` marks a row that waits for
/// the user with an amber bar and wash.
struct RowButton<Label: View>: View {
    var attention = false
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.leading, 8)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(background)
        .overlay(alignment: .leading) {
            if attention { Rectangle().fill(Lookout.attention).frame(width: 3) }
        }
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isHovered { return Lookout.selection }
        return attention ? Lookout.attentionWash : .clear
    }
}

/// The two lines of a row: the name, and under it the kind in its colour with the identifiers.
private struct RowText: View {
    let name: String
    let kind: LauncherItem.Kind
    let identifiers: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 13.5)).foregroundStyle(Lookout.primary).lineLimit(1)
            HStack(spacing: 8) {
                Text(kind.label).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Lookout.color(kind))
                ForEach(identifiers, id: \.self) {
                    Text($0).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Lookout.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct PullRequestRow: View {
    let pr: PullRequest
    let now: Date
    var isReviewRequest = false
    let action: () -> Void

    private var kind: LauncherItem.Kind { isReviewRequest ? .reviewRequest(direct: pr.requestedDirectly) : .pullRequest }

    var body: some View {
        RowButton(action: action) {
            HStack(spacing: 8) {
                KindIcon(kind: kind)
                RowText(name: pr.title, kind: kind, identifiers: identifiers)
                Spacer(minLength: 8)
                BadgeStack(badges: StatusBadge.pullRequest(pr), size: 11.5)
            }
        }
        .help(help)
    }

    private var identifiers: [String] {
        let repoName = pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo
        return ["\(repoName) #\(pr.number)"] + [pr.jiraKey].compactMap { $0 }
    }

    private var help: String {
        var lines = ["\(pr.repo) #\(pr.number) — \(pr.title)"]
        if pr.commentCount > 0 {
            var comments = "\(pr.commentCount) comment\(pr.commentCount == 1 ? "" : "s")"
            if let last = pr.lastCommentAt { comments += ", last \(RelativeAge.text(since: last, now: now))" }
            lines.append(comments)
        }
        if isReviewRequest { lines.append(pr.requestedDirectly ? "Requested from you" : "Requested from your team") }
        return lines.joined(separator: "\n")
    }
}

struct TicketRow: View {
    let ticket: Ticket
    let action: () -> Void

    var body: some View {
        RowButton(action: action) {
            HStack(spacing: 8) {
                KindIcon(kind: .ticket)
                RowText(name: ticket.summary, kind: .ticket, identifiers: [ticket.key])
                Spacer(minLength: 8)
                BadgeStack(badges: [StatusBadge.ticket(status: ticket.status, category: ticket.statusCategory)], size: 11.5)
            }
        }
        .help("\(ticket.key) — \(ticket.summary)")
    }
}

struct SessionRow: View {
    let session: ClaudeSession
    let action: () -> Void

    var body: some View {
        RowButton(attention: session.status == .waiting, action: action) {
            HStack(spacing: 8) {
                KindIcon(kind: .session(session.status))
                RowText(name: session.name, kind: .session(session.status), identifiers: identifiers)
                Spacer(minLength: 8)
                BadgeStack(badges: [StatusBadge.session(session.status)], size: 11.5)
            }
        }
        .help(session.cwd)
    }

    /// Its Jira key, and what it waits for.
    private var identifiers: [String] {
        let waitingFor = session.status == .waiting ? session.waitingFor.map { $0.prefix(1).uppercased() + $0.dropFirst() } : nil
        let parts = [session.jiraKey, waitingFor].compactMap { $0 }
        return parts.isEmpty ? [(session.cwd as NSString).abbreviatingWithTildeInPath] : parts
    }
}
