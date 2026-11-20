import DevPulseCore
import SwiftUI

/// A titled list with its source's state (age, or the error) on the right.
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                if count > 0 {
                    Text("\(count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if showsStatus {
                    Text(SourceStatusText.text(for: status, now: now))
                        .font(.caption)
                        .foregroundStyle(status.state == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, 6)

            if count > 0 {
                rows
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
                .font(.caption)
                .padding(.horizontal, 6)
        case .text(let text):
            emptyLine(text)
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 6)
    }
}

/// A full-width plain button with a hover highlight.
struct RowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 5))
        .onHover { isHovered = $0 }
    }
}

struct PullRequestRow: View {
    let pr: PullRequest
    let now: Date
    var isReviewRequest = false
    let action: () -> Void

    var body: some View {
        RowButton(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                leadingIcon.frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title).lineLimit(1)
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .help("\(pr.repo) #\(pr.number) — \(pr.title)")
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if isReviewRequest {
            ReviewRequestIcon(direct: pr.requestedDirectly)
        } else {
            switch pr.checks {
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure, .error: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .pending: Image(systemName: "clock").foregroundStyle(.yellow)
            case .none: Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
    }

    private var details: String {
        let repoName = pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo
        var parts = ["\(repoName) #\(pr.number)"]
        if let key = pr.jiraKey { parts.append(key) }
        switch pr.reviewDecision {
        case .approved: parts.append("approved")
        case .changesRequested: parts.append("changes requested")
        case .reviewRequired, .none: break
        }
        if pr.commentCount > 0 {
            var comments = "\(pr.commentCount) comment\(pr.commentCount == 1 ? "" : "s")"
            if let last = pr.lastCommentAt { comments += ", last \(RelativeAge.text(since: last, now: now))" }
            parts.append(comments)
        }
        return parts.joined(separator: " · ")
    }
}

struct TicketRow: View {
    let ticket: Ticket
    let action: () -> Void

    var body: some View {
        RowButton(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ticket.key).font(.caption.monospaced().weight(.medium))
                Text(ticket.summary).lineLimit(1)
                Spacer(minLength: 4)
                Text(ticket.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help("\(ticket.key) — \(ticket.summary)")
    }
}

struct SessionRow: View {
    let session: ClaudeSession
    let action: () -> Void

    var body: some View {
        RowButton(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SessionStatusIcon(status: session.status).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.name).lineLimit(1)
                        if let key = session.jiraKey {
                            Text(key).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .help(session.cwd)
    }

    private var details: String {
        let cwd = (session.cwd as NSString).abbreviatingWithTildeInPath
        return "\(session.stateText) · \(cwd)"
    }
}

/// One person: requested from me; two people: from one of my teams. The launcher uses it too.
struct ReviewRequestIcon: View {
    let direct: Bool

    var body: some View {
        Image(systemName: direct ? "person.fill" : "person.2")
            .foregroundStyle(direct ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .help(direct ? "Requested from you" : "Requested from your team")
    }
}

/// A Claude Code session's state; the launcher uses it too.
struct SessionStatusIcon: View {
    let status: SessionStatus

    var body: some View {
        switch status {
        case .waiting: Image(systemName: "circle.fill").foregroundStyle(.orange)
        case .busy: Image(systemName: "circle.lefthalf.filled").foregroundStyle(.blue)
        case .idle: Image(systemName: "circle").foregroundStyle(.secondary)
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.tertiary)
        }
    }
}
