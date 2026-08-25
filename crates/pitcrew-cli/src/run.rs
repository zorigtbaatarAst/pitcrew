//! `start`, `stop`, `restart`, `status` — the commands that act on a stack.

use std::collections::HashMap;
use std::path::Path;
use std::process::ExitCode;

use pitcrew_core::lifecycle::{Launcher, Started};
use pitcrew_core::{limits, logdir::LogDir, profiles, snapshot::Collector, targets};
use pitcrew_model::State;
use pitcrew_platform::{caps, process};

use crate::project::{self, Session};

/// Build a launcher for a session, with the caps already resolved.
fn launcher(s: &Session) -> Launcher<'_> {
    let overrides = s.limits();
    let p = &s.loaded.project;
    let mut caps_map = HashMap::new();
    for c in p.components() {
        let (value, _) = overrides.resolve(p, c);
        if let Some(bytes) = limits::to_bytes(&value) {
            caps_map.insert(c.name.clone(), bytes);
        }
    }
    Launcher {
        project: p,
        logs: LogDir::new(&s.found.root),
        session: s.session.clone(),
        caps: caps_map,
        enforcement: caps::Enforcement::detect(),
        log_keep: 2,
    }
}

fn resolve(s: &Session, words: &[String]) -> Result<targets::Resolved, String> {
    // Default to everything, which is what `pitcrew start` on its own has
    // always meant.
    let words = if words.is_empty() {
        vec!["all".to_string()]
    } else {
        words.to_vec()
    };
    let expanded = profiles::expand(&s.profile_dir(), &words)?;
    targets::resolve(&s.loaded.project, &expanded).map_err(|e| e.to_string())
}

pub fn start(dir: Option<&Path>, name: Option<&str>, words: &[String]) -> ExitCode {
    let s = match project::open(dir, name) {
        Ok(s) => s,
        Err(e) => return fail(&e),
    };
    let picked = match resolve(&s, words) {
        Ok(r) => r,
        Err(e) => return fail(&e),
    };
    if picked.deps {
        // Docker dependencies are not ported yet. Saying so is the whole point
        // of carrying the word this far — silently doing nothing is what made
        // `stop deps` a no-op that exited 0.
        eprintln!("warn   deps are not ported yet (phase 4) — nothing was done for them");
    }

    let l = launcher(&s);
    let mut failed = false;
    for name in &picked.components {
        let Some(c) = s.loaded.project.component(name) else {
            continue;
        };
        match l.start(c) {
            Ok(Started::AlreadyRunning) => println!("ok     {name} already running"),
            Ok(Started::Launched(pid)) => println!("ok     {name} launched (pid {pid})"),
            Ok(Started::LaunchedAfterReclaim(pid)) => {
                // Explains a component that had been stuck on "crashed": a
                // scope outliving its process is what blocks the next start.
                println!("ok     {name} launched (pid {pid}) — cleared a leftover scope first");
            }
            Err(e) => {
                eprintln!("error  {name}: {e}");
                failed = true;
            }
        }
    }
    if failed {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}

pub fn stop(dir: Option<&Path>, name: Option<&str>, words: &[String]) -> ExitCode {
    let s = match project::open(dir, name) {
        Ok(s) => s,
        Err(e) => return fail(&e),
    };
    let picked = match resolve(&s, words) {
        Ok(r) => r,
        Err(e) => return fail(&e),
    };
    if picked.deps {
        eprintln!("warn   deps are not ported yet (phase 4) — nothing was done for them");
    }

    let l = launcher(&s);
    let mut sampler = process::Sampler::new();
    let table = sampler.sample().table;
    for name in &picked.components {
        let Some(c) = s.loaded.project.component(name) else {
            continue;
        };
        let done = l.stop(c, &table);
        if let Some(port) = done.external_port {
            // Worth naming: this was not pitcrew's process, and freeing it is
            // the thing people are usually surprised by.
            println!("ok     {name} stopped, and freed port {port} from something else");
        } else if done.did_anything() {
            println!("ok     {name} stopped");
        } else {
            println!("ok     {name} was not running");
        }
    }
    ExitCode::SUCCESS
}

pub fn restart(dir: Option<&Path>, name: Option<&str>, words: &[String]) -> ExitCode {
    let code = stop(dir, name, words);
    if code != ExitCode::SUCCESS {
        return code;
    }
    start(dir, name, words)
}

pub fn status(dir: Option<&Path>, name: Option<&str>) -> ExitCode {
    let s = match project::open(dir, name) {
        Ok(s) => s,
        Err(e) => return fail(&e),
    };
    let p = &s.loaded.project;
    let mut collector = Collector::new();
    let snap = collector.take(p, &LogDir::new(&s.found.root));

    println!("  {} {}", p.emoji, p.name);
    for c in p.components() {
        let Some(cs) = snap.get(&c.name) else {
            continue;
        };
        let mark = match cs.state {
            State::Up => "up",
            State::Starting => "starting",
            State::Crashed => "crashed",
            State::External => "external",
            State::Down => "down",
            State::NotA => "n/a",
        };
        let port = c.port.map(|p| p.to_string()).unwrap_or_default();
        let rss = cs
            .rss
            .map(pitcrew_core::format::human_bytes)
            .unwrap_or_default();
        // The exit code turns "crashed" into something actionable.
        let why = match (cs.state, cs.exit) {
            (State::Crashed, Some(e)) => format!("  exited {}", e.code),
            _ => String::new(),
        };
        // A disabled component keeps its row and says off, rather than
        // vanishing — an excluded service that disappeared is one you spend an
        // afternoon looking for.
        let off = if c.enabled { "" } else { "  (off)" };
        println!(
            "  {:<10} {:<20} {:<6} {:>7}{why}{off}",
            mark, c.name, port, rss
        );
    }
    println!(
        "\n  {} up · {} starting · {} crashed · {} external · {} down",
        snap.count(State::Up),
        snap.count(State::Starting),
        snap.count(State::Crashed),
        snap.count(State::External),
        snap.count(State::Down),
    );
    ExitCode::SUCCESS
}

fn fail(msg: &str) -> ExitCode {
    eprintln!("error  {msg}");
    ExitCode::FAILURE
}
