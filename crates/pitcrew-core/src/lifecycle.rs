//! Starting and stopping components.
//!
//! **There is no daemon.** `pitcrew start` launches a process and exits; what
//! is left behind is a pidfile, a log and, eventually, an exit record. That is
//! the whole architecture, and it constrains two things here:
//!
//! *The wrapper is a shell, not a Rust thread.* Something has to outlive the
//! service to record HOW it ended — without that a dead service is just an
//! absence, and the dashboard can say "crashed" but never "exited 1 at 12:04",
//! which is the first thing anyone wants to know. A Rust thread would die with
//! `pitcrew start`; a shell wrapper does not.
//!
//! *The command is a shell string, and stays one.* Start commands are things
//! like `cd web && { [ -d node_modules ] || npm install; } && npm run dev`, and
//! the role `env:` prefix is folded in front by string concatenation. Executing
//! that as argv would break every config in existence.

use std::process::{Command, Stdio};

use pitcrew_platform::{caps, ports, process, spawn};

use crate::logdir::LogDir;
use crate::model::{Component, Project};

/// What a start attempt did.
#[derive(Debug, PartialEq, Eq)]
pub enum Started {
    /// Launched, with the wrapper's pid.
    Launched(u32),
    /// Already running — a live pidfile, or something already on the port.
    AlreadyRunning,
    /// A leftover scope or job object was cleared on the way past. Reported
    /// rather than done silently: it explains a component that had been stuck.
    LaunchedAfterReclaim(u32),
}

pub struct Launcher<'a> {
    pub project: &'a Project,
    pub logs: LogDir,
    pub session: String,
    /// Resolved caps, keyed by component name — passed in because resolving
    /// them needs the machine-local limits file, which is not this layer's job.
    pub caps: std::collections::HashMap<String, u64>,
    pub enforcement: caps::Enforcement,
    pub log_keep: usize,
}

impl Launcher<'_> {
    /// Start one component.
    pub fn start(&self, c: &Component) -> std::io::Result<Started> {
        if c.run_cmd.trim().is_empty() {
            return Err(std::io::Error::other(format!(
                "{} has no start command configured",
                c.name
            )));
        }
        // Two questions, because either answer means "do not start a second
        // copy": is our recorded process alive, and is anything already on the
        // port. The second catches a service someone started by hand.
        if self.logs.pid(&c.name).is_some_and(process::is_alive) {
            return Ok(Started::AlreadyRunning);
        }
        if let Some(port) = c.port {
            if ports::scan().is_open(port) {
                return Ok(Started::AlreadyRunning);
            }
        }

        self.logs.ensure()?;
        self.logs.rotate(&c.name, self.log_keep)?;
        self.logs.clear_pid(&c.name);
        self.logs.clear_exit(&c.name);

        // Before the wrapper, not inside it. systemd-run refuses to reuse a
        // unit name that is still loaded, and inside the wrapper that refusal
        // goes to the LOG and comes back as one more unexplained crash. A scope
        // routinely outlives the process pitcrew was watching, because it holds
        // the whole cgroup: `./gradlew bootRun` forks a daemon that stays
        // behind, so the app can exit 1 while its scope stays active.
        let unit = caps::unit_name(&self.session, &c.name);
        let reclaimed = self.reclaim(&unit);

        let env = self
            .project
            .role(&c.role)
            .map(|r| r.env.clone())
            .unwrap_or_default();
        let full = if env.trim().is_empty() {
            c.run_cmd.clone()
        } else {
            // Concatenated, not passed as argv: `RAILS_ENV=development` is only
            // an assignment because a shell parses it there.
            format!("{env} {}", c.run_cmd)
        };

        // The pidfile is written by the launcher, not here: on Unix the pid
        // that matters belongs to a background subshell, and only the shell
        // that forked it knows the number.
        let pid = self.spawn(&c.name, &unit, &full, self.caps.get(&c.name).copied())?;

        Ok(if reclaimed {
            Started::LaunchedAfterReclaim(pid)
        } else {
            Started::Launched(pid)
        })
    }

    /// Clear a leftover scope or job object so the name is free. True if there
    /// was one.
    fn reclaim(&self, unit: &str) -> bool {
        match self.enforcement {
            caps::Enforcement::Cgroup => {
                // `reset-failed` alone helps only if the unit FAILED, and the
                // common case is a scope that is still ACTIVE around a daemon
                // nothing is watching. Stop it, then release the name.
                let stopped = run_quiet("systemctl", &["--user", "stop", &format!("{unit}.scope")]);
                let _ = run_quiet(
                    "systemctl",
                    &["--user", "reset-failed", &format!("{unit}.scope")],
                );
                stopped
            }
            caps::Enforcement::JobObject => caps::terminate_job_object(unit).unwrap_or(false),
            caps::Enforcement::None => false,
        }
    }

    /// Spawn the wrapper and return its pid.
    ///
    /// The wrapper runs the command, then records HOW it ended. `$?` is read
    /// on the very next line, before anything else can overwrite it, and the
    /// whole thing is one shell so that `$?` is still the command's.
    fn spawn(
        &self,
        comp: &str,
        unit: &str,
        full_cmd: &str,
        cap_bytes: Option<u64>,
    ) -> std::io::Result<u32> {
        let inner = match (self.enforcement, cap_bytes) {
            // A capped run goes through systemd-run, which with `--scope`
            // blocks for the lifetime of the service — so it has to be the
            // thing inside the wrapper, not something wrapped around it.
            (caps::Enforcement::Cgroup, Some(bytes)) => {
                caps::systemd_scope_argv(unit, bytes, full_cmd)
                    .iter()
                    .map(|a| shell_quote(a))
                    .collect::<Vec<_>>()
                    .join(" ")
            }
            // The command runs in a NESTED shell, never inlined into the
            // wrapper. `{ ... } &` is a subshell, so an inlined `exit 3` — or
            // a `set -e` that trips, or a trap — would exit the wrapper and
            // skip the exit record entirely, which is the one thing the
            // wrapper exists to write.
            _ => format!("{} -c {}", spawn::shell(), shell_quote(full_cmd)),
        };

        let script = format!(
            "{inner}\n__pitcrew_rc=$?\nprintf '%s %s\\n' \"$__pitcrew_rc\" \"$(date +%s)\" > {exitfile}\n",
            exitfile = shell_quote(&self.logs.exitfile(comp).to_string_lossy())
        );
        // stdout and stderr are captured verbatim, ANSI escapes included: the
        // log view knows how to render colour, and stripping it here would
        // throw away information nothing downstream can recover.
        let script = format!(
            "{{\n{script}\n}} >> {log} 2>&1",
            log = shell_quote(&self.logs.log(comp).to_string_lossy())
        );

        let pid = spawn::detached(&script, &self.logs.pidfile(comp))?;

        // Windows caps are applied after the fact: there is no spawn-time flag
        // for it, and the job object holds the whole tree from here on.
        if self.enforcement == caps::Enforcement::JobObject {
            if let Some(bytes) = cap_bytes {
                let _ = caps::apply_job_object(pid, unit, bytes);
            }
        }
        Ok(pid)
    }

    /// Stop one component: the cgroup or job object if there is one, then the
    /// process tree, then whatever is left holding the port.
    pub fn stop(&self, c: &Component, table: &process::ProcessTable) -> Stopped {
        let mut out = Stopped::default();
        let unit = caps::unit_name(&self.session, &c.name);

        if self.reclaim(&unit) {
            out.by_scope = true;
        }

        if let Some(pid) = self.logs.pid(&c.name) {
            if process::is_alive(pid) {
                let killed = process::kill_tree(table, pid, || {
                    std::thread::sleep(std::time::Duration::from_millis(100));
                    true
                })
                .unwrap_or(0);
                out.tree_signalled = killed;
            }
        }
        // Removing the pidfile is what makes a clean stop distinguishable from
        // a crash. It has to happen even when nothing was running, or the next
        // frame reports a component nobody stopped as crashed.
        self.logs.clear_pid(&c.name);

        // And anything else on the port — a service started by hand outside
        // pitcrew, which is what `external` means on the dashboard.
        if let Some(port) = c.port {
            let listening = ports::scan();
            if let Some(owner) = listening.owner(port) {
                if !self.is_ours(owner, table, &c.name) && should_kill(table, owner) {
                    let _ = process::kill_tree(table, owner, || {
                        std::thread::sleep(std::time::Duration::from_millis(100));
                        true
                    });
                    out.external_port = Some(port);
                }
            }
        }
        out
    }

    fn is_ours(&self, pid: u32, table: &process::ProcessTable, comp: &str) -> bool {
        self.logs
            .pid(comp)
            .is_some_and(|ours| table.tree(ours).contains(&pid))
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Stopped {
    pub by_scope: bool,
    pub tree_signalled: usize,
    /// A port freed from something pitcrew did not start.
    pub external_port: Option<u16>,
}

impl Stopped {
    pub fn did_anything(&self) -> bool {
        self.by_scope || self.tree_signalled > 0 || self.external_port.is_some()
    }
}

/// Is this a process `stop` should kill to free a port?
///
/// `docker-proxy` is the one hard no: it holds a published container port, and
/// killing it does not stop the container — it breaks the container's
/// networking and leaves a stack that looks fine and cannot be reached.
fn should_kill(table: &process::ProcessTable, pid: u32) -> bool {
    let Some(p) = table.get(pid) else {
        return false;
    };
    !p.cmd.contains("docker-proxy")
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

fn run_quiet(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_with_a_quote_in_it_survives_the_wrapper() {
        assert_eq!(shell_quote("/a/b"), "'/a/b'");
        assert_eq!(shell_quote("/it's/here"), r"'/it'\''s/here'");
    }

    /// Killing docker-proxy does not stop the container. It breaks the
    /// container's networking and leaves a stack that looks fine and cannot be
    /// reached — which is a far worse outcome than a port that stays busy.
    #[test]
    fn docker_proxy_is_never_killed_to_free_a_port() {
        let mut sampler = process::Sampler::new();
        let table = sampler.sample().table;
        // A real pid from this machine stands in for an ordinary process.
        assert!(should_kill(&table, std::process::id()));
        // A pid that is not in the table is not something to kill either.
        assert!(!should_kill(&table, u32::MAX - 1));
    }

    #[test]
    fn stopped_reports_whether_it_did_anything() {
        assert!(!Stopped::default().did_anything());
        assert!(Stopped {
            tree_signalled: 1,
            ..Default::default()
        }
        .did_anything());
        assert!(Stopped {
            external_port: Some(8080),
            ..Default::default()
        }
        .did_anything());
    }
}
