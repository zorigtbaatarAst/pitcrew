//! `<root>/.pitcrew/logs` — where a component's state actually lives.
//!
//! **There is no daemon and nothing is kept in sync.** A component's state is
//! these files plus the OS, re-derived every frame, which is why there is
//! nothing to reconcile when pitcrew is not running. Three files per component:
//!
//! | file | meaning |
//! |---|---|
//! | `<comp>.pid` | the wrapper's pid. Its **absence** is what makes a component "down", and a leftover one is what makes it "crashed" — `stop` removes it on a clean stop, precisely so that a surviving one means something died. |
//! | `<comp>.exit` | `<code> <unix seconds>`, written by the wrapper as the service ends. Turns "crashed" into "exited 1 at 12:04", which is the first thing anyone actually wants to know. |
//! | `<comp>.log` | stdout and stderr, verbatim — ANSI escapes included, because stripping them would throw away colour the log view knows how to render. |

use std::path::{Path, PathBuf};

/// How a run ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Exit {
    pub code: i32,
    pub at: i64,
}

#[derive(Debug, Clone)]
pub struct LogDir {
    pub path: PathBuf,
}

impl LogDir {
    pub fn new(root: &Path) -> LogDir {
        LogDir {
            path: root.join(".pitcrew/logs"),
        }
    }

    pub fn ensure(&self) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.path)
    }

    pub fn log(&self, comp: &str) -> PathBuf {
        self.path.join(format!("{comp}.log"))
    }
    pub fn pidfile(&self, comp: &str) -> PathBuf {
        self.path.join(format!("{comp}.pid"))
    }
    pub fn exitfile(&self, comp: &str) -> PathBuf {
        self.path.join(format!("{comp}.exit"))
    }

    /// The recorded pid, if there is a pidfile with a number in it.
    pub fn pid(&self, comp: &str) -> Option<u32> {
        std::fs::read_to_string(self.pidfile(comp))
            .ok()?
            .trim()
            .parse()
            .ok()
    }

    /// When the pidfile was written — which is when the component started.
    ///
    /// Taken from the file's mtime rather than recorded separately: there is
    /// no extra bookkeeping to get out of step, and the file has to exist for
    /// the component to be running at all.
    pub fn started_at(&self, comp: &str) -> Option<std::time::SystemTime> {
        std::fs::metadata(self.pidfile(comp)).ok()?.modified().ok()
    }

    /// Did this pidfile survive a reboot?
    ///
    /// A recorded pid that predates boot cannot be the process that wrote it,
    /// whatever is running under that number now — and after a reboot pid 4242
    /// is very likely to be *something*. Reporting that as the component
    /// running is worse than reporting it as down.
    pub fn predates_boot(&self, comp: &str, boot: u64) -> bool {
        let Some(started) = self.started_at(comp) else {
            return false;
        };
        started
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() < boot)
            .unwrap_or(false)
    }

    /// Remove the pidfile. This is what makes a clean stop distinguishable
    /// from a crash, so it must happen on every successful stop.
    pub fn clear_pid(&self, comp: &str) {
        let _ = std::fs::remove_file(self.pidfile(comp));
    }

    pub fn exit(&self, comp: &str) -> Option<Exit> {
        let text = std::fs::read_to_string(self.exitfile(comp)).ok()?;
        let mut parts = text.split_whitespace();
        let code = parts.next()?.parse().ok()?;
        // A record with no timestamp is still a record: the code is the part
        // anyone reads.
        let at = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
        Some(Exit { code, at })
    }

    pub fn clear_exit(&self, comp: &str) {
        let _ = std::fs::remove_file(self.exitfile(comp));
    }

    /// Roll the previous run's log aside instead of erasing it.
    ///
    /// The old behaviour was to truncate, which meant restarting a service
    /// destroyed the log you were restarting it to read. The previous process
    /// is already dead by the time this runs, so a rename is safe — no open
    /// descriptor still points at the file.
    ///
    /// `keep == 0` truncates in place, which is what someone who set it to
    /// zero asked for.
    pub fn rotate(&self, comp: &str, keep: usize) -> std::io::Result<()> {
        let f = self.log(comp);
        let empty = std::fs::metadata(&f).map(|m| m.len() == 0).unwrap_or(true);
        if empty || keep == 0 {
            return std::fs::write(&f, b"");
        }
        for i in (1..keep).rev() {
            let from = self.path.join(format!("{comp}.log.{i}"));
            if from.exists() {
                let _ = std::fs::rename(&from, self.path.join(format!("{comp}.log.{}", i + 1)));
            }
        }
        std::fs::rename(&f, self.path.join(format!("{comp}.log.1")))?;
        std::fs::write(&f, b"")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> LogDir {
        let d = std::env::temp_dir().join(format!("pitcrew-logdir-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let l = LogDir::new(&d);
        l.ensure().unwrap();
        l
    }

    #[test]
    fn a_pid_round_trips_and_clearing_removes_it() {
        let l = tmp("pid");
        assert_eq!(l.pid("be-a"), None, "no pidfile means down");
        std::fs::write(l.pidfile("be-a"), "4242\n").unwrap();
        assert_eq!(l.pid("be-a"), Some(4242));
        l.clear_pid("be-a");
        assert_eq!(l.pid("be-a"), None);
    }

    /// A pidfile with something unparseable in it is not a running component.
    /// Reading it as a pid would be a number, and a number is a process.
    #[test]
    fn a_corrupt_pidfile_reads_as_no_pid() {
        let l = tmp("corrupt");
        std::fs::write(l.pidfile("be-a"), "not a number\n").unwrap();
        assert_eq!(l.pid("be-a"), None);
        std::fs::write(l.pidfile("be-a"), "").unwrap();
        assert_eq!(l.pid("be-a"), None);
    }

    /// "crashed" on its own tells you nothing actionable.
    #[test]
    fn an_exit_record_carries_the_code_and_the_time() {
        let l = tmp("exit");
        assert_eq!(l.exit("be-a"), None);
        std::fs::write(l.exitfile("be-a"), "1 1787617812\n").unwrap();
        assert_eq!(
            l.exit("be-a"),
            Some(Exit {
                code: 1,
                at: 1787617812
            })
        );
    }

    /// A record with no timestamp is still a record — the code is the part
    /// anyone reads.
    #[test]
    fn an_exit_record_without_a_time_still_reports_the_code() {
        let l = tmp("exit-notime");
        std::fs::write(l.exitfile("be-a"), "137\n").unwrap();
        assert_eq!(l.exit("be-a"), Some(Exit { code: 137, at: 0 }));
    }

    /// After a reboot, pid 4242 is very likely to be *something*. Reporting
    /// that as the component running is worse than reporting it as down.
    #[test]
    fn a_pidfile_older_than_the_boot_is_recognised_as_stale() {
        let l = tmp("boot");
        std::fs::write(l.pidfile("be-a"), "1\n").unwrap();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert!(
            !l.predates_boot("be-a", now.saturating_sub(3600)),
            "written after boot"
        );
        assert!(l.predates_boot("be-a", now + 3600), "written before boot");
        assert!(
            !l.predates_boot("no-such-comp", now),
            "no pidfile is not stale"
        );
    }

    /// Restarting a service used to destroy the log you were restarting it to
    /// read.
    #[test]
    fn rotating_keeps_the_previous_run_instead_of_erasing_it() {
        let l = tmp("rotate");
        std::fs::write(l.log("be-a"), "first run\n").unwrap();
        l.rotate("be-a", 2).unwrap();
        assert_eq!(std::fs::read_to_string(l.log("be-a")).unwrap(), "");
        assert_eq!(
            std::fs::read_to_string(l.path.join("be-a.log.1")).unwrap(),
            "first run\n"
        );

        std::fs::write(l.log("be-a"), "second run\n").unwrap();
        l.rotate("be-a", 2).unwrap();
        assert_eq!(
            std::fs::read_to_string(l.path.join("be-a.log.1")).unwrap(),
            "second run\n"
        );
        assert_eq!(
            std::fs::read_to_string(l.path.join("be-a.log.2")).unwrap(),
            "first run\n"
        );
    }

    /// Someone who set keep to zero asked for the old behaviour.
    #[test]
    fn keeping_zero_truncates_in_place() {
        let l = tmp("rotate0");
        std::fs::write(l.log("be-a"), "gone\n").unwrap();
        l.rotate("be-a", 0).unwrap();
        assert_eq!(std::fs::read_to_string(l.log("be-a")).unwrap(), "");
        assert!(!l.path.join("be-a.log.1").exists());
    }

    #[test]
    fn rotating_an_empty_log_does_not_create_a_useless_archive() {
        let l = tmp("rotate-empty");
        std::fs::write(l.log("be-a"), "").unwrap();
        l.rotate("be-a", 2).unwrap();
        assert!(!l.path.join("be-a.log.1").exists());
    }
}
