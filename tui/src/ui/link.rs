//! Terminal hyperlinks (OSC 8: `ESC ] 8 ;; URL ESC \ text ESC ] 8 ;; ESC \`), ⌘-click in Ghostty.
//!
//! Ratatui has no hyperlinks, and the text it renders drops control characters, so links go
//! onto the buffer after rendering: each cell of the linked text gets its symbol wrapped in the
//! sequence and keeps the width of that symbol (`CellDiffOption::ForcedWidth`), because the
//! sequences take no columns on screen. Layout, truncation and colours stay as rendered, and a
//! terminal without OSC 8 ignores the sequences and shows the same text.

use ratatui::buffer::{Buffer, CellDiffOption, CellWidth};
use ratatui::layout::Rect;
use std::num::NonZeroU16;

const OPEN: &str = "\x1b]8;;";
const END: &str = "\x1b\\";
const CLOSE: &str = "\x1b]8;;\x1b\\";

/// Links the text in `row` (one row of `buf`) to `url`. Cells outside the buffer, and cells
/// that already carry a link, are left alone.
pub fn apply(buf: &mut Buffer, row: Rect, url: &str) {
    let url = uri(url);
    let row = row.intersection(buf.area);
    if url.is_empty() || row.is_empty() {
        return;
    }
    let mut x = row.x;
    while x < row.right() {
        let cell = &mut buf[(x, row.y)];
        let shown = cell.symbol().to_string();
        let width = shown.as_str().cell_width().max(1);
        if target(&shown).is_none() {
            cell.set_symbol(&format!("{OPEN}{url}{END}{shown}{CLOSE}"));
            // `width` is at least 1. The trailing cells of a wide character stay as rendered.
            cell.set_diff_option(CellDiffOption::ForcedWidth(NonZeroU16::new(width).unwrap_or(NonZeroU16::MIN)));
        }
        x = x.saturating_add(width);
    }
}

/// What a cell shows: its symbol without the link around it (for tests of the rendering).
#[cfg(test)]
pub fn visible(symbol: &str) -> String {
    split(symbol).map_or(symbol, |(_, text)| text).to_string()
}

/// The link target of a cell's symbol, if it has one.
pub fn target(symbol: &str) -> Option<&str> {
    split(symbol).map(|(url, _)| url)
}

fn split(symbol: &str) -> Option<(&str, &str)> {
    let (url, rest) = symbol.strip_prefix(OPEN)?.split_once(END)?;
    Some((url, rest.strip_suffix(CLOSE)?))
}

/// `url` as OSC 8 allows it: printable ASCII only, every other byte percent-encoded, so no
/// text from the data can end the sequence early.
pub fn uri(url: &str) -> String {
    let mut out = String::with_capacity(url.len());
    for b in url.bytes() {
        if (0x21..=0x7e).contains(&b) {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// A branch name as a URL path: `/` stays, everything but letters, digits and `-._~` is
/// percent-encoded (`#`, `%`, `?`, non-ASCII).
pub fn path(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wraps_each_cell_and_keeps_its_width() {
        let mut buf = Buffer::empty(Rect::new(0, 0, 8, 1));
        buf.set_string(0, 0, "a日b", ratatui::style::Style::new());
        apply(&mut buf, Rect::new(0, 0, 4, 1), "https://x.test/a");
        assert_eq!(buf[(0, 0)].symbol(), "\x1b]8;;https://x.test/a\x1b\\a\x1b]8;;\x1b\\");
        assert_eq!(visible(buf[(1, 0)].symbol()), "日");
        assert_eq!(buf[(1, 0)].cell_width(), 2);
        // The wide character's trailing cell is not wrapped on its own.
        assert_eq!(buf[(2, 0)].symbol(), " ");
        assert_eq!(target(buf[(3, 0)].symbol()), Some("https://x.test/a"));
        assert_eq!(buf[(3, 0)].cell_width(), 1);
        // Outside the row: untouched.
        assert_eq!(buf[(4, 0)].symbol(), " ");
        assert_eq!(target(buf[(4, 0)].symbol()), None);
    }

    #[test]
    fn a_row_outside_the_buffer_or_an_empty_url_changes_nothing() {
        let mut buf = Buffer::empty(Rect::new(0, 0, 4, 1));
        let before = buf.clone();
        apply(&mut buf, Rect::new(0, 3, 4, 1), "https://x.test");
        apply(&mut buf, Rect::new(0, 0, 4, 1), "");
        assert_eq!(buf, before);
        // A row reaching past the edge is clipped.
        apply(&mut buf, Rect::new(2, 0, 10, 1), "https://x.test");
        assert!(target(buf[(3, 0)].symbol()).is_some());
    }

    #[test]
    fn visible_text_of_plain_and_linked_symbols() {
        assert_eq!(visible("x"), "x");
        assert_eq!(target("x"), None);
        assert_eq!(visible("\x1b]8;;u\x1b\\ř\x1b]8;;\x1b\\"), "ř");
        assert_eq!(target("\x1b]8;;u\x1b\\ř\x1b]8;;\x1b\\"), Some("u"));
    }

    #[test]
    fn urls_and_branches_are_encoded() {
        assert_eq!(uri("https://x.test/a b"), "https://x.test/a%20b");
        assert_eq!(uri("https://x.test/\x1b]8;;evil"), "https://x.test/%1B]8;;evil");
        assert_eq!(uri("https://x.test/ž"), "https://x.test/%C5%BE");
        assert_eq!(path("feature/STORE-1-fix_it.v2~"), "feature/STORE-1-fix_it.v2~");
        assert_eq!(path("fix/#12 100%?ä"), "fix/%2312%20100%25%3F%C3%A4");
    }
}
