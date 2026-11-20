//! Rendering: the lazygit-style layout of panels, detail pane, header and key bar.

mod detail;
mod footer;
mod header;
mod help;
mod link;
mod panels;
mod text;

use crate::state::{Action, AppState, Panel};
use crate::theme;
use crossterm::event::{MouseButton, MouseEvent, MouseEventKind};
use ratatui::Frame;
use ratatui::layout::{Alignment, Rect};
use ratatui::text::Line;
use ratatui::widgets::Paragraph;
use std::time::SystemTime;

pub use link::Links;

/// Below this size the layout does not fit and a message is shown instead.
pub const MIN_WIDTH: u16 = 60;
pub const MIN_HEIGHT: u16 = 15;

/// Share of the width taken by the left column of panels.
const LEFT_PERCENT: u32 = 45;

pub struct Areas {
    pub header: Rect,
    /// Panels and detail pane together.
    pub body: Rect,
    pub panels: [Rect; 4],
    pub detail: Rect,
    pub footer: Rect,
}

/// The screen layout, or `None` when the terminal is smaller than `MIN_WIDTH`×`MIN_HEIGHT`.
pub fn areas(area: Rect, state: &AppState) -> Option<Areas> {
    if area.width < MIN_WIDTH || area.height < MIN_HEIGHT {
        return None;
    }
    let header = Rect { height: 1, ..area };
    let footer = Rect { y: area.bottom() - 1, height: 1, ..area };
    let body = Rect { y: area.y + 1, height: area.height - 2, ..area };
    let left_width = (u32::from(body.width) * LEFT_PERCENT / 100) as u16;
    let detail = Rect { x: body.x + left_width, width: body.width - left_width, ..body };
    let lens = Panel::ALL.map(|p| state.visible_ids(p).len());
    let heights = panel_heights(body.height, lens, state.focus);
    let mut y = body.y;
    let panels = heights.map(|h| {
        let r = Rect { x: body.x, y, width: left_width, height: h };
        y += h;
        r
    });
    Some(Areas { header, body, panels, detail, footer })
}

/// Splits `total` rows between the 4 panels. Each panel wants its items plus 2 border rows and
/// gets at least one item row; the focused panel is served first and gets all spare rows.
pub fn panel_heights(total: u16, lens: [usize; 4], focus: Panel) -> [u16; 4] {
    const MIN: u16 = 3;
    if total < MIN * 4 {
        let mut h = [total / 4; 4];
        h[focus.index()] += total % 4;
        return h;
    }
    let want = lens.map(|n| u16::try_from(n.max(1)).unwrap_or(u16::MAX).saturating_add(2));
    let mut h = [MIN; 4];
    let mut left = total - MIN * 4;
    let order = std::iter::once(focus).chain(Panel::ALL.into_iter().filter(|p| *p != focus));
    for p in order {
        let add = (want[p.index()] - MIN).min(left);
        h[p.index()] += add;
        left -= add;
    }
    h[focus.index()] += left;
    h
}

/// First visible row of a list of `len` items in `height` rows, keeping `selected` on screen.
pub fn list_offset(selected: usize, len: usize, height: usize) -> usize {
    if height == 0 || len <= height {
        return 0;
    }
    selected.min(len - 1).saturating_sub(height - 1)
}

/// What a click at (`x`, `y`) hits: a panel and, inside its list, the item index under the
/// pointer (`None` on the border). The detail pane, header and footer give `None`.
pub fn hit_test(area: Rect, state: &AppState, x: u16, y: u16) -> Option<(Panel, Option<usize>)> {
    let a = areas(area, state)?;
    let pos = ratatui::layout::Position { x, y };
    let panel = Panel::ALL.into_iter().find(|p| a.panels[p.index()].contains(pos))?;
    let r = a.panels[panel.index()];
    let inner_rows = r.height.saturating_sub(2);
    let on_border = x == r.x || x == r.right() - 1 || y == r.y || y >= r.y + 1 + inner_rows;
    if on_border {
        return Some((panel, None));
    }
    let len = state.visible_ids(panel).len();
    let offset = list_offset(state.selected[panel.index()], len, usize::from(inner_rows));
    Some((panel, Some(offset + usize::from(y - r.y - 1))))
}

/// A left press of the mouse on the screen last drawn (`area`, with its `links`): opens the link
/// under the pointer, or else focuses and selects what `hit_test` finds. The modifier bits do
/// not matter: Ghostty sends ⌘-click as a plain click (SGR has no bit for ⌘), and sometimes
/// with the alt or ctrl bit set. Any other mouse event does nothing.
pub fn click(area: Rect, state: &mut AppState, links: &Links, mouse: MouseEvent) -> Option<Action> {
    if mouse.kind != MouseEventKind::Down(MouseButton::Left) {
        return None;
    }
    let hit = hit_test(area, state, mouse.column, mouse.row);
    state.left_click(links.at(mouse.column, mouse.row), hit)
}

/// Draws the whole screen for `state`; relative ages are computed against `now`. Returns where
/// its clickable links are.
pub fn draw(frame: &mut Frame, state: &AppState, now: SystemTime) -> Links {
    let area = frame.area();
    let Some(a) = areas(area, state) else {
        too_small(frame, area);
        return Links::default();
    };
    header::render(frame, a.header, state, now);
    for panel in Panel::ALL {
        panels::render(frame, a.panels[panel.index()], state, panel);
    }
    let links = detail::render(frame, a.detail, state, now);
    if state.reconnecting {
        frame.buffer_mut().set_style(a.body, theme::dim());
    }
    footer::render(frame, a.footer, state);
    if state.show_help {
        help::render(frame, area);
    }
    links
}

fn too_small(frame: &mut Frame, area: Rect) {
    let lines = vec![
        Line::styled("terminal too small", theme::bold()),
        Line::styled(
            format!("needs {MIN_WIDTH}×{MIN_HEIGHT}, is {}×{}", area.width, area.height),
            theme::dim(),
        ),
    ];
    let height = area.height.min(2);
    let rect = Rect { y: area.y + (area.height - height) / 2, height, ..area };
    frame.render_widget(Paragraph::new(lines).alignment(Alignment::Center), rect);
}

#[cfg(test)]
mod tests;
