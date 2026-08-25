//! The error radar: how many error lines a component has logged.
//!
//! Read **incrementally**, from a retained byte offset — never by re-reading
//! the file. A dashboard refreshing every second over a log that a chatty JVM
//! is appending to would otherwise re-scan megabytes per frame, and the count
//! is wanted on every frame.
//!
//! Two details are the whole difficulty, and both were bugs in the shell
//! version before they were features:
//!
//! * **A trailing partial line is held back.** A log is being appended to while
//!   it is read, so the last line is frequently half-written. Counting it now
//!   and again when it is complete double-counts; dropping it loses a real
//!   error. It is kept and prepended to the next read.
//! * **A file that shrank was rotated.** The offset means nothing against the
//!   new file, so both it and the count reset. Without this the scanner seeks
//!   past the end of a fresh log and reports zero errors forever.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use regex::Regex;

/// The default pattern. A Spring backend and a Vite frontend do not log
/// failures the same way, so this is user-overridable per project.
pub const DEFAULT_PATTERN: &str = "ERROR|FATAL|Exception|UnhandledRejection";

pub struct ErrScan {
    pattern: Regex,
    /// comp → how far into its log we have read.
    offsets: HashMap<String, u64>,
    counts: HashMap<String, u64>,
    /// comp → a trailing line that had no newline yet.
    partial: HashMap<String, String>,
}

impl ErrScan {
    /// Falls back to the default pattern when a project's own does not compile,
    /// rather than refusing to draw: a bad regex in a config should cost the
    /// error column, not the dashboard.
    pub fn new(pattern: &str) -> (ErrScan, Option<String>) {
        let (re, warning) = match Regex::new(pattern) {
            Ok(re) => (re, None),
            Err(e) => (
                Regex::new(DEFAULT_PATTERN).expect("the default pattern compiles"),
                Some(format!(
                    "error_pattern: {e} — falling back to the default pattern"
                )),
            ),
        };
        (
            ErrScan {
                pattern: re,
                offsets: HashMap::new(),
                counts: HashMap::new(),
                partial: HashMap::new(),
            },
            warning,
        )
    }

    pub fn count(&self, comp: &str) -> u64 {
        self.counts.get(comp).copied().unwrap_or(0)
    }

    /// Read whatever is new in this component's log and update its count.
    pub fn scan(&mut self, comp: &str, log: &Path) {
        let Ok(mut file) = std::fs::File::open(log) else {
            return;
        };
        let Ok(meta) = file.metadata() else { return };
        let size = meta.len();
        let offset = self.offsets.entry(comp.to_string()).or_insert(0);

        // Shrunk: the log was rotated or truncated, so the offset means nothing
        // against this file and the count belongs to a run that is over.
        if size < *offset {
            *offset = 0;
            self.counts.insert(comp.to_string(), 0);
            self.partial.remove(comp);
        }
        if size == *offset {
            return;
        }

        if file.seek(SeekFrom::Start(*offset)).is_err() {
            return;
        }
        let mut fresh = String::new();
        // Lossy on purpose: a log is captured verbatim and may hold a
        // half-written multibyte character at the boundary. Refusing to count
        // the whole read because of one is worse than one mangled glyph.
        let mut bytes = Vec::new();
        if file.read_to_end(&mut bytes).is_err() {
            return;
        }
        fresh.push_str(&String::from_utf8_lossy(&bytes));
        *offset = size;

        let held = self.partial.remove(comp).unwrap_or_default();
        let text = held + &fresh;
        // `split('\n')` rather than `lines()`: the last element is the piece
        // after the final newline, which is exactly the partial to hold back.
        let mut parts: Vec<&str> = text.split('\n').collect();
        let tail = parts.pop().unwrap_or("");
        if !tail.is_empty() {
            self.partial.insert(comp.to_string(), tail.to_string());
        }

        let hits = parts.iter().filter(|l| self.pattern.is_match(l)).count() as u64;
        *self.counts.entry(comp.to_string()).or_insert(0) += hits;
    }

    /// Forget a component's position — used when its log is about to be rotated
    /// by a restart, so the next scan starts from the new file.
    pub fn reset(&mut self, comp: &str) {
        self.offsets.remove(comp);
        self.counts.remove(comp);
        self.partial.remove(comp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn tmp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("pitcrew-err-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d.join("x.log")
    }

    fn append(p: &Path, text: &str) {
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(p)
            .unwrap();
        f.write_all(text.as_bytes()).unwrap();
    }

    #[test]
    fn it_counts_matching_lines() {
        let log = tmp("count");
        append(&log, "fine\nERROR boom\nalso fine\nFATAL worse\n");
        let (mut s, w) = ErrScan::new(DEFAULT_PATTERN);
        assert!(w.is_none());
        s.scan("be-a", &log);
        assert_eq!(s.count("be-a"), 2);
    }

    /// The count accumulates across frames rather than being recomputed, which
    /// is the whole reason for the retained offset.
    #[test]
    fn a_second_scan_only_reads_what_is_new() {
        let log = tmp("incremental");
        append(&log, "ERROR one\n");
        let (mut s, _) = ErrScan::new(DEFAULT_PATTERN);
        s.scan("be-a", &log);
        assert_eq!(s.count("be-a"), 1);

        s.scan("be-a", &log);
        assert_eq!(s.count("be-a"), 1, "the same line was counted twice");

        append(&log, "ERROR two\n");
        s.scan("be-a", &log);
        assert_eq!(s.count("be-a"), 2);
    }

    /// A log is appended to while it is read, so the last line is frequently
    /// half-written. Counting it now and again when it completes double-counts.
    #[test]
    fn a_half_written_line_is_counted_once_when_it_completes() {
        let log = tmp("partial");
        append(&log, "ERROR compl");
        let (mut s, _) = ErrScan::new(DEFAULT_PATTERN);
        s.scan("be-a", &log);
        assert_eq!(s.count("be-a"), 0, "an incomplete line is not a line yet");

        append(&log, "ete\n");
        s.scan("be-a", &log);
        assert_eq!(s.count("be-a"), 1, "and it is counted exactly once");
    }

    /// Without this the scanner seeks past the end of a fresh log and reports
    /// zero errors forever.
    #[test]
    fn a_rotated_log_resets_the_offset_and_the_count() {
        let log = tmp("rotate");
        append(&log, "ERROR old\nERROR older\n");
        let (mut s, _) = ErrScan::new(DEFAULT_PATTERN);
        s.scan("be-a", &log);
        assert_eq!(s.count("be-a"), 2);

        std::fs::write(&log, "ERROR fresh\n").unwrap();
        s.scan("be-a", &log);
        assert_eq!(s.count("be-a"), 1, "the count belongs to the new run");
    }

    /// A bad regex in a config should cost the error column, not the dashboard.
    #[test]
    fn an_invalid_pattern_falls_back_and_says_so() {
        let (mut s, warning) = ErrScan::new("([unclosed");
        assert!(warning.expect("a warning").contains("error_pattern"));
        let log = tmp("badpattern");
        append(&log, "ERROR still counted\n");
        s.scan("be-a", &log);
        assert_eq!(s.count("be-a"), 1);
    }

    #[test]
    fn a_missing_log_is_not_an_error() {
        let (mut s, _) = ErrScan::new(DEFAULT_PATTERN);
        s.scan("be-a", Path::new("/nonexistent/x.log"));
        assert_eq!(s.count("be-a"), 0);
    }

    /// A project pattern replaces the default entirely — a Vite frontend does
    /// not log failures the way a Spring backend does.
    #[test]
    fn a_project_pattern_replaces_the_default() {
        let log = tmp("custom");
        append(&log, "ERROR ignored\nBOOM counted\n");
        let (mut s, _) = ErrScan::new("BOOM|KABOOM");
        s.scan("be-a", &log);
        assert_eq!(s.count("be-a"), 1);
    }
}
