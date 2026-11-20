//! `devpulse upgrade`: asks the app to install the latest version and prints its progress.
//!
//! [`Upgrade`] turns socket events into terminal output and the next step without doing any I/O,
//! so it is unit-tested; [`run_upgrade`] drives it over the connection.

use crate::client::{Connection, Event};
use crate::protocol::{ClientMessage, ServerMessage, UpgradePhase};
use std::io::{self, IsTerminal, Write};
use std::mem;
use std::process::ExitCode;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

/// Without an upgrade message for this long, the app counts as stuck.
const NO_RESPONSE: Duration = Duration::from_secs(120);
/// How long the app has to quit and come back after `restarting`.
const RELAUNCH: Duration = Duration::from_secs(30);
/// Pause between connection attempts while the app relaunches.
const RETRY: Duration = Duration::from_millis(200);

/// What happens after an event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    /// Wait for the next message.
    Wait,
    /// The app restarts with the new version: reconnect and report it.
    Relaunch,
    /// Finished successfully.
    Done,
    /// Finished with this line for stderr.
    Failed(String),
}

impl Step {
    /// The exit code this step ends the command with; `None` while it waits. A relaunch exits 0
    /// whether or not the new version reports back.
    pub fn exit_code(&self) -> Option<u8> {
        match self {
            Step::Wait => None,
            Step::Relaunch | Step::Done => Some(0),
            Step::Failed(_) => Some(1),
        }
    }
}

/// The line printed for an upgrade message; `None` for a phase this client does not know.
pub fn phase_line(
    phase: UpgradePhase,
    progress: Option<f64>,
    message: Option<&str>,
    app_version: Option<&str>,
) -> Option<String> {
    let line = match phase {
        UpgradePhase::Checking => "Checking for updates…".to_string(),
        UpgradePhase::Downloading => match progress {
            Some(p) => format!("Downloading… {}%", percent(p)),
            None => "Downloading…".to_string(),
        },
        UpgradePhase::Installing => "Installing…".to_string(),
        UpgradePhase::Restarting => "Restarting DevPulse…".to_string(),
        UpgradePhase::UpToDate => match app_version {
            Some(v) => format!("DevPulse is up to date (v{v})"),
            None => "DevPulse is up to date".to_string(),
        },
        UpgradePhase::Failed => format!("Update failed: {}", message.unwrap_or("unknown error")),
        UpgradePhase::Unknown => return None,
    };
    Some(line)
}

/// The last line, once the relaunched app reported its version.
pub fn updated_line(app_version: &str) -> String {
    format!("Updated to v{app_version}")
}

fn percent(progress: f64) -> u32 {
    (progress.clamp(0.0, 1.0) * 100.0).round() as u32
}

/// Turns the app's messages into terminal output, one line per phase.
pub struct Upgrade {
    /// Stdout is a terminal: download progress rewrites one line in place.
    tty: bool,
    /// From the snapshot the app sends on connect, for the up-to-date line.
    app_version: Option<String>,
    /// The last line shown, so a repeated message prints nothing.
    last_line: Option<String>,
    /// Off a terminal: the 10 % step of the last progress line printed; `Downloading…` without
    /// a length counts as 0 %, so the `0%` that follows it prints nothing.
    last_step: Option<u32>,
    /// A progress line is on screen without its newline.
    open_line: bool,
}

impl Upgrade {
    /// `tty`: stdout is a terminal, so download progress rewrites one line in place.
    pub fn new(tty: bool) -> Upgrade {
        Upgrade { tty, app_version: None, last_line: None, last_step: None, open_line: false }
    }

    /// Handles one socket event: what to print on stdout, and what to do next.
    pub fn on_event(&mut self, event: Event) -> (String, Step) {
        match event {
            Event::Server(ServerMessage::Snapshot { data, .. }) => {
                self.app_version = Some(data.app_version);
                (String::new(), Step::Wait)
            }
            Event::Server(ServerMessage::Upgrade { phase, progress, message }) => {
                self.on_phase(phase, progress, message.as_deref())
            }
            Event::Server(ServerMessage::Unknown) => (String::new(), Step::Wait),
            Event::Disconnected => self.fail("DevPulse quit unexpectedly"),
        }
    }

    /// Ends with a failure the client noticed itself (no response, lost connection).
    pub fn fail(&mut self, reason: &str) -> (String, Step) {
        (self.close_line(), Step::Failed(format!("Update failed: {reason}")))
    }

    fn on_phase(
        &mut self,
        phase: UpgradePhase,
        progress: Option<f64>,
        message: Option<&str>,
    ) -> (String, Step) {
        let Some(line) = phase_line(phase, progress, message, self.app_version.as_deref()) else {
            return (String::new(), Step::Wait);
        };
        let step = match phase {
            UpgradePhase::Failed => return (self.close_line(), Step::Failed(line)),
            UpgradePhase::UpToDate => Step::Done,
            UpgradePhase::Restarting => Step::Relaunch,
            _ => Step::Wait,
        };
        (self.show(phase, progress, line), step)
    }

    fn show(&mut self, phase: UpgradePhase, progress: Option<f64>, line: String) -> String {
        if self.last_line.as_ref() == Some(&line) {
            return String::new();
        }
        let out = match phase {
            UpgradePhase::Downloading if self.tty => {
                self.open_line = true;
                format!("\r{line}")
            }
            UpgradePhase::Downloading => {
                let step = progress.map_or(0, |p| percent(p) / 10);
                if self.last_step == Some(step) {
                    return String::new();
                }
                self.last_step = Some(step);
                format!("{line}\n")
            }
            _ => format!("{}{line}\n", self.close_line()),
        };
        self.last_line = Some(line);
        out
    }

    /// Ends a progress line left open on the terminal.
    fn close_line(&mut self) -> String {
        if mem::take(&mut self.open_line) { "\n".to_string() } else { String::new() }
    }
}

/// Sends `upgrade` over `conn` (already greeted with `hello`) and prints the app's phases until
/// the upgrade ends; after a restart it reconnects and prints the new version.
pub fn run_upgrade(conn: Connection) -> ExitCode {
    let sent = conn.writer().and_then(|mut writer| writer.send(&ClientMessage::Upgrade));
    let rx = conn.lines();
    if let Err(e) = sent {
        eprintln!("Update failed: cannot reach DevPulse ({e})");
        return ExitCode::from(1);
    }
    let mut upgrade = Upgrade::new(io::stdout().is_terminal());
    let mut deadline = Instant::now() + NO_RESPONSE;
    let step = loop {
        let wait = deadline.saturating_duration_since(Instant::now());
        let (out, step) = match rx.recv_timeout(wait) {
            Ok(event) => {
                if matches!(event, Event::Server(ServerMessage::Upgrade { .. })) {
                    deadline = Instant::now() + NO_RESPONSE;
                }
                upgrade.on_event(event)
            }
            Err(RecvTimeoutError::Timeout) => upgrade.fail("no response from DevPulse"),
            Err(RecvTimeoutError::Disconnected) => upgrade.on_event(Event::Disconnected),
        };
        print!("{out}");
        let _ = io::stdout().flush();
        if step != Step::Wait {
            break step;
        }
    };
    let step = match step {
        Step::Relaunch => match relaunched_version(&rx, &mut upgrade) {
            Ok(Some(version)) => {
                println!("{}", updated_line(&version));
                Step::Done
            }
            Ok(None) => {
                eprintln!(
                    "Warning: DevPulse did not come back within {} s; open it to check that the \
                     update was installed.",
                    RELAUNCH.as_secs()
                );
                Step::Done
            }
            Err(failed) => failed,
        },
        step => step,
    };
    if let Step::Failed(line) = &step {
        eprintln!("{line}");
    }
    ExitCode::from(step.exit_code().unwrap_or(0))
}

/// After `restarting`: waits for the old app to close the connection, then for the relaunched
/// one to send its first snapshot, all within [`RELAUNCH`]. Returns its version, `None` when it
/// did not come back, or the failure the old app reported instead of quitting.
fn relaunched_version(
    old: &Receiver<Event>,
    upgrade: &mut Upgrade,
) -> Result<Option<String>, Step> {
    let deadline = Instant::now() + RELAUNCH;
    let left = || deadline.saturating_duration_since(Instant::now());
    loop {
        match old.recv_timeout(left()) {
            Ok(Event::Disconnected) | Err(RecvTimeoutError::Disconnected) => break,
            Ok(event) => {
                if let (_, failed @ Step::Failed(_)) = upgrade.on_event(event) {
                    return Err(failed);
                }
            }
            Err(RecvTimeoutError::Timeout) => return Ok(None),
        }
    }
    while !left().is_zero() {
        if let Ok(conn) = Connection::connect() {
            let rx = conn.lines();
            loop {
                match rx.recv_timeout(left()) {
                    Ok(Event::Server(ServerMessage::Snapshot { data, .. })) => {
                        return Ok(Some(data.app_version));
                    }
                    Ok(Event::Server(_)) => {}
                    Ok(Event::Disconnected) => break,
                    Err(_) => return Ok(None),
                }
            }
        }
        thread::sleep(RETRY.min(left()));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::Snapshot;

    const FIXTURE: &str = include_str!("../../protocol/fixtures/snapshot-v1.json");

    fn snapshot() -> Event {
        let data: Snapshot = serde_json::from_str(FIXTURE).unwrap();
        Event::Server(ServerMessage::Snapshot { protocol: 1, data: Box::new(data) })
    }

    fn phase(phase: UpgradePhase, progress: Option<f64>, message: Option<&str>) -> Event {
        let message = message.map(String::from);
        Event::Server(ServerMessage::Upgrade { phase, progress, message })
    }

    fn downloading(progress: Option<f64>) -> Event {
        phase(UpgradePhase::Downloading, progress, None)
    }

    /// Feeds the events and collects the stdout text of each.
    fn outputs(upgrade: &mut Upgrade, events: Vec<Event>) -> Vec<String> {
        events.into_iter().map(|e| upgrade.on_event(e).0).collect()
    }

    #[test]
    fn each_phase_prints_one_line() {
        use UpgradePhase::*;
        let line = |p, progress, message| phase_line(p, progress, message, Some("0.1.0"));
        assert_eq!(line(Checking, None, None).as_deref(), Some("Checking for updates…"));
        assert_eq!(line(Downloading, Some(0.42), None).as_deref(), Some("Downloading… 42%"));
        assert_eq!(line(Downloading, None, None).as_deref(), Some("Downloading…"));
        assert_eq!(line(Installing, None, None).as_deref(), Some("Installing…"));
        assert_eq!(line(Restarting, None, None).as_deref(), Some("Restarting DevPulse…"));
        assert_eq!(line(UpToDate, None, None).as_deref(), Some("DevPulse is up to date (v0.1.0)"));
        assert_eq!(
            line(Failed, None, Some("signature mismatch")).as_deref(),
            Some("Update failed: signature mismatch")
        );
        assert_eq!(line(Unknown, None, None), None);
        assert_eq!(updated_line("0.1.1"), "Updated to v0.1.1");
    }

    #[test]
    fn percent_is_rounded_and_clamped() {
        let pct = |p| phase_line(UpgradePhase::Downloading, Some(p), None, None).unwrap();
        assert_eq!(pct(0.29), "Downloading… 29%");
        assert_eq!(pct(0.0), "Downloading… 0%");
        assert_eq!(pct(1.3), "Downloading… 100%");
        assert_eq!(pct(-0.2), "Downloading… 0%");
    }

    #[test]
    fn up_to_date_uses_the_version_from_the_snapshot() {
        let mut upgrade = Upgrade::new(false);
        assert_eq!(upgrade.on_event(snapshot()), (String::new(), Step::Wait));
        let (out, step) = upgrade.on_event(phase(UpgradePhase::UpToDate, None, None));
        assert_eq!(out, "DevPulse is up to date (v0.1.0)\n");
        assert_eq!(step, Step::Done);
    }

    #[test]
    fn exit_codes_follow_the_final_phase() {
        let mut upgrade = Upgrade::new(false);
        let step = |u: &mut Upgrade, p, m| u.on_event(phase(p, None, m)).1;
        assert_eq!(step(&mut upgrade, UpgradePhase::Checking, None).exit_code(), None);
        assert_eq!(step(&mut upgrade, UpgradePhase::UpToDate, None).exit_code(), Some(0));
        let restarting = step(&mut Upgrade::new(false), UpgradePhase::Restarting, None);
        assert_eq!(restarting, Step::Relaunch);
        assert_eq!(restarting.exit_code(), Some(0));
        let failed = step(&mut Upgrade::new(false), UpgradePhase::Failed, Some("boom"));
        assert_eq!(failed, Step::Failed("Update failed: boom".into()));
        assert_eq!(failed.exit_code(), Some(1));
    }

    #[test]
    fn a_full_upgrade_prints_each_phase_once() {
        let mut upgrade = Upgrade::new(false);
        let events = vec![
            snapshot(),
            phase(UpgradePhase::Checking, None, None),
            phase(UpgradePhase::Checking, None, None),
            downloading(Some(1.0)),
            phase(UpgradePhase::Installing, None, None),
            phase(UpgradePhase::Restarting, None, None),
        ];
        assert_eq!(
            outputs(&mut upgrade, events).concat(),
            "Checking for updates…\nDownloading… 100%\nInstalling…\nRestarting DevPulse…\n"
        );
    }

    #[test]
    fn on_a_terminal_progress_rewrites_one_line_and_ends_it_on_the_next_phase() {
        let mut upgrade = Upgrade::new(true);
        let events = vec![
            phase(UpgradePhase::Checking, None, None),
            downloading(None),
            downloading(Some(0.1)),
            downloading(Some(0.1)),
            downloading(Some(0.42)),
            phase(UpgradePhase::Installing, None, None),
        ];
        assert_eq!(
            outputs(&mut upgrade, events),
            [
                "Checking for updates…\n",
                "\rDownloading…",
                "\rDownloading… 10%",
                "",
                "\rDownloading… 42%",
                "\nInstalling…\n",
            ]
        );
    }

    #[test]
    fn off_a_terminal_progress_prints_at_most_once_per_ten_percent() {
        let mut upgrade = Upgrade::new(false);
        let events = [0.0, 0.05, 0.1, 0.19, 0.42, 0.45, 1.0].map(|p| downloading(Some(p)));
        assert_eq!(
            outputs(&mut upgrade, events.into()).concat(),
            "Downloading… 0%\nDownloading… 10%\nDownloading… 42%\nDownloading… 100%\n"
        );
    }

    #[test]
    fn off_a_terminal_downloading_then_a_known_length_prints_one_line() {
        let mut upgrade = Upgrade::new(false);
        let events = [None, Some(0.0), Some(0.05), Some(0.1)].map(downloading);
        assert_eq!(
            outputs(&mut upgrade, events.into()).concat(),
            "Downloading…\nDownloading… 10%\n"
        );
    }

    #[test]
    fn a_failure_after_restarting_still_fails() {
        let mut upgrade = Upgrade::new(false);
        assert_eq!(upgrade.on_event(phase(UpgradePhase::Restarting, None, None)).1, Step::Relaunch);
        let (_, step) = upgrade.on_event(phase(UpgradePhase::Failed, None, Some("install failed")));
        assert_eq!(step, Step::Failed("Update failed: install failed".into()));
    }

    #[test]
    fn an_unknown_length_prints_downloading_once() {
        let mut upgrade = Upgrade::new(false);
        let events = vec![downloading(None), downloading(None), downloading(None)];
        assert_eq!(outputs(&mut upgrade, events).concat(), "Downloading…\n");
    }

    #[test]
    fn a_failure_ends_an_open_progress_line_first() {
        let mut upgrade = Upgrade::new(true);
        upgrade.on_event(downloading(Some(0.5)));
        let (out, step) = upgrade.on_event(phase(UpgradePhase::Failed, None, Some("disk full")));
        assert_eq!(out, "\n");
        assert_eq!(step, Step::Failed("Update failed: disk full".into()));
    }

    #[test]
    fn a_drop_before_restarting_fails() {
        let mut upgrade = Upgrade::new(false);
        upgrade.on_event(phase(UpgradePhase::Checking, None, None));
        let (out, step) = upgrade.on_event(Event::Disconnected);
        assert_eq!(out, "");
        assert_eq!(step, Step::Failed("Update failed: DevPulse quit unexpectedly".into()));
    }

    #[test]
    fn no_response_fails_and_ends_an_open_line() {
        let mut upgrade = Upgrade::new(true);
        upgrade.on_event(downloading(None));
        let (out, step) = upgrade.fail("no response from DevPulse");
        assert_eq!(out, "\n");
        assert_eq!(step, Step::Failed("Update failed: no response from DevPulse".into()));
    }

    #[test]
    fn unknown_phases_and_messages_are_ignored() {
        let mut upgrade = Upgrade::new(false);
        let nothing = (String::new(), Step::Wait);
        assert_eq!(upgrade.on_event(phase(UpgradePhase::Unknown, None, None)), nothing);
        assert_eq!(upgrade.on_event(Event::Server(ServerMessage::Unknown)), nothing);
    }
}
