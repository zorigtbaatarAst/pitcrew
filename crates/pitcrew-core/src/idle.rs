//! How long a component has provably done nothing.
//!
//! "What can I safely stop?" is unanswerable without this, and the alternative
//! — asking someone to remember which service they last touched — is not an
//! answer.
//!
//! **The persistence is the interesting part, and it must not be simplified
//! into trusting a timestamp.** pitcrew has no daemon, so between one run and
//! the next there is nobody watching. A naive implementation would store "idle
//! since T" and carry it forward, which turns a measurement into a guess — and
//! the guess puts busy services on a list of things it is safe to stop.
//!
//! Instead the *monotonic CPU counter* is stored alongside the timestamp. On
//! the next run the counter is compared against the current one over the
//! elapsed wall clock: if it has not moved past the idle threshold, the service
//! **provably** did no work while nobody was watching, so the old timestamp is
//! carried forward. Otherwise the clock restarts. A changed pid discards the
//! record entirely — it is a different process.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// One component's persisted idleness.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Record {
    pid: u32,
    /// Cumulative CPU milliseconds at `last_seen_at`.
    cpu_ms: u64,
    /// When this component was last observed doing work.
    last_work_at: i64,
    /// When the record was written.
    last_seen_at: i64,
}

pub struct Idle {
    file: PathBuf,
    records: HashMap<String, Record>,
    /// CPU percent below which a component counts as doing nothing.
    threshold_pct: f64,
}

impl Idle {
    pub fn path_for(home: &Path, session: &str) -> PathBuf {
        home.join(session).join("idle")
    }

    pub fn load(file: &Path) -> Idle {
        let mut records = HashMap::new();
        if let Ok(text) = std::fs::read_to_string(file) {
            for line in text.lines() {
                if let Some((name, r)) = parse(line) {
                    records.insert(name, r);
                }
            }
        }
        Idle {
            file: file.to_path_buf(),
            records,
            threshold_pct: std::env::var("PITCREW_IDLE_CPU")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(2.0),
        }
    }

    /// Observe a component and return how many seconds it has been idle, or
    /// `None` when there is nothing to go on — no CPU baseline yet, or it is
    /// not running.
    ///
    /// `cpu_pct` is the rate over the current sampling window; `cpu_ms` is the
    /// cumulative counter that survives between runs.
    pub fn observe(
        &mut self,
        comp: &str,
        pid: Option<u32>,
        cpu_pct: Option<f64>,
        cpu_ms: u64,
        now: i64,
    ) -> Option<i64> {
        let pid = pid?;
        let previous = self.records.get(comp).copied();

        let last_work_at = match previous {
            // A different process entirely. Nothing carries over.
            Some(p) if p.pid != pid => now,
            Some(p) => {
                let gap = (now - p.last_seen_at).max(0);
                let moved = cpu_ms.saturating_sub(p.cpu_ms);
                if gap > 0 {
                    // The proof: did the counter move enough, over the wall
                    // clock that actually elapsed, to count as work?
                    let pct_over_gap = (moved as f64 / (gap as f64 * 1000.0)) * 100.0;
                    if pct_over_gap > self.threshold_pct {
                        now
                    } else {
                        // It provably did nothing while nobody was watching.
                        p.last_work_at
                    }
                } else {
                    // Same second: fall back to the live rate, which is the
                    // only signal available over a zero-length window.
                    match cpu_pct {
                        Some(rate) if rate > self.threshold_pct => now,
                        _ => p.last_work_at,
                    }
                }
            }
            // First sighting. Without a baseline there is no measurement to
            // report — the clock starts now and says zero.
            None => now,
        };

        self.records.insert(
            comp.to_string(),
            Record {
                pid,
                cpu_ms,
                last_work_at,
                last_seen_at: now,
            },
        );

        // A first sighting has a baseline of zero elapsed, which is honest:
        // "idle for 0s" is different from "no idea".
        Some((now - last_work_at).max(0))
    }

    /// Forget a component — it stopped, so its record describes a process that
    /// no longer exists.
    pub fn forget(&mut self, comp: &str) {
        self.records.remove(comp);
    }

    pub fn save(&self) -> std::io::Result<()> {
        if let Some(dir) = self.file.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let mut names: Vec<&String> = self.records.keys().collect();
        names.sort();
        let body: String = names
            .iter()
            .map(|n| {
                let r = &self.records[*n];
                format!(
                    "{n}={} {} {} {}\n",
                    r.pid, r.cpu_ms, r.last_work_at, r.last_seen_at
                )
            })
            .collect();
        std::fs::write(&self.file, body)
    }
}

fn parse(line: &str) -> Option<(String, Record)> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let (name, rest) = line.split_once('=')?;
    let mut f = rest.split_whitespace();
    Some((
        name.to_string(),
        Record {
            pid: f.next()?.parse().ok()?,
            cpu_ms: f.next()?.parse().ok()?,
            last_work_at: f.next()?.parse().ok()?,
            last_seen_at: f.next()?.parse().ok()?,
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("pitcrew-idle-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d.join("idle")
    }

    #[test]
    fn a_component_that_is_not_running_has_no_measurement() {
        let mut i = Idle::load(&tmp("none"));
        assert_eq!(i.observe("be-a", None, Some(0.0), 0, 1000), None);
    }

    #[test]
    fn a_first_sighting_starts_the_clock_at_zero() {
        let mut i = Idle::load(&tmp("first"));
        assert_eq!(i.observe("be-a", Some(1), Some(0.0), 5000, 1000), Some(0));
    }

    /// The whole point. Between two runs nobody is watching, and the counter is
    /// what proves the service did nothing — not the fact that we wrote down a
    /// timestamp before we stopped looking.
    #[test]
    fn a_counter_that_did_not_move_carries_the_old_timestamp_forward() {
        let f = tmp("carry");
        let mut i = Idle::load(&f);
        i.observe("be-a", Some(1), Some(0.0), 5000, 1000);
        i.save().unwrap();

        // An hour later, in a new process, with the counter unchanged.
        let mut later = Idle::load(&f);
        let idle = later
            .observe("be-a", Some(1), Some(0.0), 5000, 4600)
            .unwrap();
        assert_eq!(idle, 3600, "it provably did no work for the whole hour");
    }

    /// And a counter that moved restarts the clock, because the service was
    /// working while nobody was watching.
    #[test]
    fn a_counter_that_moved_restarts_the_clock() {
        let f = tmp("moved");
        let mut i = Idle::load(&f);
        i.observe("be-a", Some(1), Some(0.0), 5000, 1000);
        i.save().unwrap();

        // 3600 seconds elapsed; 3.6M ms of CPU is a full core the whole time.
        let mut later = Idle::load(&f);
        let idle = later
            .observe("be-a", Some(1), Some(100.0), 5000 + 3_600_000, 4600)
            .unwrap();
        assert_eq!(idle, 0, "it was busy, so it is not idle");
    }

    /// A little CPU is not work. A JVM ticking over on a timer would otherwise
    /// never be reported as idle, which is exactly the service you want to know
    /// about.
    #[test]
    fn a_trickle_of_cpu_is_still_idle() {
        let f = tmp("trickle");
        let mut i = Idle::load(&f);
        i.observe("be-a", Some(1), Some(0.0), 0, 1000);
        i.save().unwrap();

        // 1% of one core over the hour — under the 2% default.
        let mut later = Idle::load(&f);
        let idle = later
            .observe("be-a", Some(1), Some(1.0), 36_000, 4600)
            .unwrap();
        assert_eq!(idle, 3600);
    }

    /// A changed pid is a different process, whatever the counter says.
    #[test]
    fn a_restarted_component_discards_its_record() {
        let f = tmp("restart");
        let mut i = Idle::load(&f);
        i.observe("be-a", Some(1), Some(0.0), 5000, 1000);
        i.save().unwrap();

        let mut later = Idle::load(&f);
        let idle = later
            .observe("be-a", Some(999), Some(0.0), 5000, 4600)
            .unwrap();
        assert_eq!(idle, 0, "a new process has no history");
    }

    #[test]
    fn records_round_trip_through_the_file() {
        let f = tmp("roundtrip");
        let mut i = Idle::load(&f);
        i.observe("be-a", Some(7), Some(0.0), 1234, 1000);
        i.observe("fe-a", Some(8), Some(0.0), 5678, 1000);
        i.save().unwrap();

        let reread = Idle::load(&f);
        assert_eq!(reread.records.len(), 2);
        assert_eq!(reread.records["be-a"].pid, 7);
        assert_eq!(reread.records["fe-a"].cpu_ms, 5678);
    }

    /// A hand edit or a newer format should cost that one line, not the tool.
    #[test]
    fn an_unreadable_line_is_skipped() {
        let f = tmp("corrupt");
        std::fs::write(&f, "# comment\nbe-a=1 2 3 4\ngarbage\nfe-a=nope\n").unwrap();
        let i = Idle::load(&f);
        assert_eq!(i.records.len(), 1);
        assert!(i.records.contains_key("be-a"));
    }

    #[test]
    fn forgetting_a_component_drops_its_record() {
        let mut i = Idle::load(&tmp("forget"));
        i.observe("be-a", Some(1), Some(0.0), 0, 1000);
        i.forget("be-a");
        assert!(i.records.is_empty());
    }
}
