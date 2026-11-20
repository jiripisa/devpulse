//! The right-hand pane: everything about the item selected in the focused panel.

use super::link;
use super::panels::title as panel_title;
use super::text::{ELLIPSIS, fit, pad, styled, truncate_left, width, wrap};
use crate::protocol::{AuthorKind, ClaudeSession, Comment, PullRequest, RelatedTicket, Snapshot, Ticket};
use crate::state::{AppState, Panel};
use crate::theme;
use crate::time::{age, parse_iso8601};
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Padding, Paragraph};
use std::ops::Range;
use std::time::SystemTime;

const LABEL_WIDTH: usize = 10;
const RECENT_COMMENTS: usize = 3;
/// Widest relation and status column in the Related section; longer ones are cut.
const RELATION_WIDTH: usize = 16;
const STATUS_WIDTH: usize = 14;
const KEY_WIDTH: usize = 16;

/// One row of the pane and, when part of it is a hyperlink, its columns and target.
struct Row {
    line: Line<'static>,
    link: Option<(Range<usize>, String)>,
}

impl From<Line<'static>> for Row {
    fn from(line: Line<'static>) -> Self {
        Row { line, link: None }
    }
}

impl Row {
    /// `line` with its spans `spans` (as far as `fit` kept them) linked to `url`.
    fn linked(line: Line<'static>, spans: Range<usize>, url: Option<String>) -> Self {
        let col = |n: usize| line.spans.iter().take(n).map(|s| width(&s.content)).sum::<usize>();
        let cols = col(spans.start)..col(spans.end);
        let link = url.filter(|_| !cols.is_empty()).map(|url| (cols, url));
        Row { line, link }
    }
}

pub fn render(frame: &mut Frame, area: Rect, state: &AppState, now: SystemTime) {
    let block = Block::bordered()
        .border_type(BorderType::Rounded)
        .title_top(Line::from(vec![Span::raw("─"), styled(" Detail ", theme::bold())]))
        .padding(Padding::horizontal(1));
    let inner = block.inner(area);
    let d = Detail { max: usize::from(inner.width), now };
    let mut rows = match &state.snapshot {
        None => d.wrapped("Waiting for data from DevPulse…", theme::dim(), None),
        Some(s) => d.rows(state, s).unwrap_or_else(|| {
            let what = panel_title(state.focus);
            d.wrapped(&format!("Nothing selected in {what}."), theme::dim(), None)
        }),
    };
    // Every line is one row (titles are wrapped above), so a cut is visible as a `…` row.
    let height = usize::from(inner.height);
    if rows.len() > height && height > 0 {
        rows.truncate(height - 1);
        rows.push(Line::styled(ELLIPSIS, theme::dim()).into());
    }
    let (lines, links): (Vec<_>, Vec<_>) = rows.into_iter().map(|r| (r.line, r.link)).unzip();
    frame.render_widget(Paragraph::new(lines).block(block), area);
    // The links go on the rendered cells, so the text and its width stay as laid out above.
    for (y, link) in (inner.top()..inner.bottom()).zip(links) {
        let Some((cols, url)) = link else { continue };
        let x = inner.x.saturating_add(u16::try_from(cols.start).unwrap_or(u16::MAX));
        let width = u16::try_from(cols.len()).unwrap_or(u16::MAX);
        link::apply(frame.buffer_mut(), Rect { x, y, width, height: 1 }.intersection(inner), &url);
    }
}

struct Detail {
    max: usize,
    now: SystemTime,
}

impl Detail {
    fn rows(&self, state: &AppState, s: &Snapshot) -> Option<Vec<Row>> {
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

    /// `text` word-wrapped to the pane width, one line per row, each linked to `url`.
    fn wrapped(&self, text: &str, style: Style, url: Option<&str>) -> Vec<Row> {
        wrap(text, self.max)
            .into_iter()
            .map(|l| Row::linked(Line::styled(l, style), 0..1, url.map(str::to_string)))
            .collect()
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

    /// `Jira      KEY · status`, the key linked to the ticket; the status when the ticket is
    /// known, mine or linked from a PR.
    fn jira_row(&self, key: Option<&str>, s: &Snapshot) -> Row {
        let Some(key) = key else { return self.row("Jira", vec![styled("–", theme::dim())]).into() };
        let mut value = vec![Span::raw(key.to_string())];
        if let Some(t) = known_ticket(s, key) {
            value.push(styled(" · ", theme::dim()));
            value.push(styled(t.status.clone(), theme::ticket_status(t.status_category)));
        }
        Row::linked(self.row("Jira", value), 1..2, ticket_url(s, key))
    }

    /// `Related`, then one row per link: relation, key, status and summary in columns, each
    /// row linked to its ticket. Nothing without links.
    fn related(&self, related: &[RelatedTicket], s: &Snapshot, out: &mut Vec<Row>) {
        if related.is_empty() {
            return;
        }
        let column = |text: fn(&RelatedTicket) -> &str, cap: usize| {
            related.iter().map(|r| width(text(r))).max().unwrap_or(0).min(cap)
        };
        let relation_width = column(|r| &r.relation, RELATION_WIDTH);
        let key_width = column(|r| &r.key, KEY_WIDTH);
        let status_width = column(|r| &r.status, STATUS_WIDTH);
        out.push(Line::default().into());
        out.push(Line::styled("Related", theme::dim()).into());
        for r in related {
            let line = fit(
                vec![
                    Span::raw("  "),
                    styled(format!("{}  ", pad(&r.relation, relation_width)), theme::dim()),
                    styled(format!("{}  ", pad(&r.key, key_width)), theme::accent()),
                    styled(
                        format!("{}  ", pad(&r.status, status_width)),
                        theme::ticket_status(r.status_category),
                    ),
                    Span::raw(r.summary.clone()),
                ],
                self.max,
            );
            out.push(Row::linked(line, 1..5, ticket_url(s, &r.key)));
        }
    }

    fn recent_comments(&self, comments: &[Comment], out: &mut Vec<Row>) {
        if comments.is_empty() {
            return;
        }
        let mut sorted: Vec<&Comment> = comments.iter().collect();
        sorted.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        out.push(Line::default().into());
        out.push(Line::styled("Recent comments", theme::dim()).into());
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
            out.push(
                fit(
                    vec![
                        Span::raw("  "),
                        Span::raw(name),
                        styled(tag, theme::dim()),
                        styled(format!("  {}", self.ago(&c.created_at)), theme::dim()),
                    ],
                    self.max,
                )
                .into(),
            );
        }
    }

    fn pr(&self, pr: &PullRequest, s: &Snapshot, review_request: bool) -> Vec<Row> {
        let (icon, text, style) = theme::check(pr.checks);
        let mut reviews = vec![Span::raw(format!(
            "{} approved · {} pending",
            pr.approvals, pr.pending_reviewers
        ))];
        if let Some((decision, style)) = theme::review_decision(pr.review_decision) {
            reviews.push(styled(" · ", theme::dim()));
            reviews.push(styled(decision, style));
        }
        let header = fit(
            vec![
                styled(pr.repo.clone(), theme::bold()),
                Span::raw(" "),
                styled(format!("#{}", pr.number), theme::accent_bold()),
            ],
            self.max,
        );
        let mut out = vec![Row::linked(header, 0..3, Some(pr.url.clone()))];
        out.extend(self.wrapped(&pr.title, theme::bold(), Some(&pr.url)));
        let branch = self.row("Branch", vec![styled(pr.head_branch.clone(), theme::dim())]);
        out.extend([
            Line::default().into(),
            self.jira_row(pr.jira_key.as_deref(), s),
            Row::linked(branch, 1..2, Some(branch_url(pr))),
            self.row("Checks", vec![styled(format!("{icon} {text}"), style)]).into(),
            self.row("Reviews", reviews).into(),
            self.comments_row(pr.comment_count, pr.last_comment_at.as_deref()).into(),
        ]);
        if review_request {
            let how = if pr.requested_directly { "you directly" } else { "via your team" };
            out.push(self.row("Requested", vec![Span::raw(how)]).into());
        }
        out.push(self.row("Updated", vec![Span::raw(self.ago(&pr.updated_at))]).into());
        if let Some(t) = pr.jira_key.as_deref().and_then(|key| known_ticket(s, key)) {
            self.related(&t.related, s, &mut out);
        }
        self.recent_comments(&pr.recent_comments, &mut out);
        out.push(Line::default().into());
        out.push(hint("enter", "open in browser").into());
        if pr.jira_key.is_some() {
            out.push(hint("J", "open Jira ticket").into());
        }
        out
    }

    fn ticket(&self, t: &Ticket, s: &Snapshot) -> Vec<Row> {
        let key = Line::styled(t.key.clone(), theme::accent_bold());
        let mut out = vec![Row::linked(key, 0..1, Some(t.url.clone()))];
        out.extend(self.wrapped(&t.summary, theme::bold(), Some(&t.url)));
        out.extend([
            Line::default(),
            self.row("Status", vec![styled(t.status.clone(), theme::ticket_status(t.status_category))]),
            self.row("Priority", vec![match &t.priority {
                Some(p) => Span::raw(p.clone()),
                None => styled("–", theme::dim()),
            }]),
            self.comments_row(t.comment_count, t.last_comment_at.as_deref()),
            self.row("Updated", vec![Span::raw(self.ago(&t.updated_at))]),
        ].map(Row::from));
        let prs = s.my_pull_requests.iter().chain(&s.review_requests);
        for (i, pr) in prs.filter(|p| p.jira_key.as_deref() == Some(&t.key)).enumerate() {
            let label = if i == 0 { "PRs" } else { "" };
            out.push(self.row(label, vec![
                Span::raw(format!("{} ", pr.repo)),
                styled(format!("#{}", pr.number), theme::accent()),
            ]).into());
        }
        let sessions = s.sessions.iter().filter(|c| c.jira_key.as_deref() == Some(&t.key));
        for (i, c) in sessions.enumerate() {
            let (icon, label, style) = theme::session(c.status);
            out.push(self.row(if i == 0 { "Sessions" } else { "" }, vec![
                styled(icon, style),
                Span::raw(format!(" {} ", c.name)),
                styled(label, style),
            ]).into());
        }
        self.related(&t.related, s, &mut out);
        self.recent_comments(&t.recent_comments, &mut out);
        out.push(Line::default().into());
        out.push(hint("enter", "open in browser").into());
        out
    }

    fn session(&self, c: &ClaudeSession, s: &Snapshot) -> Vec<Row> {
        let (icon, label, style) = theme::session(c.status);
        let mut status = vec![styled(format!("{icon} {label}"), style)];
        if let Some(why) = &c.waiting_for {
            status.push(styled(" · ", theme::dim()));
            status.push(Span::raw(why.clone()));
        }
        let cwd_room = self.max.saturating_sub(LABEL_WIDTH);
        let mut out = vec![
            fit(vec![styled(c.name.clone(), theme::accent_bold())], self.max).into(),
            Line::default().into(),
            self.row("Status", status).into(),
            self.row("Directory", vec![Span::raw(truncate_left(&c.cwd, cwd_room))]).into(),
            self.jira_row(c.jira_key.as_deref(), s),
            self.row("PID", vec![styled(c.pid.to_string(), theme::dim())]).into(),
            self.row("Updated", vec![Span::raw(self.ago(&c.updated_at))]).into(),
            Line::default().into(),
            hint("enter", "focus its Ghostty window").into(),
        ];
        if c.jira_key.is_some() {
            out.push(hint("J", "open Jira ticket").into());
        }
        out
    }
}

/// The ticket with `key`: one of mine, or one a PR links to.
fn known_ticket<'a>(s: &'a Snapshot, key: &str) -> Option<&'a Ticket> {
    s.tickets.iter().chain(&s.linked_tickets).find(|t| t.key == key)
}

/// The ticket's page: its own URL when known, else built from the Jira site; `None` without
/// a site.
fn ticket_url(s: &Snapshot, key: &str) -> Option<String> {
    known_ticket(s, key).map(|t| t.url.clone()).or_else(|| {
        let base = s.jira_base_url.as_deref()?;
        Some(format!("{}/browse/{key}", base.trim_end_matches('/')))
    })
}

/// The PR's branch on GitHub, in the head repository (a fork) or else the PR's own.
fn branch_url(pr: &PullRequest) -> String {
    // The host as the PR's URL has it, so a GitHub other than github.com works too.
    let host = pr.url.find(&format!("/{}/", pr.repo)).map_or("https://github.com", |i| &pr.url[..i]);
    let repo = pr.head_repo.as_deref().unwrap_or(&pr.repo);
    format!("{host}/{repo}/tree/{}", link::path(&pr.head_branch))
}

fn hint(key: &'static str, what: &'static str) -> Line<'static> {
    Line::from(vec![
        styled(format!("{key:<7}"), theme::accent().add_modifier(Modifier::BOLD)),
        Span::styled(what, Style::new()),
    ])
}
