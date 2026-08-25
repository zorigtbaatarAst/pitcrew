//! Docker dependencies — the containers a stack needs but does not own.
//!
//! **One batched call, on a slow clock.** `docker inspect` costs about 100ms,
//! and the shell implementation once ran it once per dependency per frame. The
//! fork budget that forced the fix is gone; the fix is kept, because a
//! dashboard that spends half a second of somebody's laptop per second asking
//! Docker the same question is worse behaviour, not better.

use std::collections::HashMap;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub struct Deps {
    last: Option<Instant>,
    state: HashMap<String, bool>,
    pub interval: Duration,
    /// False once `docker` has been found to be absent, so the miss is not
    /// re-paid on every poll.
    available: Option<bool>,
}

impl Default for Deps {
    fn default() -> Self {
        Deps {
            last: None,
            state: HashMap::new(),
            interval: Duration::from_secs(10),
            available: None,
        }
    }
}

impl Deps {
    /// Whether each named dependency is running, refreshing at most once per
    /// interval.
    pub fn poll(&mut self, names: &[String]) -> &HashMap<String, bool> {
        if names.is_empty() {
            return &self.state;
        }
        if self.last.is_some_and(|t| t.elapsed() < self.interval) {
            return &self.state;
        }
        self.last = Some(Instant::now());

        if self.available == Some(false) {
            return &self.state;
        }

        // One call for every dependency, not one per dependency. The format
        // string makes the output trivially parseable, which is why this does
        // not go anywhere near `docker ps` and its columns.
        let mut cmd = Command::new("docker");
        cmd.arg("inspect")
            .arg("-f")
            .arg("{{.Name}}={{.State.Running}}")
            .args(names)
            .stdin(Stdio::null())
            .stderr(Stdio::null());

        let Ok(out) = cmd.output() else {
            // Not an error worth reporting every ten seconds: a project with
            // docker deps on a machine without docker is a `doctor` finding.
            self.available = Some(false);
            return &self.state;
        };
        self.available = Some(true);

        // Reset rather than merge: a container that has been removed should
        // stop being reported as running, and `docker inspect` simply omits it.
        self.state.clear();
        for name in names {
            self.state.insert(name.clone(), false);
        }
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            let Some((name, running)) = line.rsplit_once('=') else {
                continue;
            };
            // Docker prefixes container names with a slash.
            let name = name.trim_start_matches('/');
            if self.state.contains_key(name) {
                self.state
                    .insert(name.to_string(), running.trim() == "true");
            }
        }
        &self.state
    }

    pub fn state(&self) -> &HashMap<String, bool> {
        &self.state
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_dependencies_means_no_call_and_no_state() {
        let mut d = Deps::default();
        assert!(d.poll(&[]).is_empty());
        assert!(d.last.is_none(), "nothing should have been polled");
    }

    /// The interval is the point: a dashboard refreshing every second must not
    /// pay 100ms of docker per frame.
    #[test]
    fn a_second_poll_inside_the_interval_does_not_re_ask() {
        let mut d = Deps::default();
        let names = vec!["postgres".to_string()];
        d.poll(&names);
        let first = d.last;
        d.poll(&names);
        assert_eq!(d.last, first, "it asked docker again inside the interval");
    }

    /// A machine without docker should cost one failed spawn, not one per poll.
    #[test]
    fn a_missing_docker_is_only_discovered_once() {
        let mut d = Deps {
            available: Some(false),
            ..Default::default()
        };
        d.poll(&["postgres".to_string()]);
        assert!(d.state.is_empty());
    }
}
