import AppKit
import DevPulseCore
import SwiftUI

/// The menu bar window: the four sections of spec §5.4, each source's state, and the actions.
struct PopoverView: View {
    let model: AppModel
    /// The lists scroll above this height. The demo window lifts it so a screenshot shows them all.
    var maxListHeight: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // One shared clock for every relative time; it ticks only while the window is shown.
            TimelineView(.everyMinute) { context in
                ScrollView {
                    sections(now: context.date)
                }
                .frame(maxHeight: maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Lookout.divider).frame(height: 1)
            footer
        }
        .frame(width: 520)
        .background(Lookout.surface)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 18)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button(action: model.refreshAll) {
                Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Lookout.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    @ViewBuilder
    private func sections(now: Date) -> some View {
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: 0) {
            SectionView(
                title: "My pull requests", count: snapshot.myPullRequests.count,
                status: snapshot.sources.github, now: now, emptyText: "No open pull requests"
            ) {
                ForEach(snapshot.myPullRequests, id: \.id) { pr in
                    PullRequestRow(pr: pr, now: now) { open(pr.url) }
                }
            }
            SectionView(
                title: "Review requests", count: snapshot.reviewRequests.count,
                status: snapshot.sources.github, showsStatus: false, now: now,
                emptyText: "No review requests"
            ) {
                ForEach(snapshot.reviewRequests, id: \.id) { pr in
                    PullRequestRow(pr: pr, now: now, isReviewRequest: true) { open(pr.url) }
                }
            }
            SectionView(
                title: "Jira", count: snapshot.tickets.count,
                status: snapshot.sources.jira, now: now, emptyText: "No open tickets",
                onSetUp: { model.openSettings(.jira) }
            ) {
                ForEach(snapshot.tickets, id: \.key) { ticket in
                    TicketRow(ticket: ticket) { open(ticket.url) }
                }
            }
            SectionView(
                title: "Claude Code", count: snapshot.sessions.count,
                status: snapshot.sources.claude, now: now, emptyText: "No running sessions"
            ) {
                ForEach(snapshot.sessions, id: \.pid) { session in
                    SessionRow(session: session) { model.open(.session(pid: session.pid)) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: model.openSettings)
            Spacer()
            Button("Quit DevPulse") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(Lookout.primary)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Lookout.chrome)
    }

    private func open(_ url: String) {
        guard let url = URL(string: url) else { return }
        model.open(.url(url))
    }
}
