//! Talking to the CLI.
//!
//! **The GUI is a renderer, not a second monitor.** Everything it shows arrives
//! through `pitcrew json --watch`. It must never read `/proc`, run `ps`, or
//! decide for itself whether the stack is healthy — the verdict travels in the
//! stream's `health` object for exactly that reason. If the GUI needs something
//! it does not have, extend the state object; do not re-derive it here.
//!
//! It **streams** rather than polling `status --json` on a timer because CPU% is
//! a delta between snapshots: a fresh process has no previous sample and would
//! report null cpu forever.
//!
//! The Python version's sharpest edge was reading that pipe. `read_line_async`
//! reports EOF as `(b"", 0)` and a blank line as `(b"", 0)`, so anything built
//! on it has to choose between stopping at the first empty line and spinning the
//! main loop at EOF — three separate "the log view is frozen" bugs came out of
//! that one ambiguity. Here a worker thread owns a blocking `BufRead` and sends
//! whole lines down a channel, which cannot express the ambiguity at all.

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};

use pitcrew_model as pm;

/// What the stream produces.
#[derive(Debug)]
pub enum Event {
    /// One frame.
    State(Box<pm::Snapshot>),
    /// The CLI said something on stderr — a config warning, usually. Shown
    /// rather than swallowed: a stack that will not start because of a typo
    /// should say so in the window, not only in a terminal nobody has open.
    Notice(String),
    /// The stream ended. Carries the reason where there is one.
    Ended(String),
}

pub struct Stream {
    child: Child,
    pub events: async_channel::Receiver<Event>,
}

impl Stream {
    /// Start `pitcrew json --watch` for a project.
    pub fn start(project: Option<&str>, interval: f64) -> std::io::Result<Stream> {
        let mut cmd = Command::new(cli_path());
        // Never build a pitcrew argv by hand elsewhere: the flags and their
        // order are this function's business, so a change lands in one place.
        if let Some(p) = project {
            cmd.arg("-p").arg(p);
        }
        cmd.arg("json")
            .arg("--watch")
            .arg("--interval")
            .arg(interval.to_string())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        let mut child = cmd.spawn()?;
        let (tx, rx) = async_channel::unbounded();

        let stdout = child.stdout.take().expect("piped");
        let out_tx = tx.clone();
        std::thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                let Ok(line) = line else { break };
                if line.trim().is_empty() {
                    continue;
                }
                match serde_json::from_str::<pm::Snapshot>(&line) {
                    Ok(snap) => {
                        if out_tx.send_blocking(Event::State(Box::new(snap))).is_err() {
                            return; // the window went away
                        }
                    }
                    // A line that does not parse is a contract mismatch, which
                    // is worth saying rather than silently dropping a frame.
                    Err(e) => {
                        let _ = out_tx.send_blocking(Event::Notice(format!(
                            "could not read a frame from pitcrew: {e}"
                        )));
                    }
                }
            }
            let _ = out_tx.send_blocking(Event::Ended("the stream ended".into()));
        });

        let stderr = child.stderr.take().expect("piped");
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                if line.trim().is_empty() {
                    continue;
                }
                if tx.send_blocking(Event::Notice(line)).is_err() {
                    return;
                }
            }
        });

        Ok(Stream { child, events: rx })
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        // The CLI streams forever; nothing else will stop it.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Run a one-shot command and return its stdout.
///
/// For the answers the stream does not carry — `projects`, and the start/stop
/// verbs. This is still rendering the CLI's answer, not computing one: the
/// GUI never decides what a command should do, only asks for it.
pub fn run(args: &[&str]) -> Result<String, String> {
    let out = Command::new(cli_path())
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("could not run pitcrew: {e}"))?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    // A refusal goes to stderr and is the thing worth showing. A non-zero exit
    // WITH output is not a failure here — `check` and `doctor` both exit
    // non-zero to be usable as gates while still saying something useful.
    if stdout.trim().is_empty() && !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(stdout)
}

/// Where the CLI is.
///
/// `$PITCREW_BIN` first so a checkout can point the app at the binary it just
/// built, then the name on `PATH`. A GUI that can only ever find an installed
/// pitcrew is a GUI you cannot test a change against.
pub fn cli_path() -> String {
    std::env::var("PITCREW_BIN").unwrap_or_else(|_| "pitcrew".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cli_path_can_be_pointed_at_a_local_build() {
        // SAFETY: single-threaded test, and the variable is read on the next line.
        unsafe { std::env::set_var("PITCREW_BIN", "/tmp/somewhere/pitcrew") };
        assert_eq!(cli_path(), "/tmp/somewhere/pitcrew");
        unsafe { std::env::remove_var("PITCREW_BIN") };
        assert_eq!(cli_path(), "pitcrew");
    }
}
