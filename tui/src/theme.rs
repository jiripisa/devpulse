//! Styles and status icons. Only ANSI named colors, so the terminal's (Ghostty's) theme applies.

use crate::protocol::{CheckState, ReviewDecision, SessionStatus, SourceState, StatusCategory};
use ratatui::style::{Color, Modifier, Style};

/// Focused panel border, panel numbers, keys in hints.
pub const ACCENT: Color = Color::Cyan;

/// Background of the selected row in the focused panel (lazygit's selected line).
pub const SELECTED_BG: Color = Color::Blue;

pub fn accent() -> Style {
    Style::new().fg(ACCENT)
}

pub fn accent_bold() -> Style {
    accent().add_modifier(Modifier::BOLD)
}

pub fn bold() -> Style {
    Style::new().add_modifier(Modifier::BOLD)
}

pub fn dim() -> Style {
    Style::new().add_modifier(Modifier::DIM)
}

pub fn ok() -> Style {
    Style::new().fg(Color::Green)
}

pub fn warn() -> Style {
    Style::new().fg(Color::Yellow)
}

pub fn error() -> Style {
    Style::new().fg(Color::Red)
}

pub fn error_bold() -> Style {
    error().add_modifier(Modifier::BOLD)
}

/// A span's style on the selected row: blue background, bold; status colors (green, yellow, red)
/// stay, everything else turns white so it reads on blue in light and dark themes alike.
pub fn selected(style: Style) -> Style {
    let fg = match style.fg {
        Some(c @ (Color::Green | Color::Yellow | Color::Red)) => c,
        _ => Color::White,
    };
    style.fg(fg).bg(SELECTED_BG).add_modifier(Modifier::BOLD).remove_modifier(Modifier::DIM)
}

pub fn border(focused: bool) -> Style {
    if focused { accent_bold() } else { Style::new() }
}

/// Icon and style of a PR's checks: `✓` green, `✗` red, `…` yellow.
pub fn check(state: CheckState) -> (&'static str, &'static str, Style) {
    match state {
        CheckState::Success => ("✓", "passing", ok()),
        CheckState::Failure => ("✗", "failing", error()),
        CheckState::Error => ("✗", "error", error()),
        CheckState::Pending => ("…", "running", warn()),
        CheckState::None => ("·", "none", dim()),
        CheckState::Unknown => ("?", "unknown", dim()),
    }
}

/// Icon, list label and style of a Claude Code session: `◐` busy, `●` waiting, `○` idle.
pub fn session(status: SessionStatus) -> (&'static str, &'static str, Style) {
    match status {
        SessionStatus::Busy => ("◐", "busy", warn()),
        SessionStatus::Waiting => ("●", "waiting for input", error_bold()),
        SessionStatus::Idle => ("○", "idle", dim()),
        SessionStatus::Unknown => ("?", "unknown", dim()),
    }
}

pub fn ticket_status(category: StatusCategory) -> Style {
    match category {
        StatusCategory::Todo => Style::new(),
        StatusCategory::InProgress => warn(),
        StatusCategory::Done => ok(),
        StatusCategory::Unknown => dim(),
    }
}

/// Text and style of a review decision, or `None` when there is nothing to say.
pub fn review_decision(decision: ReviewDecision) -> Option<(&'static str, Style)> {
    match decision {
        ReviewDecision::Approved => Some(("approved", ok())),
        ReviewDecision::ChangesRequested => Some(("changes requested", error())),
        ReviewDecision::ReviewRequired => Some(("review required", warn())),
        ReviewDecision::None | ReviewDecision::Unknown => None,
    }
}

/// Icon and style of a data source in the header.
pub fn source(state: SourceState) -> (&'static str, Style) {
    match state {
        SourceState::Ok => ("✓", ok()),
        SourceState::Fetching => ("…", warn()),
        SourceState::Error => ("✗", error()),
        SourceState::Disabled | SourceState::Unconfigured => ("–", dim()),
        SourceState::Unknown => ("?", dim()),
    }
}
