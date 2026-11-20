use super::*;
use crate::theme;
use crate::client::Event;
use crate::protocol::{ServerMessage, Snapshot};
use crate::state::{Action, AppState, Panel};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind};
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::buffer::{Buffer, CellDiffOption, CellWidth};
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier};
use std::time::{Duration, SystemTime};

const FIXTURE: &str = include_str!("../../../protocol/fixtures/snapshot-v1.json");
const LONG_TITLE: &str = "Přehled příliš žluťoučkých koní úpějících ďábelské ódy na nádvoří";

/// 2026-11-19T10:01:30Z, 90 s after the fixture's `generatedAt`.
fn now() -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(1_795_082_400 + 90)
}

fn fixture_state() -> AppState {
    let mut st = AppState::new();
    let data = Box::new(serde_json::from_str::<Snapshot>(FIXTURE).unwrap());
    st.apply(ServerMessage::Snapshot { protocol: 1, data });
    st
}

fn press(st: &mut AppState, c: char) {
    st.key(KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE));
}

/// The screen at `w`×`h` and the links on it, as the event loop keeps them.
fn drawn(st: &AppState, w: u16, h: u16) -> (Buffer, Links) {
    let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
    let mut links = Links::default();
    terminal.draw(|f| links = draw(f, st, now())).unwrap();
    (terminal.backend().buffer().clone(), links)
}

fn buffer(st: &AppState, w: u16, h: u16) -> Buffer {
    drawn(st, w, h).0
}

/// The first cell of the visible text `needle` in `area`.
fn cell_of(buf: &Buffer, area: Rect, needle: &str) -> (u16, u16) {
    (area.top()..area.bottom())
        .find_map(|y| {
            let row: String = (area.left()..area.right()).map(|x| link::visible(buf[(x, y)].symbol())).collect();
            row.find(needle).map(|i| (area.x + row[..i].chars().count() as u16, y))
        })
        .unwrap_or_else(|| panic!("no {needle:?} in {:#?}", lines(buf)))
}

/// A mouse event of `kind` at (`x`, `y`) with `modifiers`, handled as the event loop does.
fn mouse(st: &mut AppState, buf: &Buffer, links: &Links, kind: MouseEventKind, modifiers: KeyModifiers, (x, y): (u16, u16)) -> Option<Action> {
    click(buf.area, st, links, MouseEvent { kind, column: x, row: y, modifiers })
}

/// A plain left click at (`x`, `y`).
fn left(st: &mut AppState, buf: &Buffer, links: &Links, at: (u16, u16)) -> Option<Action> {
    mouse(st, buf, links, MouseEventKind::Down(MouseButton::Left), KeyModifiers::NONE, at)
}

/// The text a terminal shows: hyperlink sequences take no room and are left out.
fn lines(buf: &Buffer) -> Vec<String> {
    let area = buf.area;
    (0..area.height)
        .map(|y| (0..area.width).map(|x| link::visible(buf[(x, y)].symbol())).collect::<String>())
        .collect()
}

/// Runs of cells in `area` that link to the same target: (row, visible text, target).
fn link_runs(buf: &Buffer, area: Rect) -> Vec<(u16, String, String)> {
    let mut runs: Vec<(u16, String, String)> = Vec::new();
    for y in area.top()..area.bottom() {
        let mut open: Option<(String, String)> = None;
        for x in area.left()..area.right() {
            let symbol = buf[(x, y)].symbol();
            match (link::target(symbol), &mut open) {
                (Some(url), Some((text, current))) if url == current => text.push_str(&link::visible(symbol)),
                (Some(url), _) => {
                    if let Some((text, url)) = open.take() {
                        runs.push((y, text, url));
                    }
                    open = Some((link::visible(symbol), url.to_string()));
                }
                (None, _) => {
                    if let Some((text, url)) = open.take() {
                        runs.push((y, text, url));
                    }
                }
            }
        }
        if let Some((text, url)) = open {
            runs.push((y, text, url));
        }
    }
    runs
}

fn detail_links(st: &AppState) -> Vec<(String, String)> {
    let buf = buffer(st, 120, 32);
    let d = areas(buf.area, st).unwrap().detail;
    link_runs(&buf, d).into_iter().map(|(_, text, url)| (text.trim_end().to_string(), url)).collect()
}

/// What a terminal shows after it is sent the diff from `prev` to `next`: each cell's visible
/// text is printed at its column and covers as many columns as it is wide.
fn screen_after(prev: &Buffer, next: &Buffer) -> Vec<String> {
    let area = next.area;
    let mut screen = vec![vec![" ".to_string(); usize::from(area.width)]; usize::from(area.height)];
    for (x, y, cell) in prev.diff(next) {
        let shown = link::visible(cell.symbol());
        let row = &mut screen[usize::from(y)];
        let wide = usize::from(shown.as_str().cell_width());
        for i in 1..wide {
            if let Some(c) = row.get_mut(usize::from(x) + i) {
                *c = String::new();
            }
        }
        row[usize::from(x)] = shown;
    }
    screen.into_iter().map(|r| r.concat()).collect()
}

/// The buffer's rows as a terminal shows them: a wide character covers the cells after it.
fn shown(buf: &Buffer) -> Vec<String> {
    (buf.area.top()..buf.area.bottom())
        .map(|y| {
            let mut row = String::new();
            let mut x = buf.area.left();
            while x < buf.area.right() {
                let symbol = link::visible(buf[(x, y)].symbol());
                x += symbol.as_str().cell_width().max(1);
                row.push_str(&symbol);
            }
            row
        })
        .collect()
}

fn state_with(edit: impl FnOnce(&mut Snapshot)) -> AppState {
    let mut s: Snapshot = serde_json::from_str(FIXTURE).unwrap();
    edit(&mut s);
    let mut st = AppState::new();
    st.apply(ServerMessage::Snapshot { protocol: 1, data: Box::new(s) });
    st
}

/// The detail pane's rows, inside its border and padding.
fn detail_rows(st: &AppState, w: u16, h: u16) -> Vec<String> {
    let buf = buffer(st, w, h);
    let d = areas(buf.area, st).unwrap().detail;
    (d.y + 1..d.bottom() - 1)
        .map(|y| (d.x + 2..d.right() - 2).map(|x| link::visible(buf[(x, y)].symbol())).collect())
        .collect()
}

fn render(st: &AppState, w: u16, h: u16) -> String {
    lines(&buffer(st, w, h)).join("\n")
}

#[test]
fn fixture_at_120x32_shows_all_panels() {
    let out = render(&fixture_state(), 120, 32);
    println!("{out}");
    for title in ["[1] My pull requests", "[2] Review requests", "[3] Jira", "[4] Claude Code"] {
        assert!(out.contains(title), "missing {title}");
    }
    assert!(out.contains("waiting for input"));
    assert!(out.contains("#1234"));
    assert!(out.contains("STORE-2290"));
    assert!(out.contains("devpulse"));
}

#[test]
fn detail_shows_the_selected_pr() {
    let out = render(&fixture_state(), 120, 32);
    for label in ["Checks", "Reviews", "Comments", "acmecorp/store #1234"] {
        assert!(out.contains(label), "missing {label}");
    }
    assert!(out.contains("1 approved · 2 pending"));
    assert!(out.contains("3 · last 31m ago"));
    // The PR's Jira ticket is in the snapshot, so its status is shown.
    assert!(out.contains("STORE-2474 · To Do"));
    assert!(out.contains("open in browser"));
}

#[test]
fn detail_follows_the_focused_panel() {
    let mut st = fixture_state();
    press(&mut st, '3');
    let out = render(&st, 120, 32);
    assert!(out.contains("Priority"));
    assert!(out.contains("High"));
    press(&mut st, '4');
    press(&mut st, 'j');
    let out = render(&st, 120, 32);
    assert!(out.contains("permission prompt"));
    assert!(out.contains("/Users/dev/store"));
    press(&mut st, 'j');
    let out = render(&st, 120, 32);
    assert!(out.contains("STORE-2290 · In Progress"));
}

#[test]
fn header_shows_each_source_state() {
    let out = render(&fixture_state(), 120, 32);
    let header = out.lines().next().unwrap();
    assert!(header.contains("GitHub ✓ 2m"), "{header}");
    assert!(header.contains("Jira ✗ returned 401"), "{header}");
    assert!(header.contains("Claude ✓ 1m"), "{header}");
}

#[test]
fn footer_lists_the_keys() {
    let out = render(&fixture_state(), 120, 32);
    let footer = out.lines().last().unwrap();
    assert!(footer.contains("enter open"), "{footer}");
    assert!(footer.contains("? help"), "{footer}");
    assert!(footer.contains("q quit"), "{footer}");
    // At 80 columns the least important hints go first; help and quit stay.
    let narrow = render(&fixture_state(), 80, 24);
    let footer = narrow.lines().last().unwrap();
    assert!(footer.contains("enter open") && footer.contains("q quit"), "{footer}");
}

#[test]
fn narrow_terminal_truncates_the_diacritic_title() {
    let mut st = fixture_state();
    let out = render(&st, 80, 24);
    println!("{out}");
    assert!(!out.contains(LONG_TITLE));
    // The ticket row and the review-request row both cut the title at the panel edge with `…`.
    let ticket = out.lines().find(|l| l.contains("STORE-2290  In Progress")).unwrap();
    assert!(ticket.contains("Přehl…│"), "{ticket}");
    let review = out.lines().find(|l| l.contains("#1250")).unwrap();
    assert!(review.contains("Přehled pří…│"), "{review}");
    // Every panel focused, every size from the minimum up: no panic, never wider than the screen.
    for panel in ['1', '2', '3', '4'] {
        press(&mut st, panel);
        for w in 60..=130 {
            let buf = buffer(&st, w, 24);
            assert_eq!(buf.area.width, w);
        }
        for h in 15..=45 {
            buffer(&st, 80, h);
        }
    }
}

#[test]
fn too_small_terminal_says_so() {
    assert!(render(&fixture_state(), 50, 10).contains("terminal too small"));
    assert!(render(&fixture_state(), 59, 20).contains("terminal too small"));
    assert!(render(&fixture_state(), 80, 14).contains("terminal too small"));
    assert!(!render(&fixture_state(), 60, 15).contains("terminal too small"));
    for (w, h) in [(0, 0), (1, 1), (5, 2), (20, 3)] {
        buffer(&fixture_state(), w, h);
    }
}

#[test]
fn disconnected_shows_the_banner_and_keeps_the_data() {
    let mut st = fixture_state();
    st.on_event(Event::Disconnected);
    let out = render(&st, 120, 32);
    assert!(out.contains("disconnected — reconnecting…"));
    assert!(out.contains("[1] My pull requests"));
    assert!(out.contains("#1234"));
}

#[test]
fn before_the_first_snapshot_it_says_connecting() {
    let out = render(&AppState::new(), 120, 32);
    assert!(out.contains("connecting…"));
    assert!(out.contains("[4] Claude Code"));
}

#[test]
fn help_overlay_lists_every_key() {
    let mut st = fixture_state();
    press(&mut st, '?');
    let out = render(&st, 120, 32);
    for key in ["j / k", "1–4", "Tab", "Enter", "J", "/", "r", ",", "?", "q", "click / ⌘-click"] {
        assert!(out.contains(key), "missing {key}");
    }
    assert!(out.contains("open the linked Jira ticket"));
    assert!(out.contains("open Settings in the app"));
    assert!(out.contains("click / ⌘-click      open an underlined link in the browser"), "{out}");
    assert!(!out.contains("⇧⌘"), "{out}");
    // It also fits at the minimum size, every row and both borders included.
    let small = render(&st, 60, 15);
    assert!(small.contains("Keys"));
    assert!(small.contains("click / ⌘-click"), "{small}");
    assert!(small.contains("esc close"), "{small}");
}

#[test]
fn filter_shows_in_the_footer() {
    let mut st = fixture_state();
    for c in "/tidy".chars() {
        press(&mut st, c);
    }
    let out = render(&st, 120, 32);
    assert!(out.lines().last().unwrap().contains("/tidy"));
    assert!(!out.contains("#1234"));
    assert!(out.contains("#7"));
}

#[test]
fn empty_panels_show_a_placeholder() {
    let mut s: Snapshot = serde_json::from_str(FIXTURE).unwrap();
    s.review_requests.clear();
    s.tickets.clear();
    s.sources.jira.state = crate::protocol::SourceState::Ok;
    let mut st = AppState::new();
    st.apply(ServerMessage::Snapshot { protocol: 1, data: Box::new(s) });
    let out = render(&st, 120, 32);
    assert!(out.contains("No review requests"));
    assert!(out.contains("No tickets"));
    // A failing source with nothing to show points at the header instead.
    let mut s: Snapshot = serde_json::from_str(FIXTURE).unwrap();
    s.tickets.clear();
    let mut st = AppState::new();
    st.apply(ServerMessage::Snapshot { protocol: 1, data: Box::new(s) });
    assert!(render(&st, 120, 32).contains("Jira unavailable — see the header"));
}

#[test]
fn colors_are_ansi_named_and_the_focused_border_is_cyan_bold() {
    let st = fixture_state();
    let buf = buffer(&st, 120, 32);
    for cell in buf.content() {
        for c in [cell.fg, cell.bg] {
            assert!(!matches!(c, Color::Rgb(..) | Color::Indexed(_)), "{c:?}");
        }
    }
    let a = areas(buf.area, &st).unwrap();
    let corner = &buf[(a.panels[0].x, a.panels[0].y)];
    assert_eq!(corner.symbol(), "╭");
    assert_eq!(corner.fg, Color::Cyan);
    assert!(corner.modifier.contains(Modifier::BOLD));
    let other = &buf[(a.panels[1].x, a.panels[1].y)];
    assert_eq!(other.symbol(), "╭");
    assert_ne!(other.fg, Color::Cyan);
}

#[test]
fn status_icons_have_their_colors() {
    let st = fixture_state();
    let buf = buffer(&st, 120, 32);
    // The session icons, in the Claude Code panel (review requests use ● and ○ too).
    let claude = areas(buf.area, &st).unwrap().panels[3];
    let find = |sym: &str| {
        (claude.y..claude.bottom())
            .flat_map(|y| (claude.x..claude.right()).map(move |x| (x, y)))
            .map(|p| buf[p].clone())
            .find(|c| c.symbol() == sym)
            .unwrap()
    };
    assert_eq!(find("◐").fg, Color::Yellow);
    let waiting = find("●");
    assert_eq!(waiting.fg, Color::Red);
    assert!(waiting.modifier.contains(Modifier::BOLD));
    assert!(find("○").modifier.contains(Modifier::DIM));
    assert_eq!(buf.content().iter().find(|c| c.symbol() == "✗").unwrap().fg, Color::Red);
}

#[test]
fn the_focused_panel_gets_the_spare_rows() {
    // 4 panels in 20 rows; content needs 4, 4, 4, 5 rows (items + borders).
    assert_eq!(panel_heights(20, [2, 2, 2, 3], Panel::MyPrs), [7, 4, 4, 5]);
    assert_eq!(panel_heights(20, [2, 2, 2, 3], Panel::Claude), [4, 4, 4, 8]);
    // Too little room: every panel keeps one row, the focused one fills up first.
    assert_eq!(panel_heights(14, [9, 9, 9, 9], Panel::Jira), [3, 3, 5, 3]);
    assert_eq!(panel_heights(13, [0, 0, 0, 0], Panel::MyPrs), [4, 3, 3, 3]);
    assert_eq!(panel_heights(6, [1, 1, 1, 1], Panel::MyPrs).iter().sum::<u16>(), 6);
}

#[test]
fn a_cut_off_detail_pane_ends_with_an_ellipsis_row() {
    let st = fixture_state();
    let buf = buffer(&st, 120, 16);
    let d = areas(buf.area, &st).unwrap().detail;
    let row = |y: u16| (d.x + 1..d.right() - 1).map(|x| buf[(x, y)].symbol()).collect::<String>();
    let last = d.bottom() - 2;
    assert_eq!(row(last).trim(), "…", "{}", render(&st, 120, 16));
    assert!(row(last - 1).trim().len() > 1);
    // When everything fits there is no ellipsis row.
    let buf = buffer(&st, 120, 32);
    let d = areas(buf.area, &st).unwrap().detail;
    let rows: Vec<String> = (d.y + 1..d.bottom() - 1)
        .map(|y| (d.x + 1..d.right() - 1).map(|x| buf[(x, y)].symbol()).collect())
        .collect();
    assert!(rows.iter().all(|r| r.trim() != "…"));
}

#[test]
fn the_selected_row_is_highlighted_only_in_the_focused_panel() {
    let st = fixture_state();
    let buf = buffer(&st, 120, 32);
    let a = areas(buf.area, &st).unwrap();
    let focused = a.panels[0];
    let y = focused.y + 1;
    assert_eq!(buf[(focused.x + 2, y)].symbol(), "▶");
    for x in focused.x + 1..focused.right() - 1 {
        assert_eq!(buf[(x, y)].bg, theme::SELECTED_BG, "x={x}");
    }
    assert_ne!(buf[(focused.x + 2, y + 1)].bg, theme::SELECTED_BG);
    // Unfocused panels mark their selection with ▶ only.
    let claude = a.panels[3];
    assert_eq!(buf[(claude.x + 2, claude.y + 1)].symbol(), "▶");
    for x in claude.x + 1..claude.right() - 1 {
        assert_ne!(buf[(x, claude.y + 1)].bg, theme::SELECTED_BG, "x={x}");
    }
}

#[test]
fn the_footer_shows_a_notice() {
    let mut st = fixture_state();
    st.notice = Some("not connected — action not sent".into());
    let out = render(&st, 120, 32);
    let footer = out.lines().last().unwrap();
    assert!(footer.contains("not connected — action not sent"), "{footer}");
    assert!(footer.contains("q quit"), "{footer}");
}

#[test]
fn clicks_map_to_rows() {
    let st = fixture_state();
    let area = ratatui::layout::Rect::new(0, 0, 120, 32);
    let a = areas(area, &st).unwrap();
    let claude = a.panels[3];
    assert_eq!(hit_test(area, &st, claude.x + 4, claude.y + 2), Some((Panel::Claude, Some(1))));
    assert_eq!(hit_test(area, &st, claude.x + 4, claude.y), Some((Panel::Claude, None)));
    assert_eq!(hit_test(area, &st, a.detail.x + 3, a.detail.y + 3), None);
    assert_eq!(hit_test(area, &st, 3, 0), None);
}

#[test]
fn long_lists_scroll_to_keep_the_selection_visible() {
    assert_eq!(list_offset(0, 10, 3), 0);
    assert_eq!(list_offset(2, 10, 3), 0);
    assert_eq!(list_offset(3, 10, 3), 1);
    assert_eq!(list_offset(9, 10, 3), 7);
    assert_eq!(list_offset(0, 0, 0), 0);
}

#[test]
fn review_rows_mark_direct_and_team_requests() {
    let buf = buffer(&fixture_state(), 120, 32);
    let st = fixture_state();
    let a = areas(buf.area, &st).unwrap();
    let reviews = a.panels[1];
    let row = |y: u16| (reviews.x + 1..reviews.right() - 1).map(|x| buf[(x, y)].symbol()).collect::<String>();
    let mark = |y: u16| {
        (reviews.x + 1..reviews.right() - 1)
            .map(|x| buf[(x, y)].clone())
            .find(|c| c.symbol() == "●" || c.symbol() == "○")
            .unwrap_or_else(|| panic!("no mark in {}", row(y)))
    };
    // #1250 is requested from me directly, #88 from one of my teams.
    let direct = (reviews.y + 1..reviews.bottom()).find(|&y| row(y).contains("#1250")).unwrap();
    let team = (reviews.y + 1..reviews.bottom()).find(|&y| row(y).contains("#88")).unwrap();
    assert_eq!(mark(direct).symbol(), "●", "{}", row(direct));
    assert_eq!(mark(direct).fg, Color::Yellow);
    assert_eq!(mark(team).symbol(), "○", "{}", row(team));
    assert!(mark(team).modifier.contains(Modifier::DIM));
    // My own pull requests carry no mark.
    let mine = a.panels[0];
    let first = (mine.x + 1..mine.right() - 1).map(|x| buf[(x, mine.y + 1)].symbol()).collect::<String>();
    assert!(!first.contains('●') && !first.contains('○'), "{first}");
}

#[test]
fn a_session_with_a_key_offers_j() {
    let mut st = fixture_state();
    press(&mut st, '4');
    press(&mut st, 'j');
    press(&mut st, 'j');
    let out = render(&st, 120, 32);
    assert!(out.lines().last().unwrap().contains("J jira"), "{out}");
    assert!(out.contains("open Jira ticket"), "{out}");
    // Without a key neither the hint nor the detail line shows.
    press(&mut st, 'k');
    let out = render(&st, 120, 32);
    assert!(!out.lines().last().unwrap().contains("J jira"));
    assert!(!out.contains("open Jira ticket"));
}

#[test]
fn the_footer_and_the_header_show_refreshing_and_the_upgrade_result() {
    let mut st = fixture_state();
    st.refresh_sent(std::time::Instant::now());
    let out = render(&st, 120, 32);
    assert!(out.lines().last().unwrap().contains("refreshing…"), "{out}");
    st.apply(ServerMessage::Upgrade { phase: crate::protocol::UpgradePhase::UpToDate, progress: None, message: None });
    assert!(render(&st, 120, 32).lines().next().unwrap().contains("up to date"));
}

#[test]
fn pr_detail_shows_the_ticket_status_and_its_related_tickets() {
    let out = render(&fixture_state(), 120, 32);
    println!("{out}");
    assert!(out.contains("STORE-2474 · To Do"));
    let rows = detail_rows(&fixture_state(), 120, 32);
    let at = rows.iter().position(|r| r.trim() == "Related").expect("a Related section");
    // One row per link: relation, key, status, summary, in columns, cut at the pane edge.
    let blocked = &rows[at + 1];
    assert!(blocked.starts_with("  is blocked by  STORE-2290  In Progress  Přehled"), "{blocked}");
    assert!(blocked.ends_with('…'), "{blocked}");
    assert_eq!(blocked.as_str().cell_width() as usize, rows[0].as_str().cell_width() as usize);
    let relates = &rows[at + 2];
    assert!(relates.starts_with("  relates to     STORE-2101  Done         Invoice"), "{relates}");
    // The section sits before the recent comments.
    let comments = rows.iter().position(|r| r.trim() == "Recent comments").unwrap();
    assert!(at < comments);
}

#[test]
fn related_statuses_have_their_colors() {
    let st = fixture_state();
    let buf = buffer(&st, 120, 32);
    let d = areas(buf.area, &st).unwrap().detail;
    // The first cell of `word` in a detail row.
    let cell_of = |word: &str| {
        let needle = format!("  {word}  ");
        let (y, col) = (d.y..d.bottom())
            .find_map(|y| {
                let row: String = (d.x..d.right()).map(|x| link::visible(buf[(x, y)].symbol())).collect();
                row.find(&needle).map(|i| (y, row[..i + 2].chars().count() as u16))
            })
            .unwrap();
        buf[(d.x + col, y)].clone()
    };
    assert_eq!(cell_of("In Progress").fg, Color::Yellow);
    assert_eq!(cell_of("Done").fg, Color::Green);
}

#[test]
fn a_pr_whose_ticket_is_not_mine_uses_the_linked_tickets() {
    let mut st = fixture_state();
    press(&mut st, '2');
    press(&mut st, 'j');
    let out = render(&st, 120, 32);
    println!("{out}");
    assert!(out.contains("#88"));
    assert!(out.contains("WEB-77 · In Review"), "{out}");
    assert!(out.contains("  is caused by  WEB-70  Done  Column sorting"), "{out}");
}

#[test]
fn ticket_detail_shows_its_related_tickets() {
    let mut st = fixture_state();
    press(&mut st, '3');
    let out = render(&st, 120, 32);
    println!("{out}");
    assert!(out.contains("Related"));
    // Columns as wide as their widest entry: relation, key, status, then the summary.
    assert!(out.contains("  blocks         STORE-2474  To Do      Replace invoice order"), "{out}");
    assert!(out.contains("  is blocked by  PAY-310     In Review  Payment gateway"), "{out}");
}

#[test]
fn without_links_there_is_no_related_section() {
    let mut st = state_with(|s| {
        for t in &mut s.tickets {
            t.related.clear();
        }
    });
    assert!(!render(&st, 120, 32).contains("Related"));
    press(&mut st, '3');
    assert!(!render(&st, 120, 32).contains("Related"));
}

#[test]
fn pr_detail_rows_are_hyperlinks() {
    let links = detail_links(&fixture_state());
    let pr = "https://github.com/acmecorp/store/pull/1234".to_string();
    let jira = "https://example.atlassian.net/browse/".to_string();
    for want in [
        ("acmecorp/store #1234".to_string(), pr.clone()),
        ("STORE-2474 Replace invoice order".into(), pr.clone()),
        // Only the key, not the label or the status.
        ("STORE-2474".into(), format!("{jira}STORE-2474")),
        (
            "feature/STORE-2474-replace-invoice".into(),
            "https://github.com/acmecorp/store/tree/feature/STORE-2474-replace-invoice".into(),
        ),
    ] {
        assert!(links.contains(&want), "missing {want:?} in {links:#?}");
    }
    // A related row links from its relation to the end of the (cut) summary.
    let relates = links.iter().find(|(_, url)| url.ends_with("STORE-2101")).unwrap();
    assert!(relates.0.starts_with("relates to     STORE-2101  Done") && relates.0.ends_with('…'), "{relates:?}");
    let blocked = links.iter().find(|(_, url)| url.ends_with("STORE-2290")).unwrap();
    assert!(blocked.0.starts_with("is blocked by  STORE-2290"), "{blocked:?}");
    // Labels, the checks and the hints are plain text.
    assert!(links.iter().all(|(text, _)| !text.contains("Jira") && !text.contains("Checks")));
}

#[test]
fn a_fork_branch_links_into_the_head_repository() {
    let mut st = fixture_state();
    press(&mut st, '2');
    let links = detail_links(&st);
    let want = (
        "feature/STORE-2290-prehled".to_string(),
        "https://github.com/alice-dev/store/tree/feature/STORE-2290-prehled".to_string(),
    );
    assert!(links.contains(&want), "{links:#?}");
    // Without a head repository the branch is looked up in the base repository.
    let mut st = state_with(|s| s.review_requests[0].head_repo = None);
    press(&mut st, '2');
    let links = detail_links(&st);
    assert!(links.iter().any(|(_, url)| url == "https://github.com/acmecorp/store/tree/feature/STORE-2290-prehled"));
}

#[test]
fn ticket_and_session_details_link_to_jira() {
    let mut st = fixture_state();
    press(&mut st, '3');
    let links = detail_links(&st);
    let url = "https://example.atlassian.net/browse/STORE-2290".to_string();
    assert!(links.contains(&("STORE-2290".to_string(), url.clone())), "{links:#?}");
    assert!(links.iter().any(|(text, u)| text.starts_with("Přehled příliš") && *u == url), "{links:#?}");
    assert!(links.iter().any(|(text, u)| text.starts_with("blocks") && u.ends_with("/browse/STORE-2474")));
    assert!(links.iter().any(|(text, u)| text.starts_with("is blocked by  PAY-310") && u.ends_with("/browse/PAY-310")));
    press(&mut st, '4');
    press(&mut st, 'j');
    press(&mut st, 'j');
    assert!(detail_links(&st).contains(&("STORE-2290".to_string(), url)));
}

#[test]
fn without_a_jira_site_keys_of_unknown_tickets_are_plain() {
    let st = state_with(|s| {
        s.jira_base_url = None;
        s.tickets.clear();
    });
    let links = detail_links(&st);
    assert!(links.iter().all(|(_, url)| !url.contains("/browse/")), "{links:#?}");
    assert!(links.iter().any(|(_, url)| url.ends_with("/pull/1234")));
}

#[test]
fn links_take_no_columns() {
    let mut ticket = fixture_state();
    press(&mut ticket, '3');
    let wide = state_with(|s| s.my_pull_requests[0].title = "日本語のタイトル STORE-2474 příliš".into());
    for st in [fixture_state(), ticket, wide] {
        for (w, h) in [(120, 32), (80, 24), (60, 15)] {
            let buf = buffer(&st, w, h);
            assert!(buf.content().iter().any(|c| link::target(c.symbol()).is_some()));
            // Every linked cell is exactly as wide as the text it shows.
            for cell in buf.content() {
                if link::target(cell.symbol()).is_some() {
                    let shown = link::visible(cell.symbol());
                    assert_eq!(cell.cell_width(), shown.as_str().cell_width(), "{shown:?}");
                }
            }
            // So a terminal that is sent the diff shows exactly the text without links: every
            // cell lands in its column, none is skipped, and no wide character is overwritten.
            let mut plain = buf.clone();
            for cell in &mut plain.content {
                let shown = link::visible(cell.symbol());
                cell.set_symbol(&shown).set_diff_option(CellDiffOption::None);
            }
            let empty = Buffer::empty(buf.area);
            assert_eq!(screen_after(&empty, &buf), screen_after(&empty, &plain), "{w}×{h}");
            assert_eq!(screen_after(&empty, &plain), shown(&plain), "{w}×{h}");
            // And an unchanged frame sends nothing.
            assert!(buf.diff(&buf).is_empty());
        }
    }
}

#[test]
fn the_terminal_receives_osc8_around_the_text() {
    use ratatui::backend::CrosstermBackend;
    use ratatui::{TerminalOptions, Viewport};
    use std::cell::RefCell;
    use std::io::Write;
    use std::rc::Rc;
    /// Keeps what the backend writes, readable after the draw.
    #[derive(Clone, Default)]
    struct Shared(Rc<RefCell<Vec<u8>>>);
    impl Write for Shared {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.borrow_mut().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let st = fixture_state();
    let written = Shared::default();
    let options = TerminalOptions { viewport: Viewport::Fixed(Rect::new(0, 0, 120, 32)) };
    let mut terminal = Terminal::with_options(CrosstermBackend::new(written.clone()), options).unwrap();
    terminal.draw(|f| {
        draw(f, &st, now());
    })
    .unwrap();
    let out = String::from_utf8(written.0.borrow().clone()).unwrap();
    let jira = "https://example.atlassian.net/browse/STORE-2474";
    let start = out.find(&format!(";{jira}\x1b\\S")).expect("no OSC 8 for the Jira key");
    let open = &out[out[..start].rfind("\x1b]8;id=").unwrap()..start + jira.len() + 3];
    let close = "\x1b]8;;\x1b\\";
    // Each cell of the key is wrapped on its own: open with the row's id, one character, close.
    assert!(out.contains(&format!("{open}S{close}{open}T{close}")), "{open:?}");
    assert!(out.contains(";https://github.com/acmecorp/store/pull/1234\x1b\\"));
}

#[test]
fn narrow_detail_still_cuts_related_rows_with_an_ellipsis() {
    for (w, h) in [(80, 32), (60, 30)] {
        let rows = detail_rows(&fixture_state(), w, h);
        let room = rows[0].as_str().cell_width();
        for row in &rows {
            assert_eq!(row.as_str().cell_width(), room, "{row:?}");
        }
        let at = rows.iter().position(|r| r.trim() == "Related").expect("a Related section");
        assert!(rows[at + 1].trim_end().ends_with('…'), "{:?}", rows[at + 1]);
        assert!(rows[at + 2].trim_end().ends_with('…'), "{:?}", rows[at + 2]);
    }
}

#[test]
fn a_click_on_a_link_opens_its_url() {
    let jira = "https://example.atlassian.net/browse/";
    // The key that heads a ticket's detail, anywhere on it, and a Related row from its relation
    // to its summary. Neither moves the focus or the selection.
    let mut st = fixture_state();
    press(&mut st, '3');
    let (buf, links) = drawn(&st, 120, 32);
    let d = areas(buf.area, &st).unwrap().detail;
    let before = (st.focus, st.selected);
    let (x, y) = cell_of(&buf, d, "STORE-2290");
    for dx in [0, 9] {
        assert_eq!(left(&mut st, &buf, &links, (x + dx, y)), Some(Action::OpenUrl(format!("{jira}STORE-2290"))));
    }
    for text in ["is blocked by  PAY-310", "Payment gateway"] {
        let at = cell_of(&buf, d, text);
        assert_eq!(left(&mut st, &buf, &links, at), Some(Action::OpenUrl(format!("{jira}PAY-310"))), "{text}");
    }
    assert_eq!((st.focus, st.selected), before);
    // The pull request's branch, up to its last character.
    let mut st = fixture_state();
    let (buf, links) = drawn(&st, 120, 32);
    let d = areas(buf.area, &st).unwrap().detail;
    let branch = "feature/STORE-2474-replace-invoice";
    let (x, y) = cell_of(&buf, d, branch);
    let url = "https://github.com/acmecorp/store/tree/feature/STORE-2474-replace-invoice";
    let last = x + branch.len() as u16 - 1;
    for at in [(x, y), (last, y)] {
        assert_eq!(left(&mut st, &buf, &links, at), Some(Action::OpenUrl(url.into())), "{at:?}");
    }
    assert_eq!(left(&mut st, &buf, &links, (last + 1, y)), None);
}

#[test]
fn a_click_with_a_modifier_opens_the_link_too() {
    // Ghostty sends ⌘-click as a plain click (SGR has no bit for ⌘), and sometimes with the
    // alt (meta) or ctrl bit set: every one of them opens the link.
    let mut st = fixture_state();
    let (buf, links) = drawn(&st, 120, 32);
    let a = areas(buf.area, &st).unwrap();
    let key = cell_of(&buf, a.detail, "STORE-2474 · To Do");
    let url = "https://example.atlassian.net/browse/STORE-2474";
    let press_left = MouseEventKind::Down(MouseButton::Left);
    for mods in [
        KeyModifiers::NONE,
        KeyModifiers::SUPER,
        KeyModifiers::META,
        KeyModifiers::ALT,
        KeyModifiers::CONTROL,
        KeyModifiers::ALT | KeyModifiers::CONTROL,
        KeyModifiers::SHIFT,
    ] {
        assert_eq!(mouse(&mut st, &buf, &links, press_left, mods, key), Some(Action::OpenUrl(url.into())), "{mods:?}");
    }
    // A modified click on a panel row still selects it.
    let claude = a.panels[3];
    assert_eq!(mouse(&mut st, &buf, &links, press_left, KeyModifiers::CONTROL, (claude.x + 4, claude.y + 2)), None);
    assert_eq!((st.focus, st.selected[3]), (Panel::Claude, 1));
    // Only a left press clicks: a release, the right button or the wheel over a link do nothing.
    let mut st = fixture_state();
    for kind in [
        MouseEventKind::Up(MouseButton::Left),
        MouseEventKind::Down(MouseButton::Right),
        MouseEventKind::Down(MouseButton::Middle),
        MouseEventKind::ScrollDown,
    ] {
        assert_eq!(mouse(&mut st, &buf, &links, kind, KeyModifiers::NONE, key), None, "{kind:?}");
        assert_eq!(mouse(&mut st, &buf, &links, kind, KeyModifiers::NONE, (claude.x + 4, claude.y + 2)), None);
    }
    assert_eq!((st.focus, st.selected[3]), (Panel::MyPrs, 0));
}

#[test]
fn a_click_beside_a_link_keeps_selecting() {
    let mut st = fixture_state();
    let (buf, links) = drawn(&st, 120, 32);
    let a = areas(buf.area, &st).unwrap();
    // A label before a link, plain values and the hints open nothing and change nothing.
    for text in ["Branch", "Jira      ", "1 approved", "open in browser"] {
        let at = cell_of(&buf, a.detail, text);
        assert_eq!(left(&mut st, &buf, &links, at), None, "{text}");
    }
    assert_eq!((st.focus, st.selected), (Panel::MyPrs, [0; 4]));
    // A row of a panel is focused and selected as before, the header and footer do nothing.
    let claude = a.panels[3];
    assert_eq!(left(&mut st, &buf, &links, (claude.x + 4, claude.y + 2)), None);
    assert_eq!((st.focus, st.selected[3]), (Panel::Claude, 1));
    assert_eq!(left(&mut st, &buf, &links, (3, 0)), None);
    assert_eq!(left(&mut st, &buf, &links, (3, 31)), None);
    assert_eq!((st.focus, st.selected[3]), (Panel::Claude, 1));
    // With the help open a click on a link only closes the help.
    let mut st = fixture_state();
    let (buf, links) = drawn(&st, 120, 32);
    let key = cell_of(&buf, areas(buf.area, &st).unwrap().detail, "STORE-2474 · To Do");
    press(&mut st, '?');
    assert_eq!(left(&mut st, &buf, &links, key), None);
    assert!(!st.show_help);
}

#[test]
fn only_web_links_are_clickable_and_underlined() {
    let mut st = state_with(|s| s.tickets[0].url = "file:///System/Applications/Calculator.app".into());
    press(&mut st, '3');
    let (buf, links) = drawn(&st, 120, 32);
    let d = areas(buf.area, &st).unwrap().detail;
    let (x, y) = cell_of(&buf, d, "STORE-2290");
    assert_eq!(left(&mut st, &buf, &links, (x, y)), None);
    assert!(links.iter().all(|(_, url)| url.starts_with("https://")), "{links:?}");
    assert!(!buf[(x, y)].modifier.contains(Modifier::UNDERLINED));
    // The web links of the same detail are underlined, and only their text.
    let (x, y) = cell_of(&buf, d, "is blocked by  PAY-310");
    assert!(buf[(x, y)].modifier.contains(Modifier::UNDERLINED));
    assert!(!buf[(x - 1, y)].modifier.contains(Modifier::UNDERLINED));
    let st = fixture_state();
    let buf = buffer(&st, 120, 32);
    let d = areas(buf.area, &st).unwrap().detail;
    let (x, y) = cell_of(&buf, d, "STORE-2474 · To Do");
    for (dx, underlined) in [(0, true), (9, true), (10, false), (13, false)] {
        assert_eq!(buf[(x + dx, y)].modifier.contains(Modifier::UNDERLINED), underlined, "x+{dx}");
    }
    let (x, y) = cell_of(&buf, d, "Jira");
    assert!(!buf[(x, y)].modifier.contains(Modifier::UNDERLINED));
    // Outside the detail pane nothing is underlined.
    let a = areas(buf.area, &st).unwrap();
    for r in [a.header, a.panels[0], a.panels[2], a.footer] {
        for p in r.positions() {
            assert!(!buf[p].modifier.contains(Modifier::UNDERLINED), "{p:?}");
        }
    }
}

#[test]
fn link_regions_are_rebuilt_on_every_draw() {
    let mut st = fixture_state();
    let (buf, links) = drawn(&st, 120, 32);
    let d = areas(buf.area, &st).unwrap().detail;
    let old = "https://github.com/acmecorp/store/tree/feature/STORE-2474-replace-invoice";
    let branch = cell_of(&buf, d, "feature/STORE-2474");
    assert_eq!(links.at(branch.0, branch.1), Some(old));
    // Each region lies where the terminal gets the same link through OSC 8.
    assert!(links.iter().count() >= 6, "{links:?}");
    for (rect, url) in links.iter() {
        assert!(d.contains(rect.as_position()) && rect.height == 1, "{rect:?}");
        for p in rect.positions() {
            assert_eq!(link::target(buf[p].symbol()), Some(url), "{p:?}");
        }
    }
    // The next pull request: none of the first one's links is left.
    press(&mut st, 'j');
    let (buf, links) = drawn(&st, 120, 32);
    assert!(links.iter().all(|(_, url)| !url.contains("1234") && url != old), "{links:?}");
    let branch = cell_of(&buf, d, "chore/build-script");
    assert_eq!(links.at(branch.0, branch.1), Some("https://github.com/jiripisa/devpulse/tree/chore/build-script"));
    // Another panel, the help or a screen too small: no stale links either.
    press(&mut st, '4');
    let (_, links) = drawn(&st, 120, 32);
    assert!(links.iter().all(|(_, url)| url.contains("/browse/")), "{links:?}");
    assert_eq!(drawn(&st, 50, 10).1, Links::default());
}
