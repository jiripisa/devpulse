//! ISO 8601 timestamps from the protocol and the short relative ages shown in the UI.

use std::time::{Duration, SystemTime};

/// Parses `YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)`, the form Swift's `.iso8601` strategy writes.
pub fn parse_iso8601(s: &str) -> Option<SystemTime> {
    let b = s.as_bytes();
    let num = |from: usize, len: usize| -> Option<i64> {
        let digits = b.get(from..from + len)?;
        digits.iter().all(u8::is_ascii_digit).then(|| {
            digits.iter().fold(0i64, |n, d| n * 10 + i64::from(d - b'0'))
        })
    };
    let sep = |at: usize, c: u8| b.get(at) == Some(&c);
    if !(sep(4, b'-') && sep(7, b'-') && sep(10, b'T') && sep(13, b':') && sep(16, b':')) {
        return None;
    }
    let (year, month, day) = (num(0, 4)?, num(5, 2)?, num(8, 2)?);
    let (hour, minute, second) = (num(11, 2)?, num(14, 2)?, num(17, 2)?);
    let date_ok = (1..=12).contains(&month) && (1..=31).contains(&day);
    if !date_ok || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    let mut i = 19;
    let mut nanos = 0u32;
    if sep(i, b'.') {
        let frac: Vec<u8> = b[i + 1..].iter().copied().take_while(u8::is_ascii_digit).collect();
        if frac.is_empty() {
            return None;
        }
        for (k, d) in frac.iter().take(9).enumerate() {
            nanos += u32::from(d - b'0') * 10u32.pow(8 - k as u32);
        }
        i += 1 + frac.len();
    }
    let offset = match b.get(i..)? {
        b"Z" => 0,
        [sign @ (b'+' | b'-'), _, _, b':', _, _] => {
            let minutes = num(i + 1, 2)? * 60 + num(i + 4, 2)?;
            if *sign == b'+' { minutes * 60 } else { -minutes * 60 }
        }
        _ => return None,
    };
    let day_secs = hour * 3600 + minute * 60 + second;
    let secs = days_from_civil(year, month, day) * 86_400 + day_secs - offset;
    let secs = u64::try_from(secs).ok()?;
    Some(SystemTime::UNIX_EPOCH + Duration::new(secs, nanos))
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// A short age: `now` under a minute, then `5m`, `3h`, `2d`. A time in the future reads `now`.
pub fn age(since: SystemTime, now: SystemTime) -> String {
    let secs = now.duration_since(since).map_or(0, |d| d.as_secs());
    match secs {
        0..60 => "now".to_string(),
        60..3600 => format!("{}m", secs / 60),
        3600..86_400 => format!("{}h", secs / 3600),
        _ => format!("{}d", secs / 86_400),
    }
}

/// The age of an ISO 8601 timestamp, or `None` when it does not parse.
pub fn age_of(iso: &str, now: SystemTime) -> Option<String> {
    parse_iso8601(iso).map(|t| age(t, now))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(secs: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(secs)
    }

    #[test]
    fn parses_utc_fractional_and_offset_forms() {
        // 2026-11-19T10:00:00Z = 1795082400
        assert_eq!(parse_iso8601("2026-11-19T10:00:00Z"), Some(at(1_795_082_400)));
        assert_eq!(
            parse_iso8601("2026-11-19T10:00:00.250Z"),
            Some(at(1_795_082_400) + Duration::from_millis(250))
        );
        assert_eq!(parse_iso8601("2026-11-19T11:30:00+01:30"), Some(at(1_795_082_400)));
        assert_eq!(parse_iso8601("2026-11-19T08:00:00-02:00"), Some(at(1_795_082_400)));
        assert_eq!(parse_iso8601("1970-01-01T00:00:00Z"), Some(at(0)));
        assert_eq!(parse_iso8601("2024-02-29T00:00:00Z"), Some(at(1_709_164_800)));
    }

    #[test]
    fn rejects_garbage_without_panicking() {
        for s in [
            "",
            "2026",
            "2026-13-01T00:00:00Z",
            "2026-11-19T25:00:00Z",
            "2026-11-19 10:00:00Z",
            "2026-11-19T10:00:00",
            "2026-11-19T10:00:00+0100",
            "žluťoučký kůň",
            "2026-11-19T10:00:00.Z",
        ] {
            assert_eq!(parse_iso8601(s), None, "{s}");
        }
    }

    #[test]
    fn ages_are_short() {
        let now = at(1_000_000);
        let ago = |s: u64| age(at(1_000_000 - s), now);
        assert_eq!(ago(0), "now");
        assert_eq!(ago(59), "now");
        assert_eq!(ago(60), "1m");
        assert_eq!(ago(150), "2m");
        assert_eq!(ago(3599), "59m");
        assert_eq!(ago(3600), "1h");
        assert_eq!(ago(86_399), "23h");
        assert_eq!(ago(3 * 86_400 + 5), "3d");
        assert_eq!(age(at(1_000_100), now), "now");
    }
}
