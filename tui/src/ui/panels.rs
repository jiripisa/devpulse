//! The four numbered list panels of the left column.

use super::list_offset;
use super::text::{fit, pad, styled, width};
use crate::protocol::{PullRequest, SourceState, SourceStatus};
use crate::state::{AppState, Panel};
use crate::theme;
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Paragraph};

const REPO_MAX: usize = 14;
const STATUS_MAX: usize = 14;
const SESSION_NAME_MAX: usize = 18;

pub fn title(panel: Panel) -> &'static str {
    match panel {
        Panel::MyPrs => "My pull requests",
        Panel::Reviews => "Review requests",
        Panel::Jira => "Jira",
        Panel::Claude => "Claude Code",
    }
}

pub fn render(frame: &mut Frame, area: Rect, state: &AppState, panel: Panel) {
    let focused = state.focus == panel;
    let border = theme::border(focused);
    let rows = rows(state, panel);
    let total = total(state, panel);
    let count = if state.filter.as_deref().is_some_and(|f| !f.is_empty()) {
        format!(" {}/{total} ", rows.len())
    } else {
        format!(" {total} ")
    };
    let number_style = if focused { theme::accent_bold() } else { theme::accent() };
    let title_style = if focused { theme::bold() } else { Default::default() };
    let block = Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(border)
        .title_top(Line::from(vec![
            styled("─", border),
            styled(format!("[{}]", panel.index() + 1), number_style),
            styled(format!(" {} ", title(panel)), title_style),
        ]))
        .title_top(
            Line::from(vec![styled(count, theme::dim()), styled("─", border)]).right_aligned(),
        );
    let inner = block.inner(area);
    let max = usize::from(inner.width);
    let lines: Vec<Line> = if rows.is_empty() {
        let style = theme::dim().add_modifier(Modifier::ITALIC);
        vec![fit(vec![Span::raw(" "), styled(placeholder(state, panel), style)], max)]
    } else {
        let selected = state.selected[panel.index()];
        let offset = list_offset(selected, rows.len(), usize::from(inner.height));
        rows.into_iter()
            .enumerate()
            .skip(offset)
            .take(usize::from(inner.height))
            .map(|(i, spans)| {
                let marker = match (i == selected, focused) {
                    (true, true) => styled("▶", theme::accent_bold()),
                    (true, false) => Span::raw("▶"),
                    (false, _) => Span::raw(" "),
                };
                let mut all = vec![Span::raw(" "), marker, Span::raw(" ")];
                all.extend(spans);
                let line = fit(all, max);
                if focused && i == selected { highlight(line, max) } else { line }
            })
            .collect()
    };
    frame.render_widget(Paragraph::new(lines).block(block), area);
}

/// The focused panel's selected row: every span on the selection background, padded to the
/// full width like lazygit's selected line.
fn highlight(line: Line<'static>, max: usize) -> Line<'static> {
    let used: usize = line.spans.iter().map(|s| width(&s.content)).sum();
    let mut spans: Vec<Span<'static>> = line
        .spans
        .into_iter()
        .map(|s| {
            let style = theme::selected(s.style);
            s.style(style)
        })
        .collect();
    spans.push(styled(" ".repeat(max.saturating_sub(used)), theme::selected(Default::default())));
    Line::from(spans)
}

fn total(state: &AppState, panel: Panel) -> usize {
    state.snapshot.as_ref().map_or(0, |s| match panel {
        Panel::MyPrs => s.my_pull_requests.len(),
        Panel::Reviews => s.review_requests.len(),
        Panel::Jira => s.tickets.len(),
        Panel::Claude => s.sessions.len(),
    })
}

/// The row text of every visible item, without the selection marker.
fn rows(state: &AppState, panel: Panel) -> Vec<Vec<Span<'static>>> {
    match panel {
        Panel::MyPrs | Panel::Reviews => pr_rows(&state.visible_prs(panel), panel == Panel::Reviews),
        Panel::Jira => {
            let tickets = state.visible_tickets();
            let kw = tickets.iter().map(|t| width(&t.key)).max().unwrap_or(0);
            let sw = tickets.iter().map(|t| width(&t.status)).max().unwrap_or(0).min(STATUS_MAX);
            tickets
                .iter()
                .map(|t| {
                    vec![
                        Span::raw(pad(&t.key, kw)),
                        Span::raw("  "),
                        styled(pad(&t.status, sw), theme::ticket_status(t.status_category)),
                        Span::raw("  "),
                        Span::raw(t.summary.clone()),
                    ]
                })
                .collect()
        }
        Panel::Claude => {
            let sessions = state.visible_sessions();
            let nw = sessions.iter().map(|c| width(&c.name)).max().unwrap_or(0).min(SESSION_NAME_MAX);
            let lw = sessions.iter().map(|c| width(theme::session(c.status).1)).max().unwrap_or(0);
            sessions
                .iter()
                .map(|c| {
                    let (icon, label, style) = theme::session(c.status);
                    let mut spans = vec![
                        styled(icon, style),
                        Span::raw(" "),
                        Span::raw(pad(&c.name, nw)),
                        Span::raw("  "),
                        styled(pad(label, lw), style),
                    ];
                    if let Some(key) = &c.jira_key {
                        spans.push(styled("  → ", theme::dim()));
                        spans.push(Span::raw(key.clone()));
                    }
                    spans
                })
                .collect()
        }
    }
}

/// `requests` marks review requests like the popover: `●` from me directly, a dim `○` from one
/// of my teams.
fn pr_rows(prs: &[&PullRequest], requests: bool) -> Vec<Vec<Span<'static>>> {
    let repo = |p: &PullRequest| p.repo.rsplit('/').next().unwrap_or(&p.repo).to_string();
    let rw = prs.iter().map(|p| width(&repo(p))).max().unwrap_or(0).min(REPO_MAX);
    let nw = prs.iter().map(|p| p.number.to_string().len() + 1).max().unwrap_or(0);
    prs.iter()
        .map(|p| {
            let (icon, _, style) = theme::check(p.checks);
            let mut spans = Vec::new();
            if requests {
                spans.push(if p.requested_directly {
                    styled("●", theme::warn())
                } else {
                    styled("○", theme::dim())
                });
                spans.push(Span::raw(" "));
            }
            spans.extend([
                styled(pad(&repo(p), rw), theme::dim()),
                Span::raw("  "),
                styled(pad(&format!("#{}", p.number), nw), theme::accent()),
                Span::raw("  "),
                styled(icon, style),
                Span::raw(" "),
                Span::raw(short_title(p)),
            ]);
            spans
        })
        .collect()
}

/// The title without a leading Jira key (`STORE-2474 Replace…` → `Replace…`): the key is in the
/// detail pane and the column is narrow.
pub fn short_title(pr: &PullRequest) -> String {
    let Some(key) = &pr.jira_key else { return pr.title.clone() };
    match pr.title.strip_prefix(key.as_str()) {
        Some(rest) => {
            let rest = rest.trim_start_matches([' ', ':', '-', '–', '—', '|', ']']);
            if rest.is_empty() { pr.title.clone() } else { rest.to_string() }
        }
        None => pr.title.clone(),
    }
}

fn placeholder(state: &AppState, panel: Panel) -> String {
    let Some(s) = &state.snapshot else { return "loading…".into() };
    if let Some(f) = state.filter.as_deref().filter(|f| !f.is_empty()) {
        return format!("no match for “{f}”");
    }
    let (source, name): (&SourceStatus, &str) = match panel {
        Panel::MyPrs | Panel::Reviews => (&s.sources.github, "GitHub"),
        Panel::Jira => (&s.sources.jira, "Jira"),
        Panel::Claude => (&s.sources.claude, "Claude Code"),
    };
    match source.state {
        SourceState::Unconfigured => format!("{name} is not set up — press , for Settings"),
        SourceState::Disabled => format!("{name} is turned off in Settings"),
        SourceState::Error => format!("{name} unavailable — see the header"),
        SourceState::Fetching if source.last_success.is_none() => "loading…".into(),
        _ => match panel {
            Panel::MyPrs => "No open pull requests".into(),
            Panel::Reviews => "No review requests".into(),
            Panel::Jira => "No tickets".into(),
            Panel::Claude => "No sessions".into(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_title_drops_a_leading_jira_key() {
        let fixture: crate::protocol::Snapshot =
            serde_json::from_str(include_str!("../../../protocol/fixtures/snapshot-v1.json")).unwrap();
        let mut pr = fixture.my_pull_requests[0].clone();
        assert_eq!(short_title(&pr), "Replace invoice order");
        pr.title = "STORE-2474: Fix".into();
        assert_eq!(short_title(&pr), "Fix");
        pr.title = "STORE-2474".into();
        assert_eq!(short_title(&pr), "STORE-2474");
        pr.jira_key = None;
        assert_eq!(short_title(&pr), "STORE-2474");
    }
}
