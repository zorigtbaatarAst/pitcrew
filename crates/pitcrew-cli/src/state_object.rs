//! Building the JSON contract object.
//!
//! This is the whole public API of pitcrew: the desktop app's data path, a
//! status line's polling loop, a CI gate. `pitcrew-model` holds the types and
//! pins the schema; this assembles one.
//!
//! It is deliberately the ONLY place a `pitcrew_model::Snapshot` is built.
//! Everything a consumer needs travels in it — the health verdict included —
//! precisely so that no front end has to re-derive whether the stack is
//! healthy. The desktop app used to do exactly that, and it could not know that
//! "sales" had grown a worker.

use std::collections::HashMap;

use pitcrew_core::{
    deps::Deps, diag, errscan::ErrScan, idle::Idle, logdir::LogDir, profiles, snapshot::Collector,
};
use pitcrew_model as pm;

use crate::project::Session;

/// Holds everything that has to survive between frames: the CPU sampler, the
/// error radar's file offsets, the idle counters, the dependency clock.
pub struct Builder {
    collector: Collector,
    errors: ErrScan,
    deps: Deps,
    idle: Idle,
    logs: LogDir,
    /// Reported once, in the first object, rather than on every frame.
    pub warnings: Vec<String>,
}

impl Builder {
    pub fn new(s: &Session) -> Builder {
        let p = &s.loaded.project;
        let pattern = p
            .dashboard
            .iter()
            .find(|(k, _)| k == "error_pattern")
            .map(|(_, v)| v.clone())
            .unwrap_or_else(|| pitcrew_core::errscan::DEFAULT_PATTERN.to_string());
        let (errors, warning) = ErrScan::new(&pattern);

        let mut warnings = s.loaded.warnings.clone();
        warnings.extend(warning);

        Builder {
            collector: Collector::new(),
            errors,
            deps: Deps::default(),
            idle: Idle::load(&Idle::path_for(&s.home, &s.session)),
            logs: LogDir::new(&s.found.root),
            warnings,
        }
    }

    /// One frame.
    pub fn build(&mut self, s: &Session, deep: bool) -> pm::Snapshot {
        let p = &s.loaded.project;
        let snap = self.collector.take(p, &self.logs);
        let overrides = s.limits();

        // Resolved caps, needed by both the contract and the cap checks.
        let mut caps: HashMap<String, u64> = HashMap::new();
        let mut cap_source: HashMap<String, pm::LimitSource> = HashMap::new();
        for c in p.components() {
            let (value, source) = overrides.resolve(p, c);
            cap_source.insert(c.name.clone(), source);
            if let Some(b) = pitcrew_core::limits::to_bytes(&value) {
                caps.insert(c.name.clone(), b);
            }
        }

        // The error radar reads only what is new since the last frame.
        for c in p.components() {
            self.errors.scan(&c.name, &self.logs.log(&c.name));
        }
        let errors: HashMap<String, u64> = p
            .components()
            .map(|c| (c.name.clone(), self.errors.count(&c.name)))
            .collect();

        let deps_up = self.deps.poll(&p.deps).clone();

        // Idleness, measured rather than assumed — see the module docs.
        let mut idle: HashMap<String, i64> = HashMap::new();
        for cs in &snap.components {
            match cs.pid {
                Some(_) if cs.state.is_running() => {
                    if let Some(secs) = self.idle.observe(
                        &cs.name,
                        cs.pid,
                        cs.cpu,
                        cpu_ms_of(&snap, &cs.name),
                        snap.at,
                    ) {
                        idle.insert(cs.name.clone(), secs);
                    }
                }
                // A component that stopped has a record describing a process
                // that no longer exists.
                _ => self.idle.forget(&cs.name),
            }
        }
        let _ = self.idle.save();

        let health = diag::run(&diag::Context {
            project: p,
            snapshot: &snap,
            caps: &caps,
            errors: &errors,
            deps_up: &deps_up,
            idle: &idle,
            thresholds: diag::Thresholds::default(),
            deep,
        });

        let profile_dir = s.profile_dir();
        pm::Snapshot {
            schema: pm::SCHEMA,
            project: p.name.clone(),
            root: p.root.to_string_lossy().into_owned(),
            // One native collector now, where the shell had two with different
            // costs. The field stays because consumers read it.
            collector: "native".into(),
            log_dir: self.logs.path.to_string_lossy().into_owned(),
            profile_dir: profile_dir.to_string_lossy().into_owned(),
            error_pattern: pattern_of(p),
            shells: p.shells.iter().map(|(k, _)| k.clone()).collect(),
            machine: pm::Machine {
                mem_total: snap.machine.mem_total,
                mem_used: snap.machine.mem_used,
                cpu_percent: snap.machine.cpu_percent,
                swap_total: snap.machine.swap_total,
                swap_used: snap.machine.swap_used,
            },
            at: snap.at,
            components: p
                .components()
                .map(|c| {
                    let cs = snap.get(&c.name);
                    pm::Component {
                        name: c.name.clone(),
                        app: c.app.clone(),
                        role: c.role.clone(),
                        state: cs.map(|x| x.state).unwrap_or(pm::State::NotA),
                        port: c.port,
                        pid: cs.and_then(|x| x.pid),
                        rss: cs.and_then(|x| x.rss),
                        cpu: cs.and_then(|x| x.cpu),
                        errors: errors.get(&c.name).copied().unwrap_or(0),
                        exit: cs.and_then(|x| x.exit).map(|e| e.code),
                        limit: caps.get(&c.name).copied(),
                        limit_source: cap_source
                            .get(&c.name)
                            .copied()
                            .unwrap_or(pm::LimitSource::Role),
                        url: url_for(p, c),
                        health: health_url(c),
                        since: cs.and_then(|x| x.since),
                        // Restart counting belongs to the supervisor, which is
                        // a dashboard-only concern and not ported yet.
                        restarts: 0,
                        idle: idle.get(&c.name).copied(),
                        protected: c.protected,
                        enabled: c.enabled,
                        processes: cs
                            .map(|x| {
                                x.processes
                                    .iter()
                                    .map(|pr| pm::Process {
                                        pid: pr.pid,
                                        cmd: pr.cmd.clone(),
                                        rss: Some(pr.rss),
                                        cpu: None,
                                    })
                                    .collect()
                            })
                            .unwrap_or_default(),
                    }
                })
                .collect(),
            // Profiles carry their live state so a consumer can show what a
            // profile is DOING without resolving target words for itself.
            profiles: profiles::all(&profile_dir, p)
                .into_iter()
                .map(|pr| {
                    let up = pr
                        .components
                        .iter()
                        .filter(|n| snap.get(n).is_some_and(|c| c.state == pm::State::Up))
                        .count() as u32;
                    let starting = pr
                        .components
                        .iter()
                        .filter(|n| snap.get(n).is_some_and(|c| c.state == pm::State::Starting))
                        .count() as u32;
                    pm::Profile {
                        total: pr.components.len() as u32,
                        up,
                        starting,
                        rss: pr
                            .components
                            .iter()
                            .filter_map(|n| snap.get(n).and_then(|c| c.rss))
                            .sum(),
                        limit: pr.components.iter().filter_map(|n| caps.get(n)).sum(),
                        name: pr.name,
                        targets: pr.targets,
                        components: pr.components,
                        missing: pr.missing,
                    }
                })
                .collect(),
            deps: p
                .deps
                .iter()
                .map(|d| pm::Dep {
                    name: d.clone(),
                    state: if deps_up.get(d).copied().unwrap_or(false) {
                        pm::State::Up
                    } else {
                        pm::State::Down
                    },
                })
                .collect(),
            health: pm::Health {
                verdict: health.verdict,
                headline: health.headline,
                deep: health.deep,
                counts: pm::Counts {
                    crit: count(&health.findings, pm::Severity::Crit),
                    warn: count(&health.findings, pm::Severity::Warn),
                    info: count(&health.findings, pm::Severity::Info),
                },
                findings: health.findings,
                recoverable: pm::Recoverable {
                    components: health.recoverable.components,
                    protected: health.recoverable.protected,
                    bytes: health.recoverable.bytes,
                },
            },
            summary: pm::Summary {
                up: snap.count(pm::State::Up),
                starting: snap.count(pm::State::Starting),
                crashed: snap.count(pm::State::Crashed),
                external: snap.count(pm::State::External),
                down: snap.count(pm::State::Down),
            },
        }
    }
}

/// The cumulative CPU counter for a component's whole tree.
///
/// Zero when it is not running, which the idle record then treats as "no
/// movement" — correct, because a stopped component is doing nothing.
fn cpu_ms_of(snap: &pitcrew_core::snapshot::Snapshot, name: &str) -> u64 {
    snap.get(name)
        .map(|c| c.processes.iter().map(|p| p.cpu_ms).sum())
        .unwrap_or(0)
}

fn count(findings: &[pm::Finding], severity: pm::Severity) -> u32 {
    findings.iter().filter(|f| f.severity == severity).count() as u32
}

fn pattern_of(p: &pitcrew_core::model::Project) -> String {
    p.dashboard
        .iter()
        .find(|(k, _)| k == "error_pattern")
        .map(|(_, v)| v.clone())
        .unwrap_or_else(|| pitcrew_core::errscan::DEFAULT_PATTERN.to_string())
}

/// The health ENDPOINT, as a URL — not the path from the config.
///
/// A consumer that wanted to probe it would otherwise have to rebuild the URL
/// from the port and the path, which is the kind of re-derivation the contract
/// exists to avoid. Empty when none is configured, in which case an open port
/// is what makes the component up.
fn health_url(c: &pitcrew_core::model::Component) -> String {
    match (c.port, c.health.is_empty()) {
        (Some(port), false) => format!("http://localhost:{port}{}", c.health),
        _ => String::new(),
    }
}

/// A frontend gets a bare URL; anything else gets the app's `url_path` suffix,
/// because a backend's root is rarely the thing anyone wants to open.
fn url_for(p: &pitcrew_core::model::Project, c: &pitcrew_core::model::Component) -> String {
    let Some(port) = c.port else {
        return String::new();
    };
    let suffix = if c.role == "fe" {
        ""
    } else {
        p.app(&c.app).map(|a| a.url_path.as_str()).unwrap_or("")
    };
    format!("http://localhost:{port}{suffix}")
}
