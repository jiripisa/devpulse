//! Unix-socket client: connects to the DevPulse app and turns its lines into events.

use crate::protocol::{ClientMessage, PROTOCOL_VERSION, ServerMessage};
use std::io::{self, BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

pub const BUNDLE_ID: &str = "io.jp4.devpulse";

/// A write that cannot finish within this time fails, so a stuck app never freezes the UI.
pub const WRITE_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Server(ServerMessage),
    Disconnected,
}

/// `~/Library/Application Support/DevPulse/devpulse.sock`.
pub fn socket_path() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join("Library/Application Support/DevPulse/devpulse.sock")
}

/// Launches the app in the background (`open -g -b`) and waits up to 5 s for the socket.
pub fn ensure_app_running() -> io::Result<()> {
    if UnixStream::connect(socket_path()).is_ok() {
        return Ok(());
    }
    let status = Command::new("open")
        .args(["-g", "-b", BUNDLE_ID])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    if !status.success() {
        return Err(io::Error::other("could not launch DevPulse (open -g -b failed)"));
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if UnixStream::connect(socket_path()).is_ok() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err(io::Error::new(io::ErrorKind::TimedOut, "DevPulse did not open its socket within 5 s"))
}

pub struct Connection {
    stream: UnixStream,
}

impl Connection {
    /// Connects to the app socket and sends `hello`.
    pub fn connect() -> io::Result<Connection> {
        Self::from_stream(UnixStream::connect(socket_path())?)
    }

    /// Wraps an already connected stream, sets the write timeout and sends `hello`.
    pub fn from_stream(stream: UnixStream) -> io::Result<Connection> {
        stream.set_write_timeout(Some(WRITE_TIMEOUT))?;
        let mut conn = Connection { stream };
        conn.send(&ClientMessage::Hello { protocol: PROTOCOL_VERSION })?;
        Ok(conn)
    }

    pub fn send(&mut self, msg: &ClientMessage) -> io::Result<()> {
        let mut line = serde_json::to_vec(msg).map_err(io::Error::other)?;
        line.push(b'\n');
        self.stream.write_all(&line)?;
        self.stream.flush()
    }

    /// A second handle on the same socket, for sending while `lines` owns the reading side.
    pub fn writer(&self) -> io::Result<Connection> {
        Ok(Connection { stream: self.stream.try_clone()? })
    }

    /// Shuts the socket down in both directions; the reader thread then sees EOF and ends.
    pub fn shutdown(&self) {
        let _ = self.stream.shutdown(Shutdown::Both);
    }

    /// Reads the socket on a thread. Malformed lines (e.g. a truncated last line before EOF)
    /// are skipped; EOF or a read error yields `Disconnected` and ends the stream.
    pub fn lines(self) -> mpsc::Receiver<Event> {
        let (tx, rx) = mpsc::channel();
        self.forward(tx, |e| e);
        rx
    }

    /// Like `lines`, but sends each event, wrapped by `wrap`, into an existing channel, so one
    /// receiver can merge the socket with other inputs.
    pub fn forward<T, F>(self, tx: mpsc::Sender<T>, wrap: F)
    where
        T: Send + 'static,
        F: Fn(Event) -> T + Send + 'static,
    {
        thread::spawn(move || {
            let mut reader = BufReader::new(self.stream);
            let mut buf = Vec::new();
            loop {
                buf.clear();
                match reader.read_until(b'\n', &mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                if !buf.ends_with(b"\n") {
                    break; // truncated last line before EOF
                }
                if let Ok(msg) = serde_json::from_slice::<ServerMessage>(&buf)
                    && tx.send(wrap(Event::Server(msg))).is_err()
                {
                    return;
                }
            }
            let _ = tx.send(wrap(Event::Disconnected));
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    fn recv(rx: &mpsc::Receiver<Event>) -> Event {
        rx.recv_timeout(Duration::from_secs(2)).unwrap()
    }

    #[test]
    fn socket_path_is_under_application_support() {
        let p = socket_path();
        assert!(p.ends_with("Library/Application Support/DevPulse/devpulse.sock"));
    }

    #[test]
    fn connect_sends_hello_and_send_writes_lines() {
        let (client, mut server) = UnixStream::pair().unwrap();
        let mut conn = Connection::from_stream(client).unwrap();
        conn.send(&ClientMessage::Refresh).unwrap();
        drop(conn);
        let mut got = String::new();
        server.read_to_string(&mut got).unwrap();
        assert_eq!(got, "{\"type\":\"hello\",\"protocol\":1}\n{\"type\":\"refresh\"}\n");
    }

    #[test]
    fn malformed_and_truncated_lines_are_skipped_and_eof_disconnects() {
        let (client, mut server) = UnixStream::pair().unwrap();
        let rx = Connection::from_stream(client).unwrap().lines();
        server.write_all(b"not json\n").unwrap();
        server.write_all(b"{\"type\":\"upgrade\",\"phase\":\"checking\"}\n").unwrap();
        server.write_all(b"{\"type\":\"snapshot\",\"protocol\":1,\"da").unwrap();
        drop(server);
        assert!(matches!(recv(&rx), Event::Server(ServerMessage::Upgrade { .. })));
        assert_eq!(recv(&rx), Event::Disconnected);
        assert!(rx.recv_timeout(Duration::from_millis(200)).is_err());
    }

    #[test]
    fn forward_wraps_events_into_a_shared_channel() {
        let (client, mut server) = UnixStream::pair().unwrap();
        let (tx, rx) = mpsc::channel();
        Connection::from_stream(client).unwrap().forward(tx, |e| (7, e));
        server.write_all(b"{\"type\":\"upgrade\",\"phase\":\"checking\"}\n").unwrap();
        drop(server);
        let got = |rx: &mpsc::Receiver<(i32, Event)>| rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(matches!(got(&rx), (7, Event::Server(ServerMessage::Upgrade { .. }))));
        assert_eq!(got(&rx), (7, Event::Disconnected));
    }

    #[test]
    fn shutdown_ends_the_reader_and_fails_later_writes() {
        let (client, _server) = UnixStream::pair().unwrap();
        let conn = Connection::from_stream(client).unwrap();
        let mut writer = conn.writer().unwrap();
        let rx = conn.lines();
        writer.shutdown();
        assert_eq!(recv(&rx), Event::Disconnected);
        assert!(writer.send(&ClientMessage::Refresh).is_err());
    }

    #[test]
    fn writes_time_out_instead_of_blocking() {
        let (client, _server) = UnixStream::pair().unwrap();
        let mut conn = Connection::from_stream(client).unwrap();
        assert_eq!(conn.stream.write_timeout().unwrap(), Some(WRITE_TIMEOUT));
        // The peer never reads: once the socket buffer is full, a write fails after the timeout.
        let id = "x".repeat(64 * 1024);
        let big = ClientMessage::Open { kind: crate::protocol::OpenKind::Pr, id };
        let started = Instant::now();
        let failed = (0..64).any(|_| conn.send(&big).is_err());
        assert!(failed);
        assert!(started.elapsed() < Duration::from_secs(5));
    }
}
