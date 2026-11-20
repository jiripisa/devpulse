//! The right-hand pane: everything about the item selected in the focused panel.

use super::panels::title as panel_title;
use super::text::{ELLIPSIS, fit, styled, truncate_left, wrap};
use crate::protocol::{AuthorKind, ClaudeSession, Comment, PullRequest, Snapshot, Ticket};
use crate::state::{AppState, Panel};
use crate::theme;
use crate::time::{age, parse_iso8601};
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Padding, Paragraph};
use std::time::SystemTime;

const LABEL_WIDTH: usize = 10;
const RECENT_COMMENTS: usize = 3;

pub fn render(frame: &mut Frame, area: Rect, state: &AppState, now: SystemTime) {
    let block = Block::bordered()
        .border_type(BorderType::Rounded)
        .title_top(Line::from(vec![Span::raw("─"), styled(" Detail ", theme::bold())]))
        .padding(Padding::horizontal(1));
    let inner = block.inner(area);
    let d = Detail { max: usize::from(inner.width), now };
    let mut lines = match &state.snapshot {
        None => d.wrapped("Waiting for data from DevPulse…", theme::dim()),
        Some(s) => d.lines(state, s).unwrap_or_else(|| {
            let what = panel_title(state.focus);
            d.wrapped(&format!("Nothing selected in {what}."), theme::dim())
        }),
    };
    // Every line is one row (titles are wrapped above), so a cut is visible as a `…` row.
    let rows = usize::from(inner.height);
    if lines.len() > rows && rows > 0 {
        lines.truncate(rows - 1);
        lines.push(Line::styled(ELLIPSIS, theme::dim()));
    }
    frame.render_widget(Paragraph::new(lines).block(block), area);
}

struct Detail {
    max: usize,
    now: SystemTime,
}

impl Detail {
    fn lines(&self, state: &AppState, s: &Snapshot) -> Option<Vec<Line<'static>>> {
        let id = state.selected_id(state.focus)?;
        match state.focus {
            Panel::MyPrs | Panel::Reviews => {
                let pr = state.visible_prs(state.focus).into_iter().find(|p| p.id == id)?;
                Some(self.pr(pr, s, state.focus == Panel::Reviews))
            }
            Panel::Jira => Some(self.ticket(s.tickets.iter().find(|t| t.key == id)?, s)),
            Panel::Claude => {
                Some(self.session(s.sessions.iter().find(|c| c.pid.to_string() == id)?, s))
            }
        }
    }

    /// `text` word-wrapped to the pane width, one line per row.
    fn wrapped(&self, text: &str, style: Style) -> Vec<Line<'static>> {
        wrap(text, self.max).into_iter().map(|l| Line::styled(l, style)).collect()
    }

    /// `Label     value…`, cut to the pane width.
    fn row(&self, label: &str, value: Vec<Span<'static>>) -> Line<'static> {
        let mut spans = vec![styled(format!("{label:<LABEL_WIDTH$}"), theme::dim())];
        spans.extend(value);
        fit(spans, self.max)
    }

    /// `just now`, `31m ago`; empty when the timestamp does not parse.
    fn ago(&self, iso: &str) -> String {
        match parse_iso8601(iso).map(|t| age(t, self.now)) {
            Some(a) if a == "now" => "just now".into(),
            Some(a) => format!("{a} ago"),
            None => String::new(),
        }
    }

    fn comments_row(&self, count: u32, last: Option<&str>) -> Line<'static> {
        let value = match (count, last) {
            (0, _) => styled("none", theme::dim()),
            (n, Some(t)) => Span::raw(format!("{n} · last {}", self.ago(t))),
            (n, None) => Span::raw(n.to_string()),
        };
        self.row("Comments", vec![value])
    }

    fn jira_row(&self, key: Option<&str>, s: &Snapshot) -> Line<'static> {
        let Some(key) = key else { return self.row("Jira", vec![styled("–", theme::dim())]) };
        let mut value = vec![Span::raw(key.to_string())];
        if let Some(t) = s.tickets.iter().find(|t| t.key == key) {
            value.push(styled(" · ", theme::dim()));
            value.push(styled(t.status.clone(), theme::ticket_status(t.status_category)));
        }
        self.row("Jira", value)
    }

    fn recent_comments(&self, comments: &[Comment], out: &mut Vec<Line<'static>>) {
        if comments.is_empty() {
            return;
        }
        let mut sorted: Vec<&Comment> = comments.iter().collect();
        sorted.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        out.push(Line::default());
        out.push(Line::styled("Recent comments", theme::dim()));
        for c in sorted.into_iter().take(RECENT_COMMENTS) {
            let name = match (&c.author_name, c.author_kind) {
                (Some(n), _) => n.clone(),
                (None, AuthorKind::Copilot) => "Copilot".into(),
                (None, _) => c.author.clone(),
            };
            let tag = match c.author_kind {
                AuthorKind::Bot if !name.contains("[bot]") => " bot",
                _ => "",
            };
            out.push(fit(
                vec![
                    Span::raw("  "),
                    Span::raw(name),
                    styled(tag, theme::dim()),
                    styled(format!("  {}", self.ago(&c.created_at)), theme::dim()),
                ],
                self.max,
            ));
        }
    }

    fn pr(&self, pr: &PullRequest, s: &Snapshot, review_request: bool) -> Vec<Line<'static>> {
        let (icon, text, style) = theme::check(pr.checks);
        let mut reviews = vec![Span::raw(format!(
            "{} approved · {} pending",
            pr.approvals, pr.pending_reviewers
        ))];
        if let Some((decision, style)) = theme::review_decision(pr.review_decision) {
            reviews.push(styled(" · ", theme::dim()));
            reviews.push(styled(decision, style));
        }
        let mut out = vec![fit(
            vec![
                styled(pr.repo.clone(), theme::bold()),
                Span::raw(" "),
                styled(format!("#{}", pr.number), theme::accent_bold()),
            ],
            self.max,
        )];
        out.extend(self.wrapped(&pr.title, theme::bold()));
        out.extend([
            Line::default(),
            self.jira_row(pr.jira_key.as_deref(), s),
            self.row("Branch", vec![styled(pr.head_branch.clone(), theme::dim())]),
            self.row("Checks", vec![styled(format!("{icon} {text}"), style)]),
            self.row("Reviews", reviews),
            self.comments_row(pr.comment_count, pr.last_comment_at.as_deref()),
        ]);
        if review_request {
            let how = if pr.requested_directly { "you directly" } else { "via your team" };
            out.push(self.row("Requested", vec![Span::raw(how)]));
        }
        out.push(self.row("Updated", vec![Span::raw(self.ago(&pr.updated_at))]));
        self.recent_comments(&pr.recent_comments, &mut out);
        out.push(Line::default());
        out.push(hint("enter", "open in browser"));
        if pr.jira_key.is_some() {
            out.push(hint("J", "open Jira ticket"));
        }
        out
    }

    fn ticket(&self, t: &Ticket, s: &Snapshot) -> Vec<Line<'static>> {
        let mut out = vec![Line::styled(t.key.clone(), theme::accent_bold())];
        out.extend(self.wrapped(&t.summary, theme::bold()));
        out.extend([
            Line::default(),
            self.row("Status", vec![styled(t.status.clone(), theme::ticket_status(t.status_category))]),
            self.row("Priority", vec![match &t.priority {
                Some(p) => Span::raw(p.clone()),
                None => styled("–", theme::dim()),
            }]),
            self.comments_row(t.comment_count, t.last_comment_at.as_deref()),
            self.row("Updated", vec![Span::raw(self.ago(&t.updated_at))]),
        ]);
        let prs = s.my_pull_requests.iter().chain(&s.review_requests);
        for (i, pr) in prs.filter(|p| p.jira_key.as_deref() == Some(&t.key)).enumerate() {
            let label = if i == 0 { "PRs" } else { "" };
            out.push(self.row(label, vec![
                Span::raw(format!("{} ", pr.repo)),
                styled(format!("#{}", pr.number), theme::accent()),
            ]));
        }
        let sessions = s.sessions.iter().filter(|c| c.jira_key.as_deref() == Some(&t.key));
        for (i, c) in sessions.enumerate() {
            let (icon, label, style) = theme::session(c.status);
            out.push(self.row(if i == 0 { "Sessions" } else { "" }, vec![
                styled(icon, style),
                Span::raw(format!(" {} ", c.name)),
                styled(label, style),
            ]));
        }
        self.recent_comments(&t.recent_comments, &mut out);
        out.push(Line::default());
        out.push(hint("enter", "open in browser"));
        out
    }

    fn session(&self, c: &ClaudeSession, s: &Snapshot) -> Vec<Line<'static>> {
        let (icon, label, style) = theme::session(c.status);
        let mut status = vec![styled(format!("{icon} {label}"), style)];
        if let Some(why) = &c.waiting_for {
            status.push(styled(" · ", theme::dim()));
            status.push(Span::raw(why.clone()));
        }
        let cwd_room = self.max.saturating_sub(LABEL_WIDTH);
        let mut out = vec![
            fit(vec![styled(c.name.clone(), theme::accent_bold())], self.max),
            Line::default(),
            self.row("Status", status),
            self.row("Directory", vec![Span::raw(truncate_left(&c.cwd, cwd_room))]),
            self.jira_row(c.jira_key.as_deref(), s),
            self.row("PID", vec![styled(c.pid.to_string(), theme::dim())]),
            self.row("Updated", vec![Span::raw(self.ago(&c.updated_at))]),
            Line::default(),
            hint("enter", "focus its Ghostty window"),
        ];
        if c.jira_key.is_some() {
            out.push(hint("J", "open Jira ticket"));
        }
        out
    }
}

fn hint(key: &'static str, what: &'static str) -> Line<'static> {
    Line::from(vec![
        styled(format!("{key:<7}"), theme::accent().add_modifier(Modifier::BOLD)),
        Span::styled(what, Style::new()),
    ])
}
