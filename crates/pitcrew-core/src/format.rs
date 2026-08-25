//! Presentation logic shared by every front end.
//!
//! This module exists because the bash implementation and the Python GUI each
//! grew their own copy of these — `lib/04-meters.sh` and
//! `gui/pitcrewgui/model.py` — and the two drifted. A byte count that reads
//! `1.5G` in the terminal and `1.50 GB` in the desktop app is a small thing;
//! two different opinions about when a meter turns amber is not.

/// Bytes, at a unit a person would have chosen.
///
/// One decimal place below 10 and none above, because `9.7G` and `512M` are
/// both worth reading and `9.74G` is not. The trailing `.0` is dropped for the
/// same reason: `2G` beats `2.0G` in a column.
pub fn human_bytes(bytes: u64) -> String {
    const UNITS: [(u64, &str); 4] = [
        (1024 * 1024 * 1024 * 1024, "T"),
        (1024 * 1024 * 1024, "G"),
        (1024 * 1024, "M"),
        (1024, "K"),
    ];
    for (scale, suffix) in UNITS {
        if bytes >= scale {
            let value = bytes as f64 / scale as f64;
            return if value < 10.0 {
                let s = format!("{value:.1}");
                format!("{}{suffix}", s.strip_suffix(".0").unwrap_or(&s))
            } else {
                format!("{}{suffix}", value.round() as u64)
            };
        }
    }
    format!("{bytes}B")
}

/// A duration, at the coarsest unit that still says something.
///
/// Two parts at most: nobody reading an uptime measured in days needs the
/// minutes.
pub fn human_duration(secs: i64) -> String {
    if secs < 0 {
        return "—".into();
    }
    let (d, h, m, s) = (
        secs / 86_400,
        (secs % 86_400) / 3600,
        (secs % 3600) / 60,
        secs % 60,
    );
    match (d, h, m) {
        (0, 0, 0) => format!("{s}s"),
        (0, 0, m) => format!("{m}m"),
        (0, h, m) => format!("{h}h{m:02}m"),
        (d, h, _) => format!("{d}d{h:02}h"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_read_the_way_a_person_would_write_them() {
        assert_eq!(human_bytes(0), "0B");
        assert_eq!(human_bytes(512), "512B");
        assert_eq!(human_bytes(3 * 1024 * 1024), "3M");
        assert_eq!(human_bytes(1536 * 1024 * 1024), "1.5G");
        assert_eq!(human_bytes(2 * 1024 * 1024 * 1024), "2G");
    }

    /// `9.7G` is worth reading and `9.74G` is not; above ten the decimal is
    /// noise in a column.
    #[test]
    fn precision_drops_once_the_number_is_big_enough() {
        assert_eq!(human_bytes(9_700_000_000), "9G");
        assert_eq!(human_bytes(12 * 1024 * 1024 * 1024), "12G");
        assert_eq!(human_bytes(1024 * 1024 * 1024 + 512 * 1024 * 1024), "1.5G");
    }

    /// A three-megabyte process used to render as `0.0G`, which reads as
    /// broken rather than as small.
    #[test]
    fn a_small_process_does_not_read_as_zero() {
        assert_eq!(human_bytes(3_200_000), "3.1M");
        assert_ne!(human_bytes(3_200_000), "0.0G");
    }

    #[test]
    fn durations_drop_the_units_nobody_reads() {
        assert_eq!(human_duration(0), "0s");
        assert_eq!(human_duration(45), "45s");
        assert_eq!(human_duration(90), "1m");
        assert_eq!(human_duration(90 * 60), "1h30m");
        assert_eq!(human_duration(26 * 3600), "1d02h");
        assert_eq!(human_duration(-1), "—");
    }
}
