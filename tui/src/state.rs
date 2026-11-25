//! Pure UI state: the latest snapshot, focus, selection, filter and key handling.

use crate::client::Event;
use crate::protocol::{
    ClaudeSession, ClientMessage, OpenKind, PullRequest, ServerMessage, Snapshot, Ticket, UpgradePhase,
};
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use std::time::{Duration, Instant};

/// How long a key bar notice stays when no key or click clears it first.
pub const NOTICE: Duration = Duration::from_secs(3);
/// The longest `refreshing…` stays when no snapshot arrives (nothing changed, or the app was busy).
pub const REFRESH_NOTICE: Duration = Duration::from_secs(10);
/// How long a final upgrade phase (up to date, failed) stays in the header.
pub const UPGRADE_STATUS: Duration = Duration::from_secs(10);
pub const REFRESHING: &str = "refreshing…";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Panel {
    MyPrs,
    Reviews,
    Jira,
    Claude,
    /// The tickets I created in the watched statuses; shown only while that view is on.
    Created,
}

/// How many panels there are, shown or not.
pub const PANELS: usize = 5;

impl Panel {
    pub const ALL: [Panel; PANELS] = [Panel::MyPrs, Panel::Reviews, Panel::Jira, Panel::Claude, Panel::Created];

    pub fn index(self) -> usize {
        self as usize
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Quit,
    Send(ClientMessage),
    /// Open this web link in the browser: a click on a link in the detail.
    OpenUrl(String),
}

/// The last `upgrade` message from the app, for the status line.
#[derive(Debug, Clone, PartialEq)]
pub struct UpgradeStatus {
    pub phase: UpgradePhase,
    pub progress: Option<f64>,
    pub message: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AppState {
    pub snapshot: Option<Snapshot>,
    pub connected: bool,
    pub focus: Panel,
    /// Selected row per panel, as an index into the visible (filtered) items.
    pub selected: [usize; PANELS],
    pub filter: Option<String>,
    /// True while the user is typing the filter after `/`.
    pub filter_editing: bool,
    pub show_help: bool,
    pub upgrade: Option<UpgradeStatus>,
    /// True from a lost connection until the next snapshot; the old snapshot stays shown.
    pub reconnecting: bool,
    /// A short note in the key bar (e.g. an action that could not be sent); the next key or
    /// click clears it, and `expire` clears it at `notice_until`.
    pub notice: Option<String>,
    notice_until: Option<Instant>,
    /// The notice is `refreshing…`: the next snapshot clears it.
    refreshing: bool,
    /// When a final upgrade phase leaves the header.
    upgrade_until: Option<Instant>,
}

impl Default for AppState {
    fn default() -> Self {
        Self::new()
    }
}

impl AppState {
    pub fn new() -> Self {
        AppState {
            snapshot: None,
            connected: false,
            focus: Panel::MyPrs,
            selected: [0; PANELS],
            filter: None,
            filter_editing: false,
            show_help: false,
            upgrade: None,
            reconnecting: false,
            notice: None,
            notice_until: None,
            refreshing: false,
            upgrade_until: None,
        }
    }

    pub fn on_event(&mut self, event: Event) {
        match event {
            Event::Server(msg) => self.apply(msg),
            Event::Disconnected => {
                self.connected = false;
                self.reconnecting = true;
            }
        }
    }

    pub fn apply(&mut self, msg: ServerMessage) {
        self.apply_at(msg, Instant::now());
    }

    /// Applies a server message that arrived at `now`. A new snapshot keeps each panel's
    /// selection on the same item ID when it is still present, otherwise on the same index,
    /// clamped, and ends a `refreshing…` notice. The first snapshot after a reconnect clears the
    /// upgrade status (the app restarted), unless the upgrade failed. A final upgrade phase
    /// leaves the header after `UPGRADE_STATUS`.
    pub fn apply_at(&mut self, msg: ServerMessage, now: Instant) {
        match msg {
            ServerMessage::Snapshot { data, .. } => {
                let before = self.selected_ids();
                self.snapshot = Some(*data);
                if self.reconnecting
                    && self.upgrade.as_ref().is_some_and(|u| u.phase != UpgradePhase::Failed)
                {
                    self.clear_upgrade();
                }
                self.connected = true;
                self.reconnecting = false;
                self.restore_selection(&before);
                if !self.shown(self.focus) {
                    self.focus = Panel::Jira;
                }
                if self.refreshing {
                    self.clear_notice();
                }
            }
            ServerMessage::Upgrade { phase, progress, message } => {
                let fin = matches!(phase, UpgradePhase::UpToDate | UpgradePhase::Failed);
                self.upgrade_until = fin.then(|| now + UPGRADE_STATUS);
                self.upgrade = Some(UpgradeStatus { phase, progress, message });
            }
            ServerMessage::Unknown => {}
        }
    }

    /// Shows `text` in the key bar until `until`, the next key or click.
    pub fn show_notice(&mut self, text: impl Into<String>, until: Instant) {
        self.notice = Some(text.into());
        self.notice_until = Some(until);
        self.refreshing = false;
    }

    /// `r` went out at `now`: `refreshing…` until the next snapshot, at most `REFRESH_NOTICE`.
    pub fn refresh_sent(&mut self, now: Instant) {
        self.show_notice(REFRESHING, now + REFRESH_NOTICE);
        self.refreshing = true;
    }

    /// The next moment `expire` has something to do: the only timed wakes the state needs.
    pub fn next_expiry(&self) -> Option<Instant> {
        [self.notice_until, self.upgrade_until].into_iter().flatten().min()
    }

    /// Drops the notice and the upgrade status whose time is up at `now`; true when the screen
    /// changed.
    pub fn expire(&mut self, now: Instant) -> bool {
        let mut changed = false;
        if self.notice_until.is_some_and(|t| now >= t) {
            self.clear_notice();
            changed = true;
        }
        if self.upgrade_until.is_some_and(|t| now >= t) {
            self.clear_upgrade();
            changed = true;
        }
        changed
    }

    fn clear_notice(&mut self) {
        self.notice = None;
        self.notice_until = None;
        self.refreshing = false;
    }

    fn clear_upgrade(&mut self) {
        self.upgrade = None;
        self.upgrade_until = None;
    }

    fn matches(&self, fields: &[&str]) -> bool {
        match self.filter.as_deref().filter(|f| !f.is_empty()) {
            None => true,
            Some(f) => {
                let needle = f.to_lowercase();
                fields.iter().any(|field| field.to_lowercase().contains(&needle))
            }
        }
    }

    /// Whether `panel` is on screen: all are, but `Created` only while the app watches statuses.
    pub fn shown(&self, panel: Panel) -> bool {
        panel != Panel::Created
            || self.snapshot.as_ref().is_some_and(|s| !s.created_ticket_statuses.is_empty())
    }

    /// The shown panel after (`step` 1) or before (`step` -1) the focused one, wrapping.
    fn cycle(&self, step: isize) -> Panel {
        let shown: Vec<Panel> = Panel::ALL.into_iter().filter(|p| self.shown(*p)).collect();
        let at = shown.iter().position(|p| *p == self.focus).unwrap_or(0);
        shown[(at as isize + step).rem_euclid(shown.len() as isize) as usize]
    }

    /// Pull requests shown in `MyPrs` or `Reviews` (after the filter); empty for other panels.
    pub fn visible_prs(&self, panel: Panel) -> Vec<&PullRequest> {
        let Some(s) = &self.snapshot else { return Vec::new() };
        let list = match panel {
            Panel::MyPrs => &s.my_pull_requests,
            Panel::Reviews => &s.review_requests,
            Panel::Jira | Panel::Claude | Panel::Created => return Vec::new(),
        };
        list.iter()
            .filter(|p| {
                self.matches(&[
                    &p.title,
                    &p.repo,
                    &p.head_branch,
                    p.jira_key.as_deref().unwrap_or(""),
                    &p.number.to_string(),
                ])
            })
            .collect()
    }

    pub fn visible_tickets(&self) -> Vec<&Ticket> {
        let Some(s) = &self.snapshot else { return Vec::new() };
        s.tickets.iter().filter(|t| self.matches(&[&t.key, &t.summary, &t.status])).collect()
    }

    /// The tickets I created in the watched statuses (after the filter).
    pub fn visible_created(&self) -> Vec<&Ticket> {
        let Some(s) = &self.snapshot else { return Vec::new() };
        s.created_tickets.iter().filter(|t| self.matches(&[&t.key, &t.summary, &t.status])).collect()
    }

    pub fn visible_sessions(&self) -> Vec<&ClaudeSession> {
        let Some(s) = &self.snapshot else { return Vec::new() };
        s.sessions
            .iter()
            .filter(|c| self.matches(&[&c.name, &c.cwd, c.jira_key.as_deref().unwrap_or("")]))
            .collect()
    }

    /// IDs of the items shown in a panel (after the filter): PR id, ticket key or session pid.
    pub fn visible_ids(&self, panel: Panel) -> Vec<String> {
        match panel {
            Panel::MyPrs | Panel::Reviews => {
                self.visible_prs(panel).iter().map(|p| p.id.clone()).collect()
            }
            Panel::Jira => self.visible_tickets().iter().map(|t| t.key.clone()).collect(),
            Panel::Claude => self.visible_sessions().iter().map(|c| c.pid.to_string()).collect(),
            Panel::Created => self.visible_created().iter().map(|t| t.key.clone()).collect(),
        }
    }

    pub fn selected_id(&self, panel: Panel) -> Option<String> {
        self.visible_ids(panel).into_iter().nth(self.selected[panel.index()])
    }

    fn selected_ids(&self) -> [Option<String>; PANELS] {
        Panel::ALL.map(|p| self.selected_id(p))
    }

    /// Puts each panel's selection back on the item it was on before a change of the snapshot or
    /// the filter; only when that item is no longer visible does the index stay, clamped.
    fn restore_selection(&mut self, before: &[Option<String>; PANELS]) {
        for panel in Panel::ALL {
            let ids = self.visible_ids(panel);
            let i = panel.index();
            match before[i].as_ref().and_then(|id| ids.iter().position(|x| x == id)) {
                Some(pos) => self.selected[i] = pos,
                None => self.selected[i] = self.selected[i].min(ids.len().saturating_sub(1)),
            }
        }
    }

    fn move_selection(&mut self, panel: Panel, delta: isize) {
        let len = self.visible_ids(panel).len();
        let i = panel.index();
        let next = self.selected[i].saturating_add_signed(delta);
        self.selected[i] = next.min(len.saturating_sub(1));
    }

    /// A mouse click: focuses the panel and selects `row` (an index into the visible items)
    /// when there is an item there.
    pub fn click(&mut self, panel: Panel, row: Option<usize>) {
        self.clear_notice();
        self.focus = panel;
        if let Some(row) = row
            && row < self.visible_ids(panel).len()
        {
            self.selected[panel.index()] = row;
        }
    }

    /// A left click: closes the help when it is open; else opens `link`, the web link under the
    /// pointer, and selects nothing; else focuses and selects what `hit_test` found (`hit`).
    pub fn left_click(&mut self, link: Option<&str>, hit: Option<(Panel, Option<usize>)>) -> Option<Action> {
        if self.show_help {
            self.show_help = false;
            return None;
        }
        if let Some(url) = link {
            self.clear_notice();
            return Some(Action::OpenUrl(url.to_string()));
        }
        if let Some((panel, row)) = hit {
            self.click(panel, row);
        }
        None
    }

    /// The mouse wheel over `panel`: moves that panel's selection; the focus stays.
    pub fn scroll(&mut self, panel: Panel, delta: isize) {
        self.move_selection(panel, delta);
    }

    pub fn key(&mut self, key: KeyEvent) -> Option<Action> {
        if key.kind == KeyEventKind::Release {
            return None;
        }
        self.clear_notice();
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
            return Some(Action::Quit);
        }
        if self.filter_editing {
            self.filter_key(key.code);
            return None;
        }
        match key.code {
            KeyCode::Esc => {
                if self.show_help {
                    self.show_help = false;
                } else {
                    self.change_filter(|st| st.filter = None);
                }
                None
            }
            _ if self.show_help => {
                if matches!(key.code, KeyCode::Char('?') | KeyCode::Char('q')) {
                    self.show_help = false;
                }
                None
            }
            KeyCode::Char('q') => Some(Action::Quit),
            KeyCode::Char('?') => {
                self.show_help = true;
                None
            }
            KeyCode::Char('j') | KeyCode::Down => {
                self.move_selection(self.focus, 1);
                None
            }
            KeyCode::Char('k') | KeyCode::Up => {
                self.move_selection(self.focus, -1);
                None
            }
            KeyCode::Char('1') => self.focus_and_none(Panel::MyPrs),
            KeyCode::Char('2') => self.focus_and_none(Panel::Reviews),
            KeyCode::Char('3') => self.focus_and_none(Panel::Jira),
            KeyCode::Char('4') => self.focus_and_none(Panel::Claude),
            KeyCode::Char('5') if self.shown(Panel::Created) => self.focus_and_none(Panel::Created),
            KeyCode::Tab => self.focus_and_none(self.cycle(1)),
            KeyCode::BackTab => self.focus_and_none(self.cycle(-1)),
            KeyCode::Char('/') => {
                self.filter_editing = true;
                self.filter.get_or_insert_with(String::new);
                None
            }
            KeyCode::Char('r') => Some(Action::Send(ClientMessage::Refresh)),
            KeyCode::Char(',') => Some(Action::Send(ClientMessage::OpenSettings)),
            KeyCode::Enter => {
                let id = self.selected_id(self.focus)?;
                let kind = match self.focus {
                    Panel::MyPrs | Panel::Reviews => OpenKind::Pr,
                    Panel::Jira | Panel::Created => OpenKind::Ticket,
                    Panel::Claude => OpenKind::Session,
                };
                Some(Action::Send(ClientMessage::Open { kind, id }))
            }
            KeyCode::Char('J') => {
                let id = self.selected_id(self.focus)?;
                let snapshot = self.snapshot.as_ref()?;
                let list = match self.focus {
                    Panel::MyPrs => &snapshot.my_pull_requests,
                    Panel::Reviews => &snapshot.review_requests,
                    Panel::Claude => {
                        // A session's key need not be one of my tickets; the app opens it by key.
                        let session = snapshot.sessions.iter().find(|c| c.pid.to_string() == id)?;
                        let key = session.jira_key.clone()?;
                        return Some(Action::Send(ClientMessage::Open { kind: OpenKind::Ticket, id: key }));
                    }
                    Panel::Jira | Panel::Created => return None,
                };
                let pr = list.iter().find(|p| p.id == id)?;
                pr.jira_key.as_ref()?;
                Some(Action::Send(ClientMessage::Open { kind: OpenKind::JiraForPr, id }))
            }
            _ => None,
        }
    }

    fn focus_and_none(&mut self, panel: Panel) -> Option<Action> {
        self.focus = panel;
        None
    }

    /// Runs a change to the filter and keeps every panel on its selected item.
    fn change_filter(&mut self, change: impl FnOnce(&mut AppState)) {
        let before = self.selected_ids();
        change(self);
        self.restore_selection(&before);
    }

    fn filter_key(&mut self, code: KeyCode) {
        self.change_filter(|st| match code {
            KeyCode::Char(c) => st.filter.get_or_insert_with(String::new).push(c),
            KeyCode::Backspace => {
                if let Some(f) = st.filter.as_mut() {
                    f.pop();
                }
            }
            KeyCode::Enter => {
                st.filter_editing = false;
                if st.filter.as_deref() == Some("") {
                    st.filter = None;
                }
            }
            KeyCode::Esc => {
                st.filter_editing = false;
                st.filter = None;
            }
            _ => {}
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::*;
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    const FIXTURE: &str = include_str!("../../protocol/fixtures/snapshot-v1.json");

    fn snapshot() -> Snapshot {
        serde_json::from_str(FIXTURE).unwrap()
    }

    fn msg(s: Snapshot) -> ServerMessage {
        ServerMessage::Snapshot { protocol: 1, data: Box::new(s) }
    }

    fn state() -> AppState {
        let mut st = AppState::new();
        st.apply(msg(snapshot()));
        st
    }

    fn press(st: &mut AppState, c: char) -> Option<Action> {
        st.key(KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE))
    }

    fn code(st: &mut AppState, c: KeyCode) -> Option<Action> {
        st.key(KeyEvent::new(c, KeyModifiers::NONE))
    }

    #[test]
    fn j_and_k_move_and_clamp() {
        let mut st = state();
        press(&mut st, 'k');
        assert_eq!(st.selected[0], 0);
        press(&mut st, 'j');
        assert_eq!(st.selected[0], 1);
        press(&mut st, 'j');
        assert_eq!(st.selected[0], 1);
        press(&mut st, 'k');
        assert_eq!(st.selected[0], 0);
    }

    #[test]
    fn number_keys_and_tab_switch_panels() {
        let mut st = state();
        press(&mut st, '3');
        assert_eq!(st.focus, Panel::Jira);
        press(&mut st, '4');
        assert_eq!(st.focus, Panel::Claude);
        code(&mut st, KeyCode::Tab);
        assert_eq!(st.focus, Panel::Created);
        code(&mut st, KeyCode::Tab);
        assert_eq!(st.focus, Panel::MyPrs);
        code(&mut st, KeyCode::BackTab);
        assert_eq!(st.focus, Panel::Created);
        press(&mut st, '2');
        assert_eq!(st.focus, Panel::Reviews);
        press(&mut st, '5');
        assert_eq!(st.focus, Panel::Created);
    }

    #[test]
    fn the_created_panel_shows_only_while_statuses_are_watched() {
        let mut s = snapshot();
        s.created_ticket_statuses.clear();
        s.created_tickets.clear();
        let mut st = AppState::new();
        st.apply(msg(s.clone()));
        assert!(!st.shown(Panel::Created));
        press(&mut st, '5');
        assert_eq!(st.focus, Panel::MyPrs);
        press(&mut st, '4');
        code(&mut st, KeyCode::Tab);
        assert_eq!(st.focus, Panel::MyPrs);
        // Switched on in the app: it shows, and Enter opens its ticket by key.
        st.apply(msg(snapshot()));
        press(&mut st, '5');
        assert_eq!(st.focus, Panel::Created);
        assert_eq!(
            code(&mut st, KeyCode::Enter),
            Some(Action::Send(ClientMessage::Open { kind: OpenKind::Ticket, id: "STORE-2412".into() }))
        );
        assert_eq!(press(&mut st, 'J'), None);
        // Switched off while focused: the focus goes to Jira.
        st.apply(msg(s));
        assert_eq!(st.focus, Panel::Jira);
    }

    #[test]
    fn enter_opens_the_selected_item() {
        let mut st = state();
        assert_eq!(
            code(&mut st, KeyCode::Enter),
            Some(Action::Send(ClientMessage::Open { kind: OpenKind::Pr, id: "PR_kwDOA1b2c3".into() }))
        );
        press(&mut st, '3');
        assert_eq!(
            code(&mut st, KeyCode::Enter),
            Some(Action::Send(ClientMessage::Open { kind: OpenKind::Ticket, id: "STORE-2290".into() }))
        );
        let mut s = snapshot();
        s.sessions[0].pid = 77424;
        let mut st = AppState::new();
        st.apply(msg(s));
        press(&mut st, '4');
        assert_eq!(
            code(&mut st, KeyCode::Enter),
            Some(Action::Send(ClientMessage::Open { kind: OpenKind::Session, id: "77424".into() }))
        );
    }

    #[test]
    fn capital_j_opens_jira_only_for_prs_with_a_key() {
        let mut st = state();
        assert_eq!(
            press(&mut st, 'J'),
            Some(Action::Send(ClientMessage::Open { kind: OpenKind::JiraForPr, id: "PR_kwDOA1b2c3".into() }))
        );
        press(&mut st, 'j');
        assert_eq!(press(&mut st, 'J'), None);
        press(&mut st, '3');
        assert_eq!(press(&mut st, 'J'), None);
    }

    #[test]
    fn filter_is_typed_applied_and_cleared() {
        let mut st = state();
        press(&mut st, '/');
        for c in "invoice".chars() {
            assert_eq!(press(&mut st, c), None);
        }
        assert_eq!(st.filter.as_deref(), Some("invoice"));
        assert_eq!(st.visible_ids(Panel::MyPrs), vec!["PR_kwDOA1b2c3".to_string()]);
        // Typed `j` / `q` go into the filter instead of acting as commands.
        press(&mut st, 'q');
        assert_eq!(st.filter.as_deref(), Some("invoiceq"));
        code(&mut st, KeyCode::Backspace);
        code(&mut st, KeyCode::Enter);
        assert_eq!(st.filter.as_deref(), Some("invoice"));
        assert_eq!(press(&mut st, 'q'), Some(Action::Quit));
        code(&mut st, KeyCode::Esc);
        assert_eq!(st.filter, None);
        assert_eq!(st.visible_ids(Panel::MyPrs).len(), 2);
    }

    #[test]
    fn simple_commands() {
        let mut st = state();
        assert_eq!(press(&mut st, 'r'), Some(Action::Send(ClientMessage::Refresh)));
        assert_eq!(press(&mut st, ','), Some(Action::Send(ClientMessage::OpenSettings)));
        assert_eq!(press(&mut st, 'q'), Some(Action::Quit));
        press(&mut st, '?');
        assert!(st.show_help);
        code(&mut st, KeyCode::Esc);
        assert!(!st.show_help);
    }

    #[test]
    fn removed_selection_keeps_the_index_clamped() {
        let mut st = state();
        press(&mut st, 'j');
        let mut s = snapshot();
        s.my_pull_requests.remove(1);
        st.apply(msg(s));
        assert_eq!(st.selected[0], 0);
        let mut st = state();
        press(&mut st, '4');
        press(&mut st, 'j');
        let mut s = snapshot();
        s.sessions.remove(1);
        st.apply(msg(s));
        assert_eq!(st.selected[3], 1);
    }

    #[test]
    fn reorder_keeps_the_selected_id() {
        let mut st = state();
        press(&mut st, 'j');
        assert_eq!(st.selected_id(Panel::MyPrs).as_deref(), Some("PR_kwDOA4d5e6"));
        let mut s = snapshot();
        s.my_pull_requests.reverse();
        st.apply(msg(s));
        assert_eq!(st.selected[0], 0);
        assert_eq!(st.selected_id(Panel::MyPrs).as_deref(), Some("PR_kwDOA4d5e6"));
    }

    #[test]
    fn disconnect_keeps_the_snapshot() {
        let mut st = state();
        assert!(st.connected);
        st.on_event(crate::client::Event::Disconnected);
        assert!(!st.connected);
        assert!(st.snapshot.is_some());
    }

    fn type_keys(st: &mut AppState, s: &str) {
        for c in s.chars() {
            press(st, c);
        }
    }

    #[test]
    fn typing_a_filter_keeps_the_selected_id() {
        let mut st = state();
        type_keys(&mut st, "j");
        assert_eq!(st.selected_id(Panel::MyPrs).as_deref(), Some("PR_kwDOA4d5e6"));
        type_keys(&mut st, "/tidy");
        assert_eq!(st.visible_ids(Panel::MyPrs), vec!["PR_kwDOA4d5e6".to_string()]);
        assert_eq!(st.selected[0], 0);
        assert_eq!(st.selected_id(Panel::MyPrs).as_deref(), Some("PR_kwDOA4d5e6"));
        // Esc while typing clears the filter; the same PR stays selected at its old index.
        code(&mut st, KeyCode::Esc);
        assert_eq!(st.filter, None);
        assert_eq!(st.selected[0], 1);
        assert_eq!(st.selected_id(Panel::MyPrs).as_deref(), Some("PR_kwDOA4d5e6"));
    }

    #[test]
    fn clearing_an_applied_filter_with_esc_keeps_the_selected_id() {
        let mut st = state();
        type_keys(&mut st, "4j");
        assert_eq!(st.selected_id(Panel::Claude).as_deref(), Some("41002"));
        type_keys(&mut st, "/store");
        code(&mut st, KeyCode::Enter);
        assert_eq!(st.selected_id(Panel::Claude).as_deref(), Some("41002"));
        assert_eq!(st.selected[3], 0);
        code(&mut st, KeyCode::Esc);
        assert_eq!(st.selected[3], 1);
        assert_eq!(st.selected_id(Panel::Claude).as_deref(), Some("41002"));
    }

    #[test]
    fn a_filtered_out_selection_is_clamped() {
        let mut st = state();
        type_keys(&mut st, "j/zzz");
        assert!(st.visible_ids(Panel::MyPrs).is_empty());
        assert_eq!(st.selected[0], 0);
        assert_eq!(st.selected_id(Panel::MyPrs), None);
    }

    #[test]
    fn click_focuses_the_panel_and_selects_the_row() {
        let mut st = state();
        st.click(Panel::Claude, Some(2));
        assert_eq!(st.focus, Panel::Claude);
        assert_eq!(st.selected[3], 2);
        // A click past the last row (or on the border) only focuses.
        st.click(Panel::Jira, Some(5));
        assert_eq!(st.focus, Panel::Jira);
        assert_eq!(st.selected[2], 0);
        st.click(Panel::Reviews, None);
        assert_eq!(st.focus, Panel::Reviews);
    }

    #[test]
    fn scroll_moves_the_focused_selection_and_clamps() {
        let mut st = state();
        st.click(Panel::Claude, None);
        st.scroll(Panel::Claude, 1);
        st.scroll(Panel::Claude, 1);
        st.scroll(Panel::Claude, 1);
        assert_eq!(st.selected[3], 2);
        st.scroll(Panel::Claude, -5);
        assert_eq!(st.selected[3], 0);
    }

    #[test]
    fn disconnect_sets_reconnecting_until_the_next_snapshot() {
        let mut st = state();
        assert!(!st.reconnecting);
        st.on_event(crate::client::Event::Disconnected);
        assert!(st.reconnecting);
        st.apply(msg(snapshot()));
        assert!(!st.reconnecting);
    }

    #[test]
    fn a_reconnect_snapshot_clears_the_upgrade_status_unless_it_failed() {
        let mut st = state();
        let upgrade = |phase, message: Option<&str>| ServerMessage::Upgrade {
            phase,
            progress: None,
            message: message.map(String::from),
        };
        st.apply(upgrade(UpgradePhase::Restarting, None));
        // A snapshot on the same connection keeps it.
        st.apply(msg(snapshot()));
        assert!(st.upgrade.is_some());
        // The app restarted: the first snapshot after the reconnect clears it.
        st.on_event(crate::client::Event::Disconnected);
        st.apply(msg(snapshot()));
        assert_eq!(st.upgrade, None);
        // A failure stays visible.
        st.apply(upgrade(UpgradePhase::Failed, Some("signature mismatch")));
        st.on_event(crate::client::Event::Disconnected);
        st.apply(msg(snapshot()));
        assert_eq!(st.upgrade.as_ref().map(|u| u.phase), Some(UpgradePhase::Failed));
    }

    #[test]
    fn a_reordered_snapshot_after_a_disconnect_keeps_the_selected_id() {
        let mut st = state();
        type_keys(&mut st, "4jj");
        assert_eq!(st.selected_id(Panel::Claude).as_deref(), Some("41003"));
        st.on_event(crate::client::Event::Disconnected);
        let mut s = snapshot();
        s.sessions.reverse();
        st.apply(msg(s));
        assert!(!st.reconnecting);
        assert_eq!(st.selected[3], 0);
        assert_eq!(st.selected_id(Panel::Claude).as_deref(), Some("41003"));
    }

    #[test]
    fn the_wheel_scrolls_the_panel_under_the_pointer_without_moving_focus() {
        let mut st = state();
        st.scroll(Panel::Claude, 1);
        st.scroll(Panel::Claude, 5);
        assert_eq!(st.selected[3], 2);
        assert_eq!(st.selected[0], 0);
        assert_eq!(st.focus, Panel::MyPrs);
        st.scroll(Panel::Claude, -1);
        assert_eq!(st.selected[3], 1);
    }

    #[test]
    fn refreshing_shows_until_the_next_snapshot() {
        let mut st = state();
        let t0 = Instant::now();
        assert_eq!(press(&mut st, 'r'), Some(Action::Send(ClientMessage::Refresh)));
        st.refresh_sent(t0);
        assert_eq!(st.notice.as_deref(), Some(REFRESHING));
        assert_eq!(st.next_expiry(), Some(t0 + REFRESH_NOTICE));
        st.apply_at(msg(snapshot()), t0 + Duration::from_secs(1));
        assert_eq!(st.notice, None);
        assert_eq!(st.next_expiry(), None);
    }

    #[test]
    fn refreshing_gives_up_after_ten_seconds() {
        let mut st = state();
        let t0 = Instant::now();
        st.refresh_sent(t0);
        assert!(!st.expire(t0 + REFRESH_NOTICE - Duration::from_millis(1)));
        assert_eq!(st.notice.as_deref(), Some(REFRESHING));
        assert!(st.expire(t0 + REFRESH_NOTICE));
        assert_eq!(st.notice, None);
        assert_eq!(REFRESH_NOTICE, Duration::from_secs(10));
    }

    #[test]
    fn a_snapshot_leaves_other_notices_alone() {
        let mut st = state();
        let t0 = Instant::now();
        st.show_notice("not connected — action not sent", t0 + NOTICE);
        st.apply_at(msg(snapshot()), t0);
        assert!(st.notice.is_some());
        assert!(st.expire(t0 + NOTICE));
        assert_eq!(st.notice, None);
    }

    fn upgrade(phase: UpgradePhase) -> ServerMessage {
        ServerMessage::Upgrade { phase, progress: None, message: None }
    }

    #[test]
    fn final_upgrade_phases_leave_the_header_after_ten_seconds() {
        for phase in [UpgradePhase::UpToDate, UpgradePhase::Failed] {
            let mut st = state();
            let t0 = Instant::now();
            st.apply_at(upgrade(phase), t0);
            assert_eq!(st.next_expiry(), Some(t0 + UPGRADE_STATUS));
            assert!(!st.expire(t0 + UPGRADE_STATUS - Duration::from_millis(1)));
            assert!(st.upgrade.is_some());
            assert!(st.expire(t0 + UPGRADE_STATUS));
            assert_eq!(st.upgrade, None);
            assert_eq!(st.next_expiry(), None);
        }
        assert_eq!(UPGRADE_STATUS, Duration::from_secs(10));
    }

    #[test]
    fn running_upgrade_phases_need_no_timed_wake() {
        let mut st = state();
        let t0 = Instant::now();
        st.apply_at(upgrade(UpgradePhase::UpToDate), t0);
        // A new run starts: the progress stays until the next phase, with no wake scheduled.
        st.apply_at(upgrade(UpgradePhase::Downloading), t0);
        assert_eq!(st.next_expiry(), None);
        assert!(!st.expire(t0 + UPGRADE_STATUS * 2));
        assert!(st.upgrade.is_some());
    }

    #[test]
    fn capital_j_on_a_session_opens_its_ticket_by_key() {
        let mut st = state();
        press(&mut st, '4');
        // The first session has no key.
        assert_eq!(press(&mut st, 'J'), None);
        press(&mut st, 'j');
        press(&mut st, 'j');
        assert_eq!(
            press(&mut st, 'J'),
            Some(Action::Send(ClientMessage::Open { kind: OpenKind::Ticket, id: "STORE-2290".into() }))
        );
    }

    #[test]
    fn a_left_click_on_a_link_opens_it_and_selects_nothing() {
        let mut st = state();
        st.show_notice("could not open link", Instant::now() + NOTICE);
        let before = (st.focus, st.selected);
        let url = "https://example.atlassian.net/browse/STORE-2290";
        assert_eq!(st.left_click(Some(url), None), Some(Action::OpenUrl(url.into())));
        assert_eq!((st.focus, st.selected), before);
        assert_eq!(st.notice, None);
    }

    #[test]
    fn a_left_click_beside_a_link_focuses_and_selects() {
        let mut st = state();
        assert_eq!(st.left_click(None, Some((Panel::Claude, Some(1)))), None);
        assert_eq!((st.focus, st.selected[3]), (Panel::Claude, 1));
        // On the detail pane outside a link, the header or the footer: nothing changes.
        assert_eq!(st.left_click(None, None), None);
        assert_eq!((st.focus, st.selected[3]), (Panel::Claude, 1));
    }

    #[test]
    fn a_left_click_with_the_help_open_only_closes_it() {
        let mut st = state();
        press(&mut st, '?');
        assert_eq!(st.left_click(Some("https://example.test/STORE-1"), Some((Panel::Jira, Some(1)))), None);
        assert!(!st.show_help);
        assert_eq!(st.focus, Panel::MyPrs);
    }

    #[test]
    fn the_next_key_or_click_clears_the_notice() {
        let mut st = state();
        st.notice = Some("not connected — action not sent".into());
        press(&mut st, 'j');
        assert_eq!(st.notice, None);
        st.notice = Some("x".into());
        st.click(Panel::Jira, None);
        assert_eq!(st.notice, None);
    }
}
