//! Opening a link in the browser with `/usr/bin/open`. The TUI runs on the Mac the browser runs
//! on, so this needs neither the app nor the socket.

use std::io;
use std::process::{Command, Stdio};
use std::thread;

/// A link `open` may get: `http://` or `https://` (the scheme in any case) and nothing else,
/// since `open` also starts apps and opens files (`file:`, custom schemes).
pub fn is_web(url: &str) -> bool {
    ["http://", "https://"].iter().any(|scheme| url.get(..scheme.len()).is_some_and(|s| s.eq_ignore_ascii_case(scheme)))
}

/// Opens `url` with `opener` when it is a web link; any other link is refused unopened.
pub fn open(url: &str, opener: impl FnOnce(&str) -> io::Result<()>) -> io::Result<()> {
    if !is_web(url) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a web link"));
    }
    opener(url)
}

/// The real opener: starts `/usr/bin/open URL` without a shell, the URL as its one argument and
/// no terminal attached (stdin, stdout and stderr null), and does not wait for it; a thread
/// reaps it, so no zombie stays behind.
pub fn system(url: &str) -> io::Result<()> {
    let mut child = Command::new("/usr/bin/open")
        .arg(url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Opens `url` with an opener that only records what it was given.
    fn opened(url: &str) -> (io::Result<()>, Vec<String>) {
        let seen = RefCell::new(Vec::new());
        let result = open(url, |u| {
            seen.borrow_mut().push(u.to_string());
            Ok(())
        });
        (result, seen.into_inner())
    }

    #[test]
    fn web_links_go_to_the_opener_unchanged() {
        for url in [
            "https://example.atlassian.net/browse/STORE-2290",
            "http://localhost:8080/browse/STORE-1?focus=a%20b",
            "HTTPS://github.com/acmecorp/store/pull/1234",
        ] {
            let (result, seen) = opened(url);
            assert!(result.is_ok(), "{url}");
            assert_eq!(seen, [url]);
            assert!(is_web(url), "{url}");
        }
    }

    #[test]
    fn other_links_are_never_opened() {
        for url in [
            "file:///System/Applications/Calculator.app",
            "javascript:alert(1)",
            "ftp://example.test/STORE-1",
            "mailto:dev@example.test",
            "-a Calculator",
            " https://example.test",
            "https:/example.test",
            "httpsx://example.test",
            "",
        ] {
            let (result, seen) = opened(url);
            assert!(result.is_err(), "{url:?}");
            assert!(seen.is_empty(), "{url:?}");
            assert!(!is_web(url), "{url:?}");
        }
    }

    #[test]
    fn a_failing_opener_is_an_error() {
        assert!(open("https://example.test", |_| Err(io::Error::other("no open"))).is_err());
    }
}
