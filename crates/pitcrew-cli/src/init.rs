//! `pitcrew init` — look at a repository and write a config that actually runs.
//!
//! The output is a **guess**, and the generated file says so. But a guess that
//! runs beats a blank that does not: this command used to write placeholders,
//! which meant the first thing a new project did was fail.
//!
//! By default it writes into the **registry**, not the repository. You often
//! cannot add a file to a repo you do not own, and a config full of your local
//! paths and ports does not belong in version control. `--in-project` puts it
//! in the repo, which is the right choice for a team that all use pitcrew.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use pitcrew_core::{detect, find, registry};

pub struct Options {
    pub dir: Option<PathBuf>,
    pub name: Option<String>,
    pub in_project: bool,
    pub force: bool,
    /// Take a fresh look even though the repo ships its own config.
    pub redetect: bool,
}

pub fn run(opts: &Options) -> ExitCode {
    let dir = match opts
        .dir
        .clone()
        .map(Ok)
        .unwrap_or_else(std::env::current_dir)
    {
        Ok(d) => match d.canonicalize() {
            Ok(d) if d.is_dir() => d,
            _ => return crate::fail(&format!("no such directory: {}", d.display())),
        },
        Err(e) => return crate::fail(&e.to_string()),
    };

    let name = opts
        .name
        .clone()
        .unwrap_or_else(|| registry::slug(&detect::dir_name(&dir)));
    if name.is_empty() {
        return crate::fail("could not work out a project name — pass --name");
    }

    // A repo that ships its own config has already answered every question this
    // command exists to guess at, and that file wins at resolution time anyway.
    // Point at it rather than keeping a detected copy that will drift.
    if !opts.redetect && !opts.in_project {
        if let Some(found) = find::in_dir(&dir) {
            return write_pointer(&name, &dir, &found.file, opts.force);
        }
    }

    println!("  looking at {}", dir.display());
    let detected = detect::scan(&dir);
    if detected.components.is_empty() {
        return crate::fail(
            "nothing here looks like a service pitcrew can start.\n  \
             Write a pitcrew.yaml by hand — see: pitcrew check <file>",
        );
    }

    let target = if opts.in_project {
        dir.join("pitcrew.yaml")
    } else {
        registry::projects_dir(&registry::home()).join(format!("{name}.yaml"))
    };
    if target.exists() && !opts.force {
        return crate::fail(&format!(
            "{} already exists — pass --force to replace it",
            target.display()
        ));
    }

    // `root:` only when the config lives outside the repo. In-project it is the
    // file's own directory, and writing it would be one more thing to keep
    // correct when the checkout moves.
    let body = render(
        &name,
        &detected,
        (!opts.in_project).then_some(dir.as_path()),
    );
    if let Some(parent) = target.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            return crate::fail(&format!("{}: {e}", parent.display()));
        }
    }
    if let Err(e) = std::fs::write(&target, body) {
        return crate::fail(&format!("{}: {e}", target.display()));
    }

    for app in detected.apps() {
        let roles: Vec<&str> = detected
            .components
            .iter()
            .filter(|c| c.app == app)
            .map(|c| c.role.as_str())
            .collect();
        println!("  found  {app}  ({})", roles.join(" + "));
    }
    println!("\n  wrote  {}", target.display());
    // It is a guess, and it says so — here as well as in the file.
    println!("  This is a guess. Read it, correct it, then: pitcrew -p {name} check");
    ExitCode::SUCCESS
}

/// A registry entry that points at a repo's own config rather than copying it.
fn write_pointer(name: &str, dir: &Path, config: &Path, force: bool) -> ExitCode {
    let target = registry::projects_dir(&registry::home()).join(format!("{name}.yaml"));
    if target.exists() && !force {
        return crate::fail(&format!(
            "{} already exists — pass --force to replace it",
            target.display()
        ));
    }
    if let Some(parent) = target.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            return crate::fail(&format!("{}: {e}", parent.display()));
        }
    }
    let body = format!(
        "# {name} — points at the config this repository ships.\n\
         #\n\
         # The repo answered these questions itself, so nothing is guessed here.\n\
         # Editing that file is what changes this project; this entry only says\n\
         # where it lives.\n\
         #\n\
         # `include:` must be the first key — anywhere else and whether a key\n\
         # overrides the include or is overridden BY it depends on line order.\n\
         include: {}\n\
         root: {}\n",
        config.display(),
        dir.display()
    );
    if let Err(e) = std::fs::write(&target, body) {
        return crate::fail(&format!("{}: {e}", target.display()));
    }
    println!("  {} ships its own config — pointing at it", dir.display());
    println!("  wrote  {}", target.display());
    ExitCode::SUCCESS
}

/// The generated YAML.
///
/// Quoted values throughout, because a start command contains `&&` and a colon
/// is legal inside one — an unquoted `cmd:` is the single easiest way to write
/// a config the parser then refuses.
fn render(name: &str, d: &detect::Detected, root: Option<&Path>) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "# {name} — generated by `pitcrew init`.\n\
         #\n\
         # This is a GUESS, read off the repository: which directories look like\n\
         # services, what each is built with, and which port it will land on. It\n\
         # is meant to be read and corrected, not trusted.\n\
         #\n\
         # `pitcrew check` will tell you what is wrong with it.\n\n"
    ));
    if let Some(r) = root {
        out.push_str(&format!("root: {}\n", r.display()));
    }
    out.push_str(&format!("name: {}\n", quote(name)));
    out.push_str("emoji: \"🏁\"\n\napps:\n");

    for app in d.apps() {
        out.push_str(&format!("  {app}:\n"));
        for c in d.components.iter().filter(|c| c.app == app) {
            out.push_str(&format!("    {}:\n", c.role));
            if let Some(rel) = relative(&c.dir, root) {
                if !rel.is_empty() {
                    out.push_str(&format!("      dir: {}\n", quote(&rel)));
                }
            }
            out.push_str(&format!("      cmd: {}\n", quote(&c.cmd)));
            if let Some(p) = c.port {
                out.push_str(&format!("      port: {p}\n"));
            }
            if !c.health.is_empty() {
                out.push_str(&format!("      health: {}\n", quote(&c.health)));
            }
        }
    }
    out
}

fn relative(dir: &Path, root: Option<&Path>) -> Option<String> {
    let root = root?;
    Some(
        dir.strip_prefix(root)
            .ok()?
            .to_string_lossy()
            .replace('\\', "/"),
    )
}

/// Always double-quoted. A start command contains `&&`, and a colon inside one
/// is legal but reads as a key to any parser that is not looking closely.
fn quote(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The generated file must load through the very parser that will read it.
    /// A generator that emits something `check` refuses is worse than no
    /// generator.
    #[test]
    fn what_it_writes_is_what_the_parser_accepts() {
        let d = detect::Detected {
            components: vec![detect::Found {
                app: "sales".into(),
                role: "be".into(),
                dir: PathBuf::from("/repo/sales/backend"),
                kind: detect::Kind::Gradle,
                // The awkward shape on purpose: `&&`, braces and a colon.
                cmd: "cd x && { [ -d node_modules ] || npm i; } && npm run dev -- --port:3000"
                    .into(),
                port: Some(8080),
                health: "/actuator/health".into(),
            }],
        };
        let yaml = render("demo", &d, Some(Path::new("/repo")));
        let entries = pitcrew_core::yaml::parse(&yaml).expect("the generated config parses");
        let get = |k: &str| {
            entries
                .iter()
                .find(|e| e.path == k)
                .map(|e| e.value.clone())
                .unwrap_or_default()
        };
        assert_eq!(get("name"), "demo");
        assert_eq!(get("apps.sales.be.dir"), "sales/backend");
        assert_eq!(get("apps.sales.be.port"), "8080");
        assert_eq!(get("apps.sales.be.health"), "/actuator/health");
        assert!(get("apps.sales.be.cmd").contains("npm run dev -- --port:3000"));
    }

    /// In-project there is no `root:` to keep correct when the checkout moves.
    #[test]
    fn an_in_project_config_declares_no_root() {
        let d = detect::Detected {
            components: vec![detect::Found {
                app: "a".into(),
                role: "be".into(),
                dir: PathBuf::from("/repo/a"),
                kind: detect::Kind::Go,
                cmd: "go run ./...".into(),
                port: None,
                health: String::new(),
            }],
        };
        assert!(!render("demo", &d, None).contains("root:"));
        assert!(render("demo", &d, Some(Path::new("/repo"))).contains("root: /repo"));
    }

    /// It is a guess, and the file has to say so — the person reading it in six
    /// months did not run the command.
    #[test]
    fn the_generated_file_says_it_is_a_guess() {
        let d = detect::Detected::default();
        assert!(render("demo", &d, None).contains("GUESS"));
    }
}
