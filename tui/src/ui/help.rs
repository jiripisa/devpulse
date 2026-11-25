//! The `?` overlay listing every key (spec §5.5).

use super::text::{fit, styled};
use crate::theme;
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Clear, Padding, Paragraph};

const KEYS: [(&str, &str); 11] = [
    ("↑ ↓  j / k", "move"),
    ("1–5  Tab  Shift-Tab", "switch panel (5: tickets you created, when on)"),
    ("Enter", "open: browser for a PR or ticket, Ghostty for a session"),
    ("J", "open the linked Jira ticket"),
    ("/", "filter (Enter keeps it, Esc clears it)"),
    ("r", "refresh"),
    (",", "open Settings in the app"),
    ("?", "this help"),
    ("q  Ctrl-C", "quit"),
    ("mouse", "click selects, wheel moves"),
    ("click / ⌘-click", "open an underlined link in the browser"),
];

const KEY_WIDTH: usize = 21;

pub fn render(frame: &mut Frame, area: Rect) {
    let width = area.width.saturating_sub(4).min(76);
    let height = (KEYS.len() as u16 + 4).min(area.height);
    let rect = Rect {
        x: area.x + (area.width - width) / 2,
        y: area.y + (area.height - height) / 2,
        width,
        height,
    };
    let border = theme::accent_bold();
    let block = Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(border)
        .title_top(Line::from(vec![styled("─", border), styled(" Keys ", theme::bold())]))
        .title_bottom(
            Line::from(vec![styled(" esc close ", theme::dim()), styled("─", border)]).right_aligned(),
        )
        .padding(Padding::new(1, 1, 1, 0));
    let max = usize::from(block.inner(rect).width);
    let lines: Vec<Line> = KEYS
        .iter()
        .map(|(key, what)| {
            fit(vec![styled(format!("{key:<KEY_WIDTH$}"), theme::accent()), Span::raw(*what)], max)
        })
        .collect();
    frame.render_widget(Clear, rect);
    frame.render_widget(Paragraph::new(lines).block(block), rect);
}
