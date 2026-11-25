//! The bottom key bar (lazygit's options bar), or the filter prompt while typing one.

use super::text::{fit, styled, width};
use crate::state::{AppState, Panel};
use crate::theme;
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

/// A key hint; when the bar is too narrow, hints with the highest `drop` go first.
struct Hint {
    key: &'static str,
    what: &'static str,
    drop: u8,
}

const fn h(key: &'static str, what: &'static str, drop: u8) -> Hint {
    Hint { key, what, drop }
}

pub fn render(frame: &mut Frame, area: Rect, state: &AppState) {
    let max = usize::from(area.width);
    let mut lead: Vec<Span<'static>> = vec![Span::raw(" ")];
    if let Some(note) = &state.notice {
        lead.push(styled(note.clone(), theme::warn().add_modifier(Modifier::BOLD)));
        lead.push(Span::raw("   "));
    }
    let hints = if state.filter_editing {
        lead.push(styled("/", theme::accent_bold()));
        lead.push(Span::raw(state.filter.clone().unwrap_or_default()));
        lead.push(styled("▏", theme::accent()));
        lead.push(Span::raw("   "));
        vec![h("enter", "keep filter", 1), h("esc", "clear", 1)]
    } else {
        let mut hints = vec![h("↑↓/jk", "move", 3), h(if state.shown(Panel::Created) { "1-5" } else { "1-4" }, "panel", 3), h("enter", "open", 1)];
        if jira_hint(state) {
            hints.push(h("J", "jira", 3));
        }
        if let Some(f) = state.filter.as_deref() {
            lead.push(styled(format!("filter: {f}"), theme::accent()));
            lead.push(Span::raw("   "));
            hints.push(h("esc", "clear filter", 1));
        } else {
            hints.push(h("/", "filter", 2));
        }
        hints.extend([
            h("r", "refresh", 4),
            h(",", "settings", 5),
            h("?", "help", 1),
            h("q", "quit", 1),
        ]);
        hints
    };
    let right = position(state);
    let right_width = right.as_ref().map_or(0, |s| width(s) + 1);
    let room = max.saturating_sub(width_of(&lead) + right_width);
    let mut spans = lead;
    spans.extend(hint_spans(shrink(hints, room)));
    frame.render_widget(Paragraph::new(fit(spans, max.saturating_sub(right_width))), area);
    if let Some(pos) = right
        && width(&pos) + 1 < max
    {
        let line = Line::from(vec![styled(pos, theme::dim()), Span::raw(" ")]).right_aligned();
        frame.render_widget(Paragraph::new(line), area);
    }
}

/// `J` applies: the selected PR or session has a Jira key.
fn jira_hint(state: &AppState) -> bool {
    let Some(id) = state.selected_id(state.focus) else { return false };
    match state.focus {
        Panel::MyPrs | Panel::Reviews => {
            state.visible_prs(state.focus).iter().any(|p| p.id == id && p.jira_key.is_some())
        }
        Panel::Claude => {
            state.visible_sessions().iter().any(|c| c.pid.to_string() == id && c.jira_key.is_some())
        }
        Panel::Jira | Panel::Created => false,
    }
}

/// `2 of 3` for the focused list, like lazygit.
fn position(state: &AppState) -> Option<String> {
    let len = state.visible_ids(state.focus).len();
    (len > 0).then(|| format!("{} of {len}", state.selected[state.focus.index()] + 1))
}

fn width_of(spans: &[Span]) -> usize {
    spans.iter().map(|s| width(&s.content)).sum()
}

const SEPARATOR: &str = " · ";

fn hints_width(hints: &[Hint]) -> usize {
    let items: usize = hints.iter().map(|h| width(h.key) + 1 + width(h.what)).sum();
    items + hints.len().saturating_sub(1) * width(SEPARATOR)
}

/// Drops the least important hints (the last of the highest `drop`) until the rest fit.
fn shrink(mut hints: Vec<Hint>, room: usize) -> Vec<Hint> {
    while hints_width(&hints) > room {
        let worst = hints.iter().map(|h| h.drop).max().unwrap_or(0);
        if worst <= 1 {
            break;
        }
        let i = hints.iter().rposition(|h| h.drop == worst).unwrap_or(0);
        hints.remove(i);
    }
    hints
}

fn hint_spans(hints: Vec<Hint>) -> Vec<Span<'static>> {
    let mut spans = Vec::new();
    for (i, hint) in hints.into_iter().enumerate() {
        if i > 0 {
            spans.push(styled(SEPARATOR, theme::dim()));
        }
        spans.push(styled(hint.key, theme::accent()));
        spans.push(Span::raw(format!(" {}", hint.what)));
    }
    spans
}
