//! One pass answering every state question about a project.
//!
//! Everything the dashboard, `status` and the JSON stream show comes from here,
//! taken once. The bash implementation's whole design rested on this pass
//! costing no forks; that constraint is gone, but the shape it produced is
//! kept, because the alternative — each caller asking the OS its own question —
//! is how `comp_state` came to re-open a socket three times per component per
//! frame.

use std::collections::HashMap;
use std::time::Duration;

use pitcrew_model::State;
use pitcrew_platform::{ports, process};

use crate::logdir::LogDir;
use crate::model::{Component, Project};
use crate::state::{self, Facts};

/// What one component is doing, right now.
#[derive(Debug, Clone)]
pub struct CompSnapshot {
    pub name: String,
    pub state: State,
    pub pid: Option<u32>,
    /// Summed over the whole process tree, so it is the same number with or
    /// without a cgroup.
    pub rss: Option<u64>,
    pub cpu: Option<f64>,
    pub since: Option<i64>,
    pub exit: Option<crate::logdir::Exit>,
    pub processes: Vec<process::ProcInfo>,
}

pub struct Snapshot {
    pub at: i64,
    pub components: Vec<CompSnapshot>,
    pub machine: pitcrew_platform::Machine,
}

impl Snapshot {
    pub fn get(&self, name: &str) -> Option<&CompSnapshot> {
        self.components.iter().find(|c| c.name == name)
    }

    pub fn count(&self, state: State) -> u32 {
        self.components.iter().filter(|c| c.state == state).count() as u32
    }
}

/// Holds what a snapshot needs between passes: the CPU sampler's previous
/// reading, and the machine gauges.
pub struct Collector {
    sampler: process::Sampler,
    gauges: pitcrew_platform::memory::Gauges,
    boot: u64,
    /// The last health verdict per component. A probe is synchronous here, so
    /// it is only run for components whose port is actually open — asking a
    /// closed port costs a full connect timeout for an answer already known.
    health: HashMap<String, bool>,
    pub health_timeout: Duration,
}

impl Default for Collector {
    fn default() -> Self {
        Self::new()
    }
}

impl Collector {
    pub fn new() -> Collector {
        Collector {
            sampler: process::Sampler::new(),
            gauges: pitcrew_platform::memory::Gauges::new(),
            boot: pitcrew_platform::boot_time(),
            health: HashMap::new(),
            health_timeout: Duration::from_secs(2),
        }
    }

    pub fn take(&mut self, p: &Project, logs: &LogDir) -> Snapshot {
        // Sweeping the process table is by far the most expensive thing here —
        // one /proc read per process on the machine. When nothing this project
        // started is alive there is no tree to walk, every RSS and CPU is None
        // regardless, and the sweep buys exactly nothing. A stopped stack is
        // the common case for a `status` check, so it is worth the branch.
        //
        // The pid liveness test is `kill(pid, 0)`: one syscall per component,
        // against 750 file reads.
        // Only the roots this project started. Nothing here ever asks about a
        // process outside a component's tree, so sweeping the machine to find
        // four of them is work with no answer attached to it.
        let roots: Vec<u32> = p
            .components()
            .filter_map(|c| logs.pid(&c.name))
            .filter(|pid| process::is_alive(*pid))
            .collect();
        let sample = if !roots.is_empty() {
            self.sampler.sample_trees(&roots)
        } else {
            // Still advances the CPU baseline's clock, so the first frame after
            // something starts is not differencing against a stale window.
            self.sampler.idle_sample()
        };
        let listening = ports::scan();
        let machine = self.gauges.read();
        let now = pitcrew_platform::now() as i64;

        let mut components = Vec::new();
        for c in p.components() {
            components.push(self.one(c, logs, &sample, &listening, now));
        }

        // Command lines, for the handful of pids that will actually be shown.
        // Reading them for every process on the machine is the single most
        // expensive thing a frame can do.
        let shown: Vec<u32> = components
            .iter()
            .flat_map(|c| c.processes.iter().map(|p| p.pid))
            .collect();
        let commands = self.sampler.commands_for(&shown);
        for c in &mut components {
            for proc in &mut c.processes {
                if let Some(cmd) = commands.get(&proc.pid) {
                    proc.cmd.clone_from(cmd);
                }
            }
        }

        Snapshot {
            at: now,
            components,
            machine,
        }
    }

    fn one(
        &mut self,
        c: &Component,
        logs: &LogDir,
        sample: &process::Sample,
        listening: &ports::Listening,
        now: i64,
    ) -> CompSnapshot {
        // A pidfile that predates the last boot cannot be the process that
        // wrote it, whatever is running under that number now.
        let stale = logs.predates_boot(&c.name, self.boot);
        let pid = logs.pid(&c.name).filter(|_| !stale);
        let pid_alive = pid.is_some_and(process::is_alive);
        let port_open = c.port.is_some_and(|p| listening.is_open(p));

        // Only probe a port that is actually open: asking a closed one costs a
        // full connect timeout to learn what the port scan already said.
        let health_ok = match (&c.health, c.port, port_open) {
            (h, _, _) if h.is_empty() => true,
            (h, Some(port), true) => {
                let ok = crate::health::probe(port, h, self.health_timeout);
                self.health.insert(c.name.clone(), ok);
                ok
            }
            _ => false,
        };

        let facts = Facts {
            pid,
            pid_alive,
            port_open,
            health_ok,
        };
        let st = state::derive(&facts);

        let (rss, cpu, since, processes) = if pid_alive {
            let root = pid.unwrap();
            let tree = sample.table.tree(root);
            (
                Some(sample.table.tree_rss(root)),
                sample.tree_cpu(&sample.table, root),
                sample.table.tree_started(root).map(|s| s as i64),
                tree.iter()
                    .filter_map(|p| sample.table.get(*p))
                    // Capped: a large stack would otherwise put hundreds of
                    // processes on every frame, for a view most frames nobody
                    // has open.
                    .take(12)
                    .cloned()
                    .collect(),
            )
        } else {
            (None, None, None, Vec::new())
        };

        CompSnapshot {
            name: c.name.clone(),
            state: st,
            pid,
            rss,
            cpu,
            since,
            // "crashed" on its own tells you nothing actionable, so the record
            // of HOW travels with it — and only with it, because a stale exit
            // file from a previous run says nothing about a running service.
            exit: (st == State::Crashed).then(|| logs.exit(&c.name)).flatten(),
            processes,
        }
        .tap_now(now)
    }
}

impl CompSnapshot {
    /// A component that has not started has no uptime, whatever a leftover
    /// pidfile's mtime says.
    fn tap_now(mut self, now: i64) -> CompSnapshot {
        if let Some(since) = self.since {
            if since > now {
                self.since = None;
            }
        }
        self
    }
}
