use super::*;
use crate::theme;
use crate::client::Event;
use crate::protocol::{ServerMessage, Snapshot};
use crate::state::{AppState, Panel};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::buffer::Buffer;
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

fn buffer(st: &AppState, w: u16, h: u16) -> Buffer {
    let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
    terminal.draw(|f| draw(f, st, now())).unwrap();
    terminal.backend().buffer().clone()
}

fn lines(buf: &Buffer) -> Vec<String> {
    let area = buf.area;
    (0..area.height)
        .map(|y| (0..area.width).map(|x| buf[(x, y)].symbol()).collect::<String>())
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
    for key in ["j / k", "1–4", "Tab", "Enter", "J", "/", "r", ",", "?", "q"] {
        assert!(out.contains(key), "missing {key}");
    }
    assert!(out.contains("open the linked Jira ticket"));
    assert!(out.contains("open Settings in the app"));
    // It also fits at the minimum size.
    let small = render(&st, 60, 15);
    assert!(small.contains("Keys"));
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
