//! The read-only commands that need only a config.
//!
//! These work today because none of them asks the OS anything: what a project
//! serves, which ports it claims, what is registered, what a profile covers.
//! Anything that needs live state waits for the snapshot in phase 4.

use std::path::Path;
use std::process::ExitCode;

use pitcrew_core::{limits, profiles, registry};

use crate::project;

/// Every URL this project serves.
///
/// A frontend gets a bare URL; anything else gets the app's `url_path` suffix,
/// because a backend's root is rarely the thing you want to open.
pub fn urls(dir: Option<&Path>, name: Option<&str>) -> ExitCode {
    let session = match project::open(dir, name) {
        Ok(s) => s,
        Err(e) => return crate::fail(&e),
    };
    let p = &session.loaded.project;
    println!(
        "  {} {}  ·  {}",
        p.emoji,
        p.name,
        session.found.file.display()
    );

    let mut last_app = String::new();
    for app in &p.apps {
        for c in &app.components {
            let Some(port) = c.port else { continue };
            let suffix = if c.role == "fe" {
                ""
            } else {
                app.url_path.as_str()
            };
            let shown = if app.name == last_app {
                ""
            } else {
                app.name.as_str()
            };
            println!(
                "  {shown:<12} {:<6} http://localhost:{port}{suffix}",
                c.role
            );
            last_app = app.name.clone();
        }
    }
    ExitCode::SUCCESS
}

/// Which port belongs to what, across **every** registered project.
///
/// Deliberately not just this one: the question people ask of this command is
/// "what already has 8080", and the answer is usually in the other checkout.
/// A project that cannot be read is listed with the reason rather than skipped,
/// because a silent omission here reads as "nothing is using that port".
pub fn ports() -> ExitCode {
    let home = registry::home();
    let entries = registry::list(&home);
    if entries.is_empty() {
        println!("  nothing registered — pitcrew init <dir>");
        return ExitCode::SUCCESS;
    }

    let mut claimed: Vec<(u16, String, String)> = Vec::new();
    for entry in &entries {
        match project::open_found(pitcrew_core::find::Found {
            file: entry.file.clone(),
            format: entry.format,
            root: entry.root.clone(),
            shadowed: None,
        }) {
            Ok(s) => {
                for c in s.loaded.project.components() {
                    if let Some(port) = c.port {
                        claimed.push((port, entry.name.clone(), c.name.clone()));
                    }
                }
            }
            Err(_) => println!("  {:<24} not readable from this build", entry.name),
        }
    }

    claimed.sort();
    let mut last = String::new();
    for (port, project_name, comp) in &claimed {
        if *project_name != last {
            println!("\n  {project_name}");
            last.clone_from(project_name);
        }
        // Two projects on one port is the thing this command exists to show.
        let clash = claimed
            .iter()
            .any(|(p, pr, _)| p == port && pr != project_name);
        let mark = if clash {
            "  ← also claimed elsewhere"
        } else {
            ""
        };
        println!("    {port:<6} {comp}{mark}");
    }
    ExitCode::SUCCESS
}

/// Projects pitcrew knows about.
pub fn projects() -> ExitCode {
    let home = registry::home();
    let entries = registry::list(&home);
    if entries.is_empty() {
        println!("  nothing registered — pitcrew init <dir>");
        return ExitCode::SUCCESS;
    }
    let current = registry::current(&home);
    for e in &entries {
        // Which one `pitcrew use` selected, since it changes what a bare
        // `pitcrew` command means from outside any checkout.
        let mark = if current.as_deref() == Some(e.name.as_str()) {
            "●"
        } else {
            "○"
        };
        // Not "running": that needs the OS, and this command does not ask it.
        // Saying so is better than a column that is always blank.
        let note = if e.format == pitcrew_core::model::Format::Sh {
            "  (bash config — not readable from this build)"
        } else {
            ""
        };
        println!("  {mark} {:<24} {}{note}", e.name, e.root.display());
    }
    ExitCode::SUCCESS
}

/// Every profile, and what it covers **today** — missing entries included.
pub fn profiles(dir: Option<&Path>, name: Option<&str>) -> ExitCode {
    let session = match project::open(dir, name) {
        Ok(s) => s,
        Err(e) => return crate::fail(&e),
    };
    let profile_dir = session.profile_dir();
    let found = profiles::all(&profile_dir, &session.loaded.project);
    if found.is_empty() {
        println!("  no profiles — pitcrew profile save <name> <targets...>");
        return ExitCode::SUCCESS;
    }
    for p in &found {
        println!("  {:<16} {}", p.name, p.targets.join(" "));
        println!("  {:<16} {} component(s)", "", p.components.len());
        // A profile that has rotted is worth saying out loud rather than
        // quietly covering less than it reads as covering.
        if !p.missing.is_empty() {
            println!("  {:<16} missing: {}", "", p.missing.join(" "));
        }
    }
    ExitCode::SUCCESS
}

/// Each component's RAM cap, and which of the three layers supplied it.
///
/// The source column is the point: a cap that came from the machine-local file
/// and one that came from the project config look identical on a meter, and
/// only one of them is shared through git.
pub fn caps(dir: Option<&Path>, name: Option<&str>) -> ExitCode {
    let session = match project::open(dir, name) {
        Ok(s) => s,
        Err(e) => return crate::fail(&e),
    };
    let overrides = session.limits();
    let p = &session.loaded.project;
    for c in p.components() {
        let (value, source) = overrides.resolve(p, c);
        let source = match source {
            pitcrew_model::LimitSource::Override => "machine-local",
            pitcrew_model::LimitSource::App => "config",
            pitcrew_model::LimitSource::Role => "role default",
        };
        println!("  {:<20} {:>6}   {source}", c.name, limits::label(&value));
    }
    ExitCode::SUCCESS
}

/// `pitcrew use <name>` — pick the project a bare command means from outside
/// any checkout.
///
/// Last in the resolution order, so it never overrides a config you are
/// standing in: a repo that ships one is making a deliberate statement about
/// how it should be run.
pub fn use_project(name: &str) -> ExitCode {
    let home = registry::home();
    let Some(entry) = registry::get(&home, name) else {
        let known: Vec<String> = registry::list(&home).into_iter().map(|e| e.name).collect();
        return crate::fail(&if known.is_empty() {
            format!("no project '{name}', and nothing is registered — try: pitcrew init <dir>")
        } else {
            format!("no project '{name}' (registered: {})", known.join(" "))
        });
    };
    match registry::set_current(&home, name) {
        Ok(()) => {
            println!("ok     now using {} · {}", entry.name, entry.root.display());
            ExitCode::SUCCESS
        }
        Err(e) => crate::fail(&e),
    }
}
