//! Width-aware text fitting: everything that could overflow is cut with `…`, never mid-cell.

use ratatui::style::Style;
use ratatui::text::{Line, Span};
use unicode_width::UnicodeWidthStr;

pub const ELLIPSIS: &str = "…";

pub fn width(s: &str) -> usize {
    UnicodeWidthStr::width(s)
}

/// Cuts `s` to at most `max` columns, ending with `…` when something was cut.
pub fn truncate(s: &str, max: usize) -> String {
    if width(s) <= max {
        return s.to_string();
    }
    if max == 0 {
        return String::new();
    }
    let mut out = String::new();
    let mut used = 0;
    for c in s.chars() {
        let w = unicode_width::UnicodeWidthChar::width(c).unwrap_or(0);
        if used + w > max - 1 {
            break;
        }
        used += w;
        out.push(c);
    }
    out.push_str(ELLIPSIS);
    out
}

/// Cuts from the left (`…/the/end`), for paths whose end matters most.
pub fn truncate_left(s: &str, max: usize) -> String {
    if width(s) <= max {
        return s.to_string();
    }
    if max == 0 {
        return String::new();
    }
    let mut kept: Vec<char> = Vec::new();
    let mut used = 0;
    for c in s.chars().rev() {
        let w = unicode_width::UnicodeWidthChar::width(c).unwrap_or(0);
        if used + w > max - 1 {
            break;
        }
        used += w;
        kept.push(c);
    }
    let mut out = String::from(ELLIPSIS);
    out.extend(kept.into_iter().rev());
    out
}

/// Word-wraps `s` into lines of at most `max` columns; a word longer than a line is split.
pub fn wrap(s: &str, max: usize) -> Vec<String> {
    if max == 0 {
        return Vec::new();
    }
    let mut lines = Vec::new();
    let mut cur = String::new();
    let mut used = 0;
    for word in s.split_whitespace() {
        let w = width(word);
        if used > 0 && used + 1 + w <= max {
            cur.push(' ');
            cur.push_str(word);
            used += 1 + w;
            continue;
        }
        if used > 0 {
            lines.push(std::mem::take(&mut cur));
            used = 0;
        }
        for c in word.chars() {
            let cw = unicode_width::UnicodeWidthChar::width(c).unwrap_or(0);
            if used > 0 && used + cw > max {
                lines.push(std::mem::take(&mut cur));
                used = 0;
            }
            cur.push(c);
            used += cw;
        }
    }
    if used > 0 || lines.is_empty() {
        lines.push(cur);
    }
    lines
}

/// `s` cut or padded with spaces to exactly `cols` columns.
pub fn pad(s: &str, cols: usize) -> String {
    let t = truncate(s, cols);
    let w = width(&t);
    format!("{t}{}", " ".repeat(cols.saturating_sub(w)))
}

/// Joins spans into a line of at most `max` columns; the span that overflows is cut with `…`
/// and the rest are dropped.
pub fn fit(spans: Vec<Span<'static>>, max: usize) -> Line<'static> {
    let mut out = Vec::with_capacity(spans.len());
    let mut used = 0;
    for span in spans {
        let w = width(&span.content);
        if used + w <= max {
            used += w;
            out.push(span);
            continue;
        }
        let rest = max - used;
        if rest > 0 {
            out.push(Span::styled(truncate(&span.content, rest), span.style));
        }
        break;
    }
    Line::from(out)
}

pub fn styled(s: impl Into<String>, style: Style) -> Span<'static> {
    Span::styled(s.into(), style)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncates_by_columns_with_an_ellipsis() {
        assert_eq!(truncate("Přehled příliš žluťoučkých", 16), "Přehled příliš …");
        assert_eq!(truncate("převody", 7), "převody");
        assert_eq!(truncate("převody", 4), "pře…");
        assert_eq!(truncate("abc", 1), "…");
        assert_eq!(truncate("abc", 0), "");
        // Combining marks (decomposed diacritics) stay with their letter and take no column.
        let decomposed = "pr\u{030c}evody";
        assert_eq!(width(&truncate(decomposed, 4)), 4);
        // Wide characters are never split.
        assert_eq!(truncate("日本語テキスト", 6), "日本…");
        assert_eq!(truncate_left("/Users/dev/store-2290", 10), "…tore-2290");
    }

    #[test]
    fn wraps_words_and_splits_long_ones() {
        let title = "Přehled příliš žluťoučkých koní úpějících ďábelské ódy na nádvoří";
        let lines = wrap(title, 20);
        let expected =
            ["Přehled příliš", "žluťoučkých koní", "úpějících ďábelské", "ódy na nádvoří"];
        assert_eq!(lines, expected);
        assert!(lines.iter().all(|l| width(l) <= 20));
        assert_eq!(wrap("abcdefgh", 3), ["abc", "def", "gh"]);
        assert_eq!(wrap("", 5), [""]);
        assert!(wrap("x", 0).is_empty());
    }

    #[test]
    fn pad_and_fit() {
        assert_eq!(pad("ab", 4), "ab  ");
        assert_eq!(pad("abcdef", 4), "abc…");
        let line = fit(vec![Span::raw("12345"), Span::raw("67890"), Span::raw("x")], 8);
        assert_eq!(line.to_string(), "1234567…");
        assert_eq!(fit(vec![Span::raw("ab")], 2).to_string(), "ab");
    }
}
