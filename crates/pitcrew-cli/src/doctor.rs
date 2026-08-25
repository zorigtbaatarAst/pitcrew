//! `pitcrew doctor` — is this *environment* able to run pitcrew?
//!
//! Not to be confused with `diagnose`, which asks whether this *stack* is
//! healthy right now. Confusing the two is the easy mistake: doctor is static
//! and about the machine, diagnose is derived from a live snapshot.
//!
//! Two halves. The environment half needs nothing but the machine. The
//! project half runs whatever the config's `doctor:` block declares — label on
//! the left, a shell command on the right, exit 0 is a tick.
//!
//! Those commands are the one place `doctor` runs something the project wrote,
//! so they are run exactly as a start command is: one string, one shell. A
//! config that can define them is a config you already trusted enough to
//! launch services from.

use pitcrew_platform::{caps::Enforcement, memory, ports, process, process::Sampler, Os};

/// One line of the report, and whether it is a problem.
pub struct Check {
    pub level: Level,
    pub line: String,
}

#[derive(PartialEq, Eq, Clone, Copy)]
pub enum Level {
    Ok,
    Warn,
}

/// Everything doctor can establish, optionally including a project's own checks.
pub fn run_with(project: Option<&crate::project::Session>) -> Vec<Check> {
    let mut out = run();
    let Some(s) = project else {
        return out;
    };
    let p = &s.loaded.project;

    // Does the configured stack even fit? A cap that cannot bite is worse than
    // no cap, because the OOM killer picks the victim instead.
    let overrides = s.limits();
    let committed: u64 = p
        .components()
        .filter_map(|c| pitcrew_core::limits::to_bytes(&overrides.resolve(p, c).0))
        .sum();
    let total = pitcrew_platform::memory::Gauges::new().read().mem_total;
    if total > 0 && committed > total {
        out.push(Check {
            level: Level::Warn,
            line: format!(
                "caps   this project commits {} on a {} machine",
                pitcrew_core::format::human_bytes(committed),
                pitcrew_core::format::human_bytes(total)
            ),
        });
    }

    // A config that loads but looks wrong is still worth saying out loud here,
    // because `check` is a thing people run once and `doctor` is a thing they
    // run when something is broken.
    for w in s.loaded.warnings.iter().chain(
        pitcrew_core::validate::validate(p)
            .iter()
            .map(|w| w as &String),
    ) {
        out.push(Check {
            level: Level::Warn,
            line: format!("config {w}"),
        });
    }

    for (label, cmd) in &p.doctor {
        let ok = std::process::Command::new(pitcrew_platform::spawn::shell())
            .arg(if cfg!(windows) { "/C" } else { "-c" })
            .arg(cmd)
            .current_dir(&s.found.root)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|st| st.success())
            .unwrap_or(false);
        out.push(Check {
            // The command is shown on failure, because "frontend deps
            // installed: no" without it leaves the reader to go and find the
            // config to learn what was actually run.
            line: if ok {
                format!("proj   {label}")
            } else {
                format!("proj   {label}  ({cmd})")
            },
            level: if ok { Level::Ok } else { Level::Warn },
        });
    }
    out
}

/// Everything doctor can establish about this machine alone.
pub fn run() -> Vec<Check> {
    let mut out = Vec::new();
    let os = Os::current();

    out.push(Check {
        level: Level::Ok,
        line: format!(
            "os     {} · {} cores · pitcrew {}",
            os.as_str(),
            memory::cpu_count(),
            env!("CARGO_PKG_VERSION")
        ),
    });

    // No collector choice to report any more. The bash version had two (`proc`
    // and `ps`) and `doctor` had to say which was live, because they had
    // different costs and different failure modes. A native binary has one.
    let mut sampler = Sampler::new();
    let table = sampler.sample().table;
    out.push(Check {
        level: if table.is_empty() {
            Level::Warn
        } else {
            Level::Ok
        },
        line: if table.is_empty() {
            "procs  the process table came back EMPTY — every component will read as down".into()
        } else {
            format!(
                "procs  native collector · {} processes visible",
                table.len()
            )
        },
    });

    let listening = ports::scan();
    out.push(Check {
        level: Level::Ok,
        line: format!("ports  {} local TCP ports listening", listening.len()),
    });

    // A cap you cannot enforce is worth saying out loud: the meters look
    // identical either way, and letting them imply enforcement is the thing
    // this project has always refused to do.
    let caps = Enforcement::detect();
    out.push(Check {
        level: if caps.is_enforced() {
            Level::Ok
        } else {
            Level::Warn
        },
        line: format!("caps   {}", caps.explain()),
    });

    // Windows has no SIGTERM that reaches a detached process, so `stop`
    // terminates rather than asking. Saying so beats an identical-looking
    // `stop` implying a clean shutdown it did not perform.
    if !process::graceful_stop_available() {
        out.push(Check {
            level: Level::Warn,
            line: "stop   no graceful signal on this platform — stop terminates \
                   rather than asking, so a service gets no chance to flush"
                .into(),
        });
    }
    // A start command is a POSIX shell string; on Windows it goes to cmd.exe,
    // where `&&` works and a `{ ...; }` grouping does not.
    if !pitcrew_platform::spawn::posix_shell() {
        out.push(Check {
            level: Level::Warn,
            line: "shell  start commands run under cmd.exe here — a config written \
                   for a POSIX shell may not run unchanged"
                .into(),
        });
    }

    let (boot, now) = (pitcrew_platform::boot_time(), pitcrew_platform::now());
    out.push(Check {
        level: Level::Ok,
        line: format!(
            "boot   machine up {}",
            human_duration(now.saturating_sub(boot))
        ),
    });

    out
}

/// The machine-readable form.
///
/// A separate shape from the prose, not a reformat of it: this is the CI-gate
/// surface, and the exit code is part of it. Emitting the CHECKS rather than
/// the rendered lines is what lets a consumer act on one without string
/// matching.
#[derive(serde::Serialize)]
pub struct DoctorJson {
    pub schema: u32,
    pub version: &'static str,
    pub os: &'static str,
    /// The bash that runs start commands, where there is one. Empty on a box
    /// with no bash — which is now possible, since the tool itself no longer
    /// needs one.
    pub bash: String,
    pub collector: &'static str,
    #[serde(rename = "capsEnforced")]
    pub caps_enforced: bool,
    #[serde(rename = "capsWarning")]
    pub caps_warning: String,
    /// True where a start command gets a POSIX shell. False on Windows, where
    /// `cmd.exe` runs it and a `{ ...; }` grouping means something else.
    #[serde(rename = "posixShell")]
    pub posix_shell: bool,
    pub tools: std::collections::BTreeMap<&'static str, bool>,
}

pub fn json() -> DoctorJson {
    let caps = Enforcement::detect();
    let mut tools = std::collections::BTreeMap::new();
    for tool in ["docker", "fzf", "lsof", "systemctl"] {
        tools.insert(tool, which(tool));
    }
    DoctorJson {
        schema: pitcrew_model::SCHEMA,
        version: env!("CARGO_PKG_VERSION"),
        os: Os::current().as_str(),
        bash: bash_version(),
        collector: "native",
        caps_enforced: caps.is_enforced(),
        // Empty when there is nothing to warn about, so a consumer can test
        // the string rather than parse the explanation.
        caps_warning: if caps.is_enforced() {
            String::new()
        } else {
            caps.explain().to_string()
        },
        posix_shell: pitcrew_platform::spawn::posix_shell(),
        tools,
    }
}

fn which(tool: &str) -> bool {
    std::process::Command::new(tool)
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn bash_version() -> String {
    let Ok(out) = std::process::Command::new("bash").arg("--version").output() else {
        return String::new();
    };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .unwrap_or("")
        .split_whitespace()
        .nth(3)
        .unwrap_or("")
        .to_string()
}

/// Seconds as the coarsest useful unit. Two significant parts at most: nobody
/// reading an uptime needs the seconds once it is measured in days.
fn human_duration(secs: u64) -> String {
    let (d, h, m) = (secs / 86_400, (secs % 86_400) / 3600, (secs % 3600) / 60);
    match (d, h, m) {
        (0, 0, m) => format!("{m}m"),
        (0, h, m) => format!("{h}h{m:02}m"),
        (d, h, _) => format!("{d}d{h:02}h"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every line must be attributable to a check that actually ran. A doctor
    /// that prints nothing reads as a doctor that found nothing wrong.
    #[test]
    fn the_report_is_not_empty_and_names_the_platform() {
        let checks = run();
        assert!(checks.len() >= 5);
        assert!(checks[0].line.contains(Os::current().as_str()));
    }

    /// The environment half stands alone: a machine with no project is still
    /// a machine `doctor` can report on.
    #[test]
    fn the_environment_half_needs_no_project() {
        assert!(run_with(None).len() >= 5);
    }

    /// The JSON form is a CI-gate surface, so its shape is asserted rather
    /// than left to whatever the struct happens to serialise to.
    #[test]
    fn the_json_form_carries_the_machine_readable_facts() {
        let d = json();
        assert_eq!(d.schema, pitcrew_model::SCHEMA);
        assert_eq!(d.os, Os::current().as_str());
        assert_eq!(d.posix_shell, cfg!(not(windows)));
        assert!(d.tools.contains_key("docker"));
        // Either it is enforced and there is nothing to warn about, or it is
        // not and the reason is stated. Never both, never neither.
        assert_eq!(d.caps_enforced, d.caps_warning.is_empty());
    }

    #[test]
    fn durations_drop_the_units_nobody_reads() {
        assert_eq!(human_duration(0), "0m");
        assert_eq!(human_duration(59), "0m");
        assert_eq!(human_duration(90 * 60), "1h30m");
        assert_eq!(human_duration(26 * 3600), "1d02h");
    }
}
