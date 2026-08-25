//! The pitcrew JSON contract, as types.
//!
//! This crate is the port spec. Every field, its name, its order and its
//! nullability come from `lib/16-output.sh` in the bash implementation, and the
//! exact key set is pinned by `test/output_test.sh:15-58` — which exists
//! because this object has consumers (the desktop app, a status line, a CI
//! gate), so a renamed or dropped field is a breaking change.
//!
//! Two rules carried over from bash, and they are the whole reason this crate
//! is separate from `pitcrew-core`:
//!
//! 1. **`SCHEMA` is versioned independently of the crate version.** Bump it only
//!    when a field is REMOVED or CHANGES MEANING. Adding a field is free — add
//!    it here and to the key-set test in the same change.
//!
//! 2. **Field order matches the bash writer's output order.** Nothing depends on
//!    it semantically, but it makes a raw `diff` between the two implementations
//!    readable during the port, which is worth more than alphabetical tidiness
//!    for as long as both exist.
//!
//! The GUI links this crate for its types but still reads its data from a
//! `pitcrew json --watch` subprocess. That is deliberate: the process boundary
//! is what has kept the GUI from re-deriving health for itself.

use serde::{Deserialize, Serialize};

/// The JSON contract version. Bumped only on removal or a change of meaning.
pub const SCHEMA: u32 = 1;

// ── component state ─────────────────────────────────────────────────────────

/// What a component is doing right now.
///
/// The spellings are the contract — `n/a` carries a slash, and `Unknown` is not
/// a state a consumer will ever see. A role that has no start command is `NotA`,
/// which is NOT the same as `Down`: it is never started and never counted as
/// down, which is the whole of the asymmetric-role design.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Up,
    Starting,
    Crashed,
    Down,
    /// Something is listening on this component's port that pitcrew did not
    /// start. Exists because two projects sharing port 8080 each counted the
    /// other's service as their own.
    External,
    #[serde(rename = "n/a")]
    NotA,
}

impl State {
    /// `external` counts as running for stop and profile purposes: stopping a
    /// port pitcrew does not own is a supported thing to do.
    pub fn is_running(self) -> bool {
        matches!(self, State::Up | State::Starting | State::External)
    }
}

/// Where a component's RAM cap came from. A cap is a property of the machine,
/// not the project, so a machine-local override outranks both config sources.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LimitSource {
    Override,
    App,
    Role,
}

/// Worst-finding-wins verdict over the whole stack.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    Ok,
    Info,
    Warn,
    Crit,
}

/// A finding's severity. Ordered so `max()` yields the verdict directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Info,
    Warn,
    Crit,
}

// ── the state object: `pitcrew status --json` / `pitcrew json --watch` ───────

/// One snapshot of the whole stack. Field order matches the bash writer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub schema: u32,
    pub project: String,
    pub root: String,
    /// Which collector produced these numbers — `proc` or `ps`. Surfaced
    /// because the two have different costs and `doctor` reports which is live.
    pub collector: String,
    #[serde(rename = "logDir")]
    pub log_dir: String,
    #[serde(rename = "profileDir")]
    pub profile_dir: String,
    /// The regex the error radar matches log lines against. User-visible in the
    /// dashboard header, so it travels with the data.
    #[serde(rename = "errorPattern")]
    pub error_pattern: String,
    pub shells: Vec<String>,
    pub machine: Machine,
    /// Unix seconds. The GUI computes uptime against this rather than its own
    /// clock, so a stream from another box still reads correctly.
    pub at: i64,
    pub components: Vec<Component>,
    pub profiles: Vec<Profile>,
    pub deps: Vec<Dep>,
    pub health: Health,
    pub summary: Summary,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Machine {
    #[serde(rename = "memTotal")]
    pub mem_total: u64,
    #[serde(rename = "memUsed")]
    pub mem_used: u64,
    #[serde(rename = "cpuPercent")]
    pub cpu_percent: u32,
    #[serde(rename = "swapTotal")]
    pub swap_total: u64,
    #[serde(rename = "swapUsed")]
    pub swap_used: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Component {
    pub name: String,
    pub app: String,
    pub role: String,
    pub state: State,
    /// `None` for a role with no port configured — not 0. A consumer that sees
    /// 0 would render it as a real port.
    pub port: Option<u16>,
    pub pid: Option<u32>,
    /// Summed over the whole process tree, so the number is the same with or
    /// without systemd.
    pub rss: Option<u64>,
    /// A real utime+stime delta over the sampling window, not `ps`'s lifetime
    /// average. `None` on the first frame, when there is no previous sample to
    /// difference against — that is why the GUI streams instead of polling.
    pub cpu: Option<f64>,
    pub errors: u64,
    /// Exit code of the last run, when it ended on its own. Distinguishes
    /// "exited 1 at 12:04" from "crashed", which is a real product difference.
    pub exit: Option<i32>,
    pub limit: Option<u64>,
    #[serde(rename = "limitSource")]
    pub limit_source: LimitSource,
    pub url: String,
    /// The health *endpoint*, not a verdict. Empty when none is configured, in
    /// which case an open port is what makes the component up.
    pub health: String,
    /// Unix seconds this component started, or `None` if it is not running.
    pub since: Option<i64>,
    pub restarts: u32,
    /// Seconds this component has provably done no work. Measured, not guessed:
    /// the CPU counter is persisted alongside the timestamp so a gap with no
    /// counter movement carries the old timestamp forward.
    pub idle: Option<i64>,
    /// `diagnose` will never PROPOSE stopping this to free memory. Not a lock —
    /// `stop` still stops it — just a statement that suggesting it would waste
    /// the reader's time.
    pub protected: bool,
    pub enabled: bool,
    /// Capped per component. Empty unless the consumer asked for it.
    pub processes: Vec<Process>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Process {
    pub pid: u32,
    pub cmd: String,
    pub rss: Option<u64>,
    pub cpu: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Profile {
    pub name: String,
    /// The target words as written (`all`, `backends`, `sales`), before
    /// resolution — so the GUI can show what a profile *says*.
    pub targets: Vec<String>,
    /// …and after resolution, so it can show what the profile *covers* without
    /// reimplementing target resolution.
    pub components: Vec<String>,
    /// Targets that resolved to nothing. A profile naming a deleted app is a
    /// thing to say out loud, not to silently drop.
    pub missing: Vec<String>,
    pub total: u32,
    pub up: u32,
    pub starting: u32,
    pub rss: u64,
    pub limit: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Dep {
    pub name: String,
    pub state: State,
}

/// The verdict travels with the facts. A consumer that had to work out "is
/// anything wrong" from the component list would be reimplementing the whole
/// diagnostics layer — which is exactly what the GUI used to do.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Health {
    pub verdict: Verdict,
    /// The worst finding, in one line. When a stack is on fire, this is the
    /// thing the reader actually reads.
    pub headline: String,
    /// Whether the expensive checks ran. `status`/`json` run the cheap tier;
    /// `diagnose` runs everything.
    pub deep: bool,
    pub counts: Counts,
    pub findings: Vec<Finding>,
    pub recoverable: Recoverable,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct Counts {
    pub crit: u32,
    pub warn: u32,
    pub info: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Finding {
    pub severity: Severity,
    /// Stable identifier (`dep-down`, `cap-overcommit`). Consumers match on
    /// this, never on the title.
    pub id: String,
    pub title: String,
    /// Carries the evidence (`quiet 41m · up 3h20m`) rather than rounding it
    /// into an assertion. Never claim more than was measured.
    pub detail: String,
    /// A suggested command. The GUI checks this against a verb whitelist and
    /// runs it as argv, never through a shell — plugins write this field.
    pub fix: String,
    pub scope: String,
}

/// What stopping the idle components would return, and what will never be
/// proposed. `protected` is listed rather than omitted, so a missing candidate
/// is never a mystery.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Recoverable {
    pub components: Vec<String>,
    pub protected: Vec<String>,
    pub bytes: u64,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct Summary {
    pub up: u32,
    pub starting: u32,
    pub crashed: u32,
    pub external: u32,
    pub down: u32,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The spellings are the contract, not an implementation detail. `n/a`
    /// carries a slash; every other state is its own lowercase word.
    #[test]
    fn state_spellings_are_the_contract() {
        let cases = [
            (State::Up, "\"up\""),
            (State::Starting, "\"starting\""),
            (State::Crashed, "\"crashed\""),
            (State::Down, "\"down\""),
            (State::External, "\"external\""),
            (State::NotA, "\"n/a\""),
        ];
        for (state, want) in cases {
            assert_eq!(serde_json::to_string(&state).unwrap(), want);
        }
    }

    /// `n/a` is not `down`. A role with no start command is never started and
    /// never counted as down, and `external` counts as running because
    /// stopping a port pitcrew does not own is supported.
    #[test]
    fn running_means_up_starting_or_external() {
        assert!(State::Up.is_running());
        assert!(State::Starting.is_running());
        assert!(State::External.is_running());
        assert!(!State::Down.is_running());
        assert!(!State::Crashed.is_running());
        assert!(!State::NotA.is_running());
    }

    /// Severity is ordered so the stack verdict is `max()` over the findings
    /// rather than a hand-written cascade.
    #[test]
    fn severity_orders_worst_last() {
        assert!(Severity::Crit > Severity::Warn);
        assert!(Severity::Warn > Severity::Info);
    }

    /// A null port must stay null. A consumer that receives 0 renders it as a
    /// real port number.
    #[test]
    fn absent_numbers_serialize_as_null_not_zero() {
        let json = serde_json::to_string(&Process {
            pid: 42,
            cmd: "java".into(),
            rss: None,
            cpu: None,
        })
        .unwrap();
        assert_eq!(json, r#"{"pid":42,"cmd":"java","rss":null,"cpu":null}"#);
    }
}
