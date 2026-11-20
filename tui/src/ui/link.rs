//! Terminal hyperlinks (OSC 8: `ESC ] 8 ; id=ID ; URL ESC \ text ESC ] 8 ;; ESC \`), ⇧⌘-click in
//! Ghostty, and where they are on screen (`Links`), so the TUI opens them on a plain click.
//!
//! Ratatui has no hyperlinks, and the text it renders drops control characters, so links go
//! onto the buffer after rendering: each cell of the linked text gets its symbol wrapped in the
//! sequence and keeps the width of that symbol (`CellDiffOption::ForcedWidth`), because the
//! sequences take no columns on screen. Layout, truncation and colours stay as rendered, and a
//! terminal without OSC 8 ignores the sequences and shows the same text.
//!
//! The `id` is the same for every cell of one link on one row (a hash of the URL and the row),
//! so a terminal treats the cells, each wrapped on its own, as one link and underlines all of
//! it on hover.

use ratatui::buffer::{Buffer, CellDiffOption, CellWidth};
use ratatui::layout::{Position, Rect};
use std::num::NonZeroU16;

const OPEN: &str = "\x1b]8;";
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
    let open = format!("{OPEN}id={:08x};{url}{END}", link_id(&url, row.y));
    let mut x = row.x;
    while x < row.right() {
        let cell = &mut buf[(x, row.y)];
        let shown = cell.symbol().to_string();
        let width = shown.as_str().cell_width().max(1);
        if target(&shown).is_none() {
            cell.set_symbol(&format!("{open}{shown}{CLOSE}"));
            // `width` is at least 1. The trailing cells of a wide character stay as rendered.
            cell.set_diff_option(CellDiffOption::ForcedWidth(NonZeroU16::new(width).unwrap_or(NonZeroU16::MIN)));
        }
        x = x.saturating_add(width);
    }
}

/// Where the clickable links of a drawn frame are: one row part per link, with its target as
/// the terminal gets it. Every draw builds them anew.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Links(Vec<(Rect, String)>);

impl Links {
    /// Records that `row` links to `url`; an empty row or URL is left out, as `apply` does.
    pub fn push(&mut self, row: Rect, url: &str) {
        if !row.is_empty() && !url.is_empty() {
            self.0.push((row, uri(url)));
        }
    }

    /// The link under (`x`, `y`), if there is one.
    pub fn at(&self, x: u16, y: u16) -> Option<&str> {
        let pos = Position { x, y };
        self.0.iter().find(|(r, _)| r.contains(pos)).map(|(_, url)| url.as_str())
    }

    /// Every recorded row part and its target (for tests).
    #[cfg(test)]
    pub fn iter(&self) -> impl Iterator<Item = (Rect, &str)> {
        self.0.iter().map(|(r, url)| (*r, url.as_str()))
    }
}

/// What a cell shows: its symbol without the link around it (for tests of the rendering).
#[cfg(test)]
pub fn visible(symbol: &str) -> String {
    split(symbol).map_or(symbol, |(_, _, text)| text).to_string()
}

/// The link target of a cell's symbol, if it has one.
pub fn target(symbol: &str) -> Option<&str> {
    split(symbol).map(|(_, url, _)| url)
}

/// The `id` parameter of a cell's link, if it has one.
#[cfg(test)]
pub fn id(symbol: &str) -> Option<&str> {
    let (params, _, _) = split(symbol)?;
    params.split(':').find_map(|p| p.strip_prefix("id="))
}

/// The parameters, target and text of a linked symbol.
fn split(symbol: &str) -> Option<(&str, &str, &str)> {
    let (link, rest) = symbol.strip_prefix(OPEN)?.split_once(END)?;
    let (params, url) = link.split_once(';')?;
    Some((params, url, rest.strip_suffix(CLOSE)?))
}

/// A stable id for the link to `url` on row `y`: 32-bit FNV-1a over both.
fn link_id(url: &str, y: u16) -> u32 {
    url.bytes().chain(y.to_be_bytes()).fold(0x811c_9dc5, |hash, b| (hash ^ u32::from(b)).wrapping_mul(0x0100_0193))
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
        let id = format!("{:08x}", link_id("https://x.test/a", 0));
        assert_eq!(buf[(0, 0)].symbol(), format!("\x1b]8;id={id};https://x.test/a\x1b\\a\x1b]8;;\x1b\\"));
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
    fn one_link_has_one_id_per_row() {
        let mut buf = Buffer::empty(Rect::new(0, 0, 6, 3));
        buf.set_string(0, 0, "abc", ratatui::style::Style::new());
        buf.set_string(0, 1, "abc", ratatui::style::Style::new());
        apply(&mut buf, Rect::new(0, 0, 3, 1), "https://x.test/a");
        apply(&mut buf, Rect::new(0, 1, 3, 1), "https://x.test/a");
        apply(&mut buf, Rect::new(3, 0, 3, 1), "https://x.test/b");
        let ids = |y: u16, xs: std::ops::Range<u16>| xs.map(|x| id(buf[(x, y)].symbol()).unwrap().to_string()).collect::<Vec<_>>();
        // Every cell of a row's link shares the id, so the terminal underlines all of it.
        let first = ids(0, 0..3);
        assert!(first.iter().all(|i| *i == first[0]) && first[0].len() == 8, "{first:?}");
        // The same URL on another row, and another URL on the same row, get other ids.
        assert_ne!(ids(1, 0..1)[0], first[0]);
        assert_ne!(ids(0, 3..4)[0], first[0]);
        // Stable: the same URL and row always give the same id.
        assert_eq!(first[0], format!("{:08x}", link_id("https://x.test/a", 0)));
        assert_eq!(target(buf[(1, 1)].symbol()), Some("https://x.test/a"));
        assert_eq!(visible(buf[(1, 1)].symbol()), "b");
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
        assert_eq!(id("\x1b]8;;u\x1b\\ř\x1b]8;;\x1b\\"), None);
        let with_id = "\x1b]8;id=0a1b2c3d;u\x1b\\ř\x1b]8;;\x1b\\";
        assert_eq!((visible(with_id).as_str(), target(with_id), id(with_id)), ("ř", Some("u"), Some("0a1b2c3d")));
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
