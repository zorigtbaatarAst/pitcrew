//! Per-component RAM caps, and honesty about whether they are real.
//!
//! A cap is a property of the machine, not the project. What this module
//! decides is only *whether the kernel will enforce one*, and that answer
//! differs three ways:
//!
//! | Platform | Mechanism | Enforced |
//! |---|---|---|
//! | Linux + `systemd --user` | a transient scope with `MemoryMax` | yes |
//! | Windows | a named Job Object with a job memory limit | **yes — new here** |
//! | macOS, BSD, Linux without systemd | nothing | no |
//!
//! The Windows row is the one that changed. The bash implementation could only
//! apologise for it (`lib/12-doctor.sh:48`: *"Job Objects exist but nothing on
//! the command line puts a process in one"*) — which was exactly right, and
//! exactly the kind of thing a native binary fixes for free.
//!
//! macOS has not changed and will not: there is no cgroup equivalent and
//! `ulimit -v` is not honoured there. [`Enforcement::explain`] says so in the
//! words `doctor` prints, because a cap you cannot enforce is worth saying out
//! loud when the meters look identical either way.

use std::process::Command;

/// Whether — and how — a memory cap is actually applied on this machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Enforcement {
    /// Linux with a usable `systemd --user`. The kernel applies `MemoryMax` to
    /// the whole cgroup, so it covers the process tree, not just the wrapper.
    Cgroup,
    /// Windows. A Job Object memory limit, applied by the kernel to every
    /// process in the job.
    JobObject,
    /// The cap is a budget the meters measure against, not a limit anything
    /// applies. A runaway process is not auto-killed.
    None,
}

impl Enforcement {
    /// What this machine can actually do.
    ///
    /// The systemd probe is a subprocess, so this is called once at startup and
    /// the answer is carried — never from anywhere reachable per frame.
    pub fn detect() -> Enforcement {
        match crate::Os::current() {
            crate::Os::Windows => Enforcement::JobObject,
            crate::Os::Linux if systemd_user_available() => Enforcement::Cgroup,
            _ => Enforcement::None,
        }
    }

    pub fn is_enforced(self) -> bool {
        !matches!(self, Enforcement::None)
    }

    /// One sentence explaining the verdict, with no leading label and no
    /// padding — column layout belongs to whatever is printing, not here.
    ///
    /// Never claim more than is true: when a cap is only a budget, say which
    /// platform limitation makes it one, because the meter looks identical in
    /// both cases and letting it imply enforcement is the thing this project
    /// has always refused to do.
    pub fn explain(self) -> &'static str {
        match self {
            Enforcement::Cgroup => {
                "enforced by the kernel — each component runs in its own systemd scope with MemoryMax"
            }
            Enforcement::JobObject => {
                "enforced by the kernel — each component runs in its own Job Object with a job memory limit"
            }
            Enforcement::None => match crate::Os::current() {
                crate::Os::MacOs => {
                    "not enforceable on macOS — there is no cgroup equivalent, so the caps are budgets the meters measure against, not limits the kernel applies"
                }
                crate::Os::Linux => {
                    "not enforceable without systemd --user — the caps are budgets the meters measure against, not limits the kernel applies"
                }
                _ => {
                    "not enforceable on this platform — the caps are budgets the meters measure against, not limits the kernel applies"
                }
            },
        }
    }
}

/// Is there a `systemd --user` instance that will accept a transient scope?
///
/// `systemctl --user status` is the cheapest question that distinguishes "the
/// binary exists" from "there is a running user instance to talk to" — a
/// container with systemd installed and no session has the first and not the
/// second, and `systemd-run` there fails at start time with the failure landing
/// inside a log file, which arrives as one more unexplained crash.
fn systemd_user_available() -> bool {
    if !cfg!(target_os = "linux") {
        return false;
    }
    Command::new("systemctl")
        .args(["--user", "status"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// The `systemd-run` argv that wraps a component's command in a capped scope.
///
/// A pure function returning argv rather than something that runs it, so it can
/// be asserted on a machine with no systemd — the same bargain the bash version
/// struck with its `_wmic_ps_parse`-style pure filters, and the only reason its
/// macOS and Windows paths were testable from Linux at all.
///
/// `--scope` rather than `--service` deliberately: a scope stays a child of the
/// calling shell, so the pid pitcrew records still means something. `--collect`
/// so a unit that fails does not linger in a failed state and block the next
/// start under the same name.
pub fn systemd_scope_argv(unit: &str, max_bytes: u64, command: &str) -> Vec<String> {
    vec![
        "systemd-run".into(),
        "--user".into(),
        "--scope".into(),
        "--collect".into(),
        format!("--unit={unit}"),
        format!("-p=MemoryMax={max_bytes}"),
        // Without a swap limit the cap is advisory in practice: a process at
        // MemoryMax simply swaps, and the machine grinds instead of the
        // component failing. This is what makes the cap bite.
        "-p=MemorySwapMax=0".into(),
        "bash".into(),
        "-c".into(),
        command.into(),
    ]
}

/// The transient unit / job object name for a component.
///
/// Session-scoped so two projects on one machine do not collide — which is a
/// real case pitcrew already handles elsewhere (two checkouts sharing port
/// 8080), not a hypothetical.
pub fn unit_name(session: &str, component: &str) -> String {
    format!("pitcrew-{session}-{component}")
}

// ── Windows: the Job Object path ────────────────────────────────────────────

/// Apply a kernel-enforced memory cap to an already-spawned process.
///
/// The job is **named**, and this deliberately does not hold its handle open:
/// a job object outlives every handle to it as long as a process in it is
/// alive, so the limit stays enforced after `pitcrew start` exits. That matters
/// because pitcrew has no daemon — it is the whole architecture — and a cap
/// that evaporated when the launching process returned would be worse than no
/// cap, because the meter would still claim one.
///
/// `stop` re-opens the job by name and terminates it, which is the direct
/// analogue of `systemctl --user stop <unit>.scope` on Linux: one call that
/// takes the whole tree, not a pid walk that can miss a child.
///
/// Compile-verified in CI on `windows-latest`; not exercised against a real
/// capped runaway process yet.
#[cfg(target_os = "windows")]
pub fn apply_job_object(pid: u32, name: &str, max_bytes: u64) -> std::io::Result<()> {
    use windows::core::HSTRING;
    use windows::Win32::Foundation::{CloseHandle, HANDLE};
    use windows::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_JOB_MEMORY,
    };
    use windows::Win32::System::Threading::{OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE};

    // A guard so every early return still closes its handle. Three of the four
    // calls below can fail, and a leaked job handle would keep the job alive
    // past the process it was meant to bound.
    struct Handle(HANDLE);
    impl Drop for Handle {
        fn drop(&mut self) {
            if !self.0.is_invalid() {
                unsafe {
                    let _ = CloseHandle(self.0);
                }
            }
        }
    }

    let wide = HSTRING::from(name);
    unsafe {
        let job = Handle(CreateJobObjectW(None, &wide).map_err(std::io::Error::other)?);

        let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_JOB_MEMORY;
        // The limit is on the JOB, not per process: a component is a tree, and
        // capping each member separately would let four children at the limit
        // use four times it. This is the property the cgroup path already had.
        info.JobMemoryLimit = max_bytes as usize;

        SetInformationJobObject(
            job.0,
            JobObjectExtendedLimitInformation,
            &info as *const _ as *const core::ffi::c_void,
            core::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
        .map_err(std::io::Error::other)?;

        let proc = Handle(
            OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, false, pid)
                .map_err(std::io::Error::other)?,
        );
        AssignProcessToJobObject(job.0, proc.0).map_err(std::io::Error::other)?;
    }
    Ok(())
}

/// Terminate every process in a component's job object.
///
/// Returns `Ok(false)` when no such job exists, which is the ordinary case for
/// a component that was never started or has already stopped — not an error.
#[cfg(target_os = "windows")]
pub fn terminate_job_object(name: &str) -> std::io::Result<bool> {
    use windows::core::HSTRING;
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::JobObjects::{
        OpenJobObjectW, TerminateJobObject, JOB_OBJECT_ALL_ACCESS,
    };

    let wide = HSTRING::from(name);
    unsafe {
        let Ok(job) = OpenJobObjectW(JOB_OBJECT_ALL_ACCESS, false, &wide) else {
            return Ok(false);
        };
        let result = TerminateJobObject(job, 0).map_err(std::io::Error::other);
        let _ = CloseHandle(job);
        result?;
    }
    Ok(true)
}

#[cfg(not(target_os = "windows"))]
pub fn apply_job_object(_pid: u32, _name: &str, _max_bytes: u64) -> std::io::Result<()> {
    Err(std::io::Error::other("job objects are a Windows facility"))
}

#[cfg(not(target_os = "windows"))]
pub fn terminate_job_object(_name: &str) -> std::io::Result<bool> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pure argv, asserted on a machine that may have no systemd at all.
    #[test]
    fn the_scope_argv_carries_the_cap_and_the_command() {
        let argv = systemd_scope_argv(
            "pitcrew-demo-be-api",
            2 * 1024 * 1024 * 1024,
            "./gradlew bootRun",
        );
        assert_eq!(argv[0], "systemd-run");
        assert!(
            argv.contains(&"--scope".to_string()),
            "not --service: a scope stays a child of this shell"
        );
        assert!(
            argv.contains(&"--collect".to_string()),
            "a failed unit must not block the next start"
        );
        assert!(argv.contains(&"--unit=pitcrew-demo-be-api".to_string()));
        assert!(argv.contains(&"-p=MemoryMax=2147483648".to_string()));
        // Without this the cap is advisory: the process swaps instead of failing.
        assert!(argv.contains(&"-p=MemorySwapMax=0".to_string()));
        assert_eq!(
            argv[argv.len() - 3..],
            ["bash".to_string(), "-c".into(), "./gradlew bootRun".into()]
        );
    }

    /// The command reaches a shell as ONE argument. Splitting it would break
    /// every config, because a real start command is
    /// `cd x && { [ -d node_modules ] || npm install; } && npm run dev`.
    #[test]
    fn the_command_is_not_split() {
        let cmd = "cd web && { [ -d node_modules ] || npm install; } && npm run dev";
        let argv = systemd_scope_argv("u", 1, cmd);
        assert_eq!(argv.last().unwrap(), cmd);
    }

    /// Two projects on one machine must not collide on a unit name — that is a
    /// case pitcrew already handles elsewhere, not a hypothetical.
    #[test]
    fn unit_names_are_scoped_to_the_session() {
        assert_eq!(unit_name("sales", "be-api"), "pitcrew-sales-be-api");
        assert_ne!(unit_name("a", "be-api"), unit_name("b", "be-api"));
    }

    /// Whatever this platform reports, the explanation must match it — a
    /// "budget" wording paired with an enforced cap, or the reverse, is the
    /// exact confusion the meters already invite.
    #[test]
    fn the_explanation_agrees_with_the_verdict() {
        let e = Enforcement::detect();
        if e.is_enforced() {
            assert!(e.explain().contains("enforced by the kernel"));
        } else {
            assert!(e.explain().contains("budgets"));
            assert!(e.explain().contains("not limits"));
        }
    }

    /// macOS has no cgroup equivalent and does not honour `ulimit -v`. If this
    /// ever starts failing, something claimed a cap it cannot apply.
    #[test]
    #[cfg(target_os = "macos")]
    fn macos_never_claims_enforcement() {
        assert_eq!(Enforcement::detect(), Enforcement::None);
    }

    /// The row that changed. Windows could not enforce a cap from bash; it can
    /// from here.
    #[test]
    #[cfg(target_os = "windows")]
    fn windows_enforces_via_job_objects() {
        assert_eq!(Enforcement::detect(), Enforcement::JobObject);
        assert!(Enforcement::detect().is_enforced());
    }
}
