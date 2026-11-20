use crossterm::Command;
use crossterm::cursor::{Hide, Show};
use crossterm::event::{self, Event as Input, MouseButton, MouseEventKind};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use devpulse::client::{self, Connection, Event};
use devpulse::protocol::ClientMessage;
use devpulse::state::{Action, AppState, NOTICE};
use devpulse::ui;
use devpulse::upgrade::run_upgrade;
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::Rect;
use std::fmt;
use std::io::{self, Stdout, stdout};
use std::process::ExitCode;
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

const VERSION: &str = match option_env!("DEVPULSE_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};

const USAGE: &str = "usage: devpulse [upgrade | --version]";

/// Relative ages ("2m") are refreshed this often when nothing else redraws.
const TICK: Duration = Duration::from_secs(60);
/// Pause between reconnect attempts after the app went away.
const RETRY: Duration = Duration::from_secs(1);
const NOT_SENT: &str = "not connected — action not sent";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        [] => run_tui(),
        ["--version"] => {
            println!("devpulse {VERSION}");
            ExitCode::SUCCESS
        }
        ["upgrade"] => upgrade(),
        _ => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

/// `devpulse upgrade`: starts the app if needed, then lets it install the latest version.
fn upgrade() -> ExitCode {
    match client::ensure_app_running().and_then(|()| Connection::connect()) {
        Ok(conn) => run_upgrade(conn),
        Err(e) => {
            eprintln!("devpulse: cannot reach the DevPulse app ({e}). Is DevPulse installed?");
            ExitCode::from(1)
        }
    }
}

/// Everything the single event loop waits for, merged into one channel.
enum Msg {
    Input(Input),
    /// Stdin is gone; nothing more can be read.
    InputClosed,
    /// A socket event, tagged with the connection generation it came from.
    Socket(u64, Event),
}

fn run_tui() -> ExitCode {
    if let Err(e) = client::ensure_app_running() {
        eprintln!(
            "devpulse: cannot reach the DevPulse app ({e}). Is DevPulse installed in /Applications?"
        );
        return ExitCode::from(1);
    }
    let (tx, rx) = mpsc::channel();
    let mut state = AppState::new();
    let mut link = Link { tx: tx.clone(), writer: None, generation: 0, retry_at: None };
    if link.connect().is_err() {
        link.lost(&mut state);
    }
    let mut terminal = match setup() {
        Ok(t) => t,
        Err(e) => {
            restore();
            eprintln!("devpulse: cannot set up the terminal: {e}");
            return ExitCode::from(1);
        }
    };
    // Blocks in `read()`, so input costs nothing while idle; ends with the process.
    thread::spawn(move || {
        loop {
            match event::read() {
                Ok(ev) => {
                    if tx.send(Msg::Input(ev)).is_err() {
                        return;
                    }
                }
                Err(_) => {
                    let _ = tx.send(Msg::InputClosed);
                    return;
                }
            }
        }
    });
    let result = event_loop(&mut terminal, &rx, &mut state, &mut link);
    restore();
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("devpulse: {e}");
            ExitCode::from(1)
        }
    }
}

/// Waits for input, socket events, the minute tick or the next reconnect attempt, and redraws
/// only when one of them changed something. Nothing runs between events.
fn event_loop(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    rx: &mpsc::Receiver<Msg>,
    state: &mut AppState,
    link: &mut Link,
) -> io::Result<()> {
    let mut dirty = true;
    let mut next_tick = Instant::now() + TICK;
    let mut area = Rect::default();
    loop {
        if dirty {
            area = terminal.draw(|f| ui::draw(f, state, SystemTime::now()))?.area;
            dirty = false;
            next_tick = Instant::now() + TICK;
        }
        // A notice or a final upgrade phase that expires adds one timed wake, no more.
        let wakes = [link.retry_at, state.next_expiry()].into_iter().flatten();
        let deadline = wakes.fold(next_tick, Instant::min);
        let first = match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(msg) => Some(msg),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => return Ok(()),
        };
        // Handle everything already queued before drawing once (e.g. a burst of resizes).
        for msg in first.into_iter().chain(std::iter::from_fn(|| rx.try_recv().ok())) {
            match handle(msg, state, link, area) {
                Flow::Quit => return Ok(()),
                Flow::Redraw => dirty = true,
                Flow::Idle => {}
            }
        }
        let now = Instant::now();
        if now >= next_tick {
            dirty = true;
        }
        if state.expire(now) {
            dirty = true;
        }
        if link.retry_at.is_some_and(|r| now >= r) && link.connect().is_err() {
            link.retry_at = Some(now + RETRY);
        }
    }
}

enum Flow {
    Quit,
    Redraw,
    Idle,
}

fn handle(
    msg: Msg,
    state: &mut AppState,
    link: &mut Link,
    area: Rect,
) -> Flow {
    match msg {
        Msg::InputClosed => Flow::Quit,
        Msg::Socket(generation, event) => {
            if generation != link.generation {
                return Flow::Idle; // a leftover from a connection already replaced
            }
            match event {
                Event::Disconnected => link.lost(state),
                event => state.on_event(event),
            }
            Flow::Redraw
        }
        Msg::Input(Input::Key(key)) => {
            let action = state.key(key);
            if action == Some(Action::Quit) {
                return Flow::Quit;
            }
            if let Some(Action::Send(msg)) = action {
                let now = Instant::now();
                if !link.send(&msg, state) {
                    state.show_notice(NOT_SENT, now + NOTICE);
                } else if msg == ClientMessage::Refresh {
                    state.refresh_sent(now);
                }
            }
            Flow::Redraw
        }
        Msg::Input(Input::Mouse(mouse)) => match mouse.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                if state.show_help {
                    state.show_help = false;
                } else if let Some((panel, row)) = ui::hit_test(area, state, mouse.column, mouse.row) {
                    state.click(panel, row);
                }
                Flow::Redraw
            }
            // Like lazygit: the wheel scrolls the panel under the pointer, not the focused one.
            MouseEventKind::ScrollDown | MouseEventKind::ScrollUp if !state.show_help => {
                let delta = if mouse.kind == MouseEventKind::ScrollDown { 1 } else { -1 };
                match ui::hit_test(area, state, mouse.column, mouse.row) {
                    Some((panel, _)) => {
                        state.scroll(panel, delta);
                        Flow::Redraw
                    }
                    None => Flow::Idle,
                }
            }
            _ => Flow::Idle,
        },
        Msg::Input(Input::Resize(..)) => Flow::Redraw,
        Msg::Input(_) => Flow::Idle,
    }
}

/// The connection to the app: the writing half, plus what is needed to replace it.
struct Link {
    tx: Sender<Msg>,
    writer: Option<Connection>,
    /// Bumped on every connect and loss, so events of an old reader are ignored.
    generation: u64,
    /// When to try connecting again; `None` while connected.
    retry_at: Option<Instant>,
}

impl Link {
    /// Connects (which sends `hello`) and starts forwarding the socket into the event loop.
    fn connect(&mut self) -> io::Result<()> {
        let conn = Connection::connect()?;
        let writer = conn.writer()?;
        self.generation += 1;
        let generation = self.generation;
        conn.forward(self.tx.clone(), move |e| Msg::Socket(generation, e));
        self.writer = Some(writer);
        self.retry_at = None;
        Ok(())
    }

    /// The connection is gone: close it for good and schedule a reconnect.
    fn lost(&mut self, state: &mut AppState) {
        if let Some(writer) = self.writer.take() {
            writer.shutdown();
        }
        self.generation += 1;
        self.retry_at = Some(Instant::now() + RETRY);
        state.on_event(Event::Disconnected);
    }

    /// Sends a command and says whether it went out. Not connected → `false`; a failed or
    /// timed-out write counts as a lost connection.
    fn send(&mut self, msg: &ClientMessage, state: &mut AppState) -> bool {
        let Some(writer) = self.writer.as_mut() else { return false };
        if writer.send(msg).is_err() {
            self.lost(state);
            return false;
        }
        true
    }
}

/// Mouse reporting for clicks and the wheel only: normal (VT200) tracking `?1000` reports button
/// presses, releases and the wheel; `?1006` encodes them as SGR. Crossterm's `EnableMouseCapture`
/// also turns on motion tracking (`?1003`), which would wake the loop on every mouse move.
struct EnableClicks;
struct DisableClicks;

impl Command for EnableClicks {
    fn write_ansi(&self, f: &mut impl fmt::Write) -> fmt::Result {
        f.write_str("\x1b[?1000h\x1b[?1006h")
    }
}

impl Command for DisableClicks {
    fn write_ansi(&self, f: &mut impl fmt::Write) -> fmt::Result {
        f.write_str("\x1b[?1006l\x1b[?1000l")
    }
}

fn setup() -> io::Result<Terminal<CrosstermBackend<Stdout>>> {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore();
        previous(info);
    }));
    enable_raw_mode()?;
    execute!(stdout(), EnterAlternateScreen, EnableClicks, Hide)?;
    Terminal::new(CrosstermBackend::new(stdout()))
}

/// Puts the terminal back: also called from the panic hook, so it must not fail or panic.
fn restore() {
    let _ = execute!(stdout(), DisableClicks, LeaveAlternateScreen, Show);
    let _ = disable_raw_mode();
}
