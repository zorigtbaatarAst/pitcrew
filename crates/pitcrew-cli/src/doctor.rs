//! `pitcrew doctor` — is this *environment* able to run pitcrew?
//!
//! Not to be confused with `diagnose`, which asks whether this *stack* is
//! healthy right now. Confusing the two is the easy mistake: doctor is static
//! and about the machine, diagnose is derived from a live snapshot.
//!
//! Only the environment half is ported. The project's own checks and the
//! capacity checks (does the configured stack fit in this machine, do two
//! registered projects clash on a port) need the config model, so they arrive
//! with it in phase 2. Until then this says so rather than printing a clean
//! bill of health it has not earned — a doctor that silently checks less than
//! you think it does is worse than one that admits its scope.

use pitcrew_platform::{caps::Enforcement, memory, ports, process::Sampler, Os};

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

/// Everything doctor can currently establish about this machine.
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

    let (boot, now) = (pitcrew_platform::boot_time(), pitcrew_platform::now());
    out.push(Check {
        level: Level::Ok,
        line: format!(
            "boot   machine up {}",
            human_duration(now.saturating_sub(boot))
        ),
    });

    out.push(Check {
        level: Level::Warn,
        line: "scope  the project's own checks are not ported yet (phase 2) — \
               this reports the machine only"
            .into(),
    });

    out
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

    /// Until the project checks land, doctor must say its scope out loud
    /// rather than implying a clean bill of health it has not earned.
    #[test]
    fn the_unported_scope_is_declared() {
        assert!(run().iter().any(|c| c.line.contains("not ported yet")));
    }

    #[test]
    fn durations_drop_the_units_nobody_reads() {
        assert_eq!(human_duration(0), "0m");
        assert_eq!(human_duration(59), "0m");
        assert_eq!(human_duration(90 * 60), "1h30m");
        assert_eq!(human_duration(26 * 3600), "1d02h");
    }
}
