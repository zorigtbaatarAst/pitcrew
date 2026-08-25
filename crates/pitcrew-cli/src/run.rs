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
pub fn launcher_for(s: &Session) -> Launcher<'_> {
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

    let l = launcher_for(&s);
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

    let l = launcher_for(&s);
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

/// `status --json` — one object, then exit.
pub fn status_json(dir: Option<&Path>, name: Option<&str>) -> ExitCode {
    let s = match project::open(dir, name) {
        Ok(s) => s,
        Err(e) => return fail(&e),
    };
    let mut b = crate::state_object::Builder::new(&s);
    // Config warnings go to stderr, never into the object: stdout is a
    // contract and a consumer parsing it should never have to skip prose.
    for w in &b.warnings {
        eprintln!("warn   {w}");
    }
    let obj = b.build(&s, false);
    match serde_json::to_string(&obj) {
        Ok(text) => {
            println!("{text}");
            ExitCode::SUCCESS
        }
        Err(e) => fail(&e.to_string()),
    }
}

/// `json --watch` — one object per line, forever.
///
/// This is the desktop app's whole data path, and the reason it streams rather
/// than polling `status --json` on a timer: CPU% is a delta between snapshots,
/// so a fresh process reports null cpu and always would.
pub fn json(dir: Option<&Path>, name: Option<&str>, watch: bool, interval: f64) -> ExitCode {
    let s = match project::open(dir, name) {
        Ok(s) => s,
        Err(e) => return fail(&e),
    };
    let mut b = crate::state_object::Builder::new(&s);
    for w in &b.warnings {
        eprintln!("warn   {w}");
    }
    if !watch {
        return match serde_json::to_string(&b.build(&s, false)) {
            Ok(text) => {
                println!("{text}");
                ExitCode::SUCCESS
            }
            Err(e) => fail(&e.to_string()),
        };
    }

    let gap = std::time::Duration::from_secs_f64(interval.max(0.1));
    loop {
        match serde_json::to_string(&b.build(&s, false)) {
            Ok(text) => {
                // A closed pipe is the ordinary way this ends — the reader
                // went away — and it is not an error worth a message.
                use std::io::Write;
                let mut out = std::io::stdout();
                if writeln!(out, "{text}").is_err() || out.flush().is_err() {
                    return ExitCode::SUCCESS;
                }
            }
            Err(e) => return fail(&e.to_string()),
        }
        std::thread::sleep(gap);
    }
}

/// `diagnose` — is this stack healthy right now?
///
/// Takes TWO snapshots a second apart, because CPU% is a delta and one sample
/// can only ever report "unknown" — which would make every idle check silently
/// say nothing.
pub fn diagnose(dir: Option<&Path>, name: Option<&str>, as_json: bool) -> ExitCode {
    let s = match project::open(dir, name) {
        Ok(s) => s,
        Err(e) => return fail(&e),
    };
    let mut b = crate::state_object::Builder::new(&s);
    if !as_json {
        for w in &b.warnings {
            eprintln!("warn   {w}");
        }
    }
    b.build(&s, true);
    std::thread::sleep(std::time::Duration::from_secs(1));
    let obj = b.build(&s, true);

    if as_json {
        return match serde_json::to_string(&obj.health) {
            Ok(text) => {
                println!("{text}");
                verdict_code(obj.health.verdict)
            }
            Err(e) => fail(&e.to_string()),
        };
    }

    println!("  {} {}", obj.project, verdict_word(obj.health.verdict));
    if obj.health.findings.is_empty() {
        println!("  nothing to report");
    }
    for f in &obj.health.findings {
        let mark = match f.severity {
            pitcrew_model::Severity::Crit => "crit",
            pitcrew_model::Severity::Warn => "warn",
            pitcrew_model::Severity::Info => "info",
        };
        println!("  {mark}   {}", f.title);
        // The evidence, never rounded into an assertion.
        println!("         {}", f.detail);
        if !f.fix.is_empty() {
            println!("         → {}", f.fix);
        }
    }
    // Protected components are listed even though they will never be proposed:
    // a list that quietly omits the one you expected reads as a bug.
    if !obj.health.recoverable.protected.is_empty() {
        println!(
            "\n  protected, so never proposed: {}",
            obj.health.recoverable.protected.join(" ")
        );
    }
    verdict_code(obj.health.verdict)
}

/// Non-zero on anything worse than info, so `diagnose` can be a CI gate
/// without a wrapper deciding what counts.
fn verdict_code(v: pitcrew_model::Verdict) -> ExitCode {
    match v {
        pitcrew_model::Verdict::Ok | pitcrew_model::Verdict::Info => ExitCode::SUCCESS,
        _ => ExitCode::FAILURE,
    }
}

fn verdict_word(v: pitcrew_model::Verdict) -> &'static str {
    match v {
        pitcrew_model::Verdict::Ok => "· all good",
        pitcrew_model::Verdict::Info => "· worth knowing",
        pitcrew_model::Verdict::Warn => "· needs attention",
        pitcrew_model::Verdict::Crit => "· something is wrong",
    }
}
