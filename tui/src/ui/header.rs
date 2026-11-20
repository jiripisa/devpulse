//! The top line: app name, connection state, each source's state and the upgrade status.

use super::text::{fit, styled, width};
use crate::protocol::{SourceState, SourceStatus, UpgradePhase};
use crate::state::AppState;
use crate::theme;
use crate::time::age_of;
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use std::time::SystemTime;

pub fn render(frame: &mut Frame, area: Rect, state: &AppState, now: SystemTime) {
    let mut spans = vec![styled(" DevPulse", theme::accent_bold())];
    if state.reconnecting {
        spans.push(Span::raw("  "));
        spans.push(styled("disconnected — reconnecting…", theme::error_bold()));
    } else if state.snapshot.is_none() {
        spans.push(Span::raw("  "));
        spans.push(styled("connecting…", theme::dim()));
    }
    if let Some(s) = &state.snapshot {
        for (name, status) in
            [("GitHub", &s.sources.github), ("Jira", &s.sources.jira), ("Claude", &s.sources.claude)]
        {
            spans.push(Span::raw("   "));
            spans.extend(source(name, status, now));
        }
    }
    let right = upgrade(state);
    let right_width = right.as_ref().map_or(0, |l| width(&l.to_string()));
    let room = usize::from(area.width).saturating_sub(right_width + 1);
    frame.render_widget(Paragraph::new(fit(spans, room)), area);
    if let Some(line) = right
        && right_width < usize::from(area.width)
    {
        frame.render_widget(Paragraph::new(line.right_aligned()), area);
    }
}

/// `GitHub ✓ 2m`, `Jira ✗ credentials rejected (20m old)`, `Claude – off`.
fn source(name: &'static str, status: &SourceStatus, now: SystemTime) -> Vec<Span<'static>> {
    let (icon, style) = theme::source(status.state);
    let age = status.last_success.as_deref().and_then(|t| age_of(t, now));
    let mut spans =
        vec![styled(name, theme::bold()), Span::raw(" "), styled(icon, style), Span::raw(" ")];
    match status.state {
        SourceState::Ok => spans.push(styled(age.unwrap_or_else(|| "ok".into()), theme::dim())),
        SourceState::Fetching => spans.push(styled("fetching", theme::dim())),
        SourceState::Error => {
            let message = status.message.as_deref().unwrap_or("error");
            spans.push(styled(strip_source_name(message, name), theme::error()));
            if let Some(age) = age {
                spans.push(styled(format!(" ({age} old)"), theme::dim()));
            }
        }
        SourceState::Disabled => spans.push(styled("off", theme::dim())),
        SourceState::Unconfigured => spans.push(styled("not set up", theme::dim())),
        SourceState::Unknown => spans.push(styled("unknown", theme::dim())),
    }
    spans
}

/// `Jira credentials rejected` after `Jira ✗` reads better as `credentials rejected`.
fn strip_source_name(message: &str, name: &str) -> String {
    match message.split_once(' ') {
        Some((first, rest)) if first.eq_ignore_ascii_case(name) && !rest.is_empty() => rest.to_string(),
        _ => message.to_string(),
    }
}

fn upgrade(state: &AppState) -> Option<Line<'static>> {
    let u = state.upgrade.as_ref()?;
    let (text, style) = match u.phase {
        UpgradePhase::Checking => ("checking for updates…".to_string(), theme::warn()),
        UpgradePhase::Downloading => {
            let pct = u.progress.map(|p| format!(" {:.0}%", p * 100.0)).unwrap_or_default();
            (format!("downloading update{pct}"), theme::warn())
        }
        UpgradePhase::Installing => ("installing update…".to_string(), theme::warn()),
        UpgradePhase::Restarting => ("restarting DevPulse…".to_string(), theme::warn()),
        UpgradePhase::UpToDate => ("up to date".to_string(), theme::ok()),
        UpgradePhase::Failed => {
            let msg = u.message.as_deref().unwrap_or("unknown error");
            (format!("update failed: {msg}"), theme::error())
        }
        UpgradePhase::Unknown => return None,
    };
    Some(Line::from(vec![styled(text, style), Span::raw(" ")]))
}
