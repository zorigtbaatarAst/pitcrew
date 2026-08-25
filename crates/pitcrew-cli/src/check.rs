//! `pitcrew check` — load a config and report what is wrong with it.
//!
//! Two kinds of answer, and the difference matters:
//!
//! * a **refusal** — the file could not be read at all, with a line number.
//!   Exits non-zero, and nothing else is reported because nothing else is known.
//! * **warnings** — it loaded, and here is what is probably not what you meant.
//!   Also exits non-zero, so this can be a pre-commit hook, but the summary
//!   still prints because a config that is 90% right starts the 90%.

use std::path::Path;

use pitcrew_core::{load, model::Format, validate};

use crate::project;

pub enum Outcome {
    /// Nothing to say. The config loads and nothing looks wrong.
    Clean(String),
    /// It loaded, with remarks.
    Warned {
        summary: String,
        warnings: Vec<String>,
    },
    /// It did not load.
    Refused(String),
}

pub fn check(target: Option<&Path>, name: Option<&str>) -> Outcome {
    let found = match project::locate(target, name) {
        Ok(f) => f,
        Err(e) => return Outcome::Refused(e),
    };

    if found.format == Format::Sh {
        // Honest rather than helpful-sounding: this is a shell script, and
        // reading it means running it. The bash implementation is where that
        // can happen, and it can convert the file too.
        return Outcome::Refused(format!(
            "{}: the bash config format is not readable from this build — it is a \
             shell script, so loading it means running it.\n  Convert it first with \
             the bash implementation: pitcrew migrate",
            found.file.display()
        ));
    }

    let loaded = match load::load_yaml(&found.file, &found.root) {
        Ok(l) => l,
        Err(e) => return Outcome::Refused(format!("{}:{e}", found.file.display())),
    };

    let mut warnings = loaded.warnings;
    warnings.extend(
        validate::validate(&loaded.project)
            .into_iter()
            .map(|w| format!("config: {w}")),
    );
    if let Some(shadowed) = &found.shadowed {
        warnings.push(format!(
            "config: {} is also here and is being ignored — YAML wins",
            shadowed.display()
        ));
    }

    let p = &loaded.project;
    let summary = format!(
        "{} {}  ·  {} app{}, {} component{}  ·  {}",
        p.emoji,
        p.name,
        p.apps.len(),
        plural(p.apps.len()),
        p.components().count(),
        plural(p.components().count()),
        found.file.display()
    );

    if warnings.is_empty() {
        Outcome::Clean(summary)
    } else {
        Outcome::Warned { summary, warnings }
    }
}

fn plural(n: usize) -> &'static str {
    if n == 1 {
        ""
    } else {
        "s"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("pitcrew-check-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn a_clean_config_summarises_what_it_found() {
        let d = tmp("clean");
        std::fs::write(
            d.join("pitcrew.yaml"),
            "name: demo\napps:\n  api:\n    be:\n      cmd: \"true\"\n      port: 1\n",
        )
        .unwrap();
        match check(Some(&d), None) {
            Outcome::Clean(s) => {
                assert!(s.contains("demo"), "{s}");
                assert!(s.contains("1 app, 1 component"), "{s}");
            }
            Outcome::Warned { warnings, .. } => panic!("unexpected warnings: {warnings:#?}"),
            Outcome::Refused(e) => panic!("refused: {e}"),
        }
    }

    /// A refusal carries the line, and reports nothing else — because after a
    /// parse failure nothing else is actually known.
    #[test]
    fn a_broken_config_is_refused_with_a_line() {
        let d = tmp("broken");
        std::fs::write(d.join("pitcrew.yaml"), "name: ok\nport:8080\n").unwrap();
        match check(Some(&d), None) {
            Outcome::Refused(e) => assert!(e.contains("line 2"), "{e}"),
            _ => panic!("should have been refused"),
        }
    }

    /// Loading and being right are different questions, and this is the second.
    #[test]
    fn a_config_that_loads_but_looks_wrong_warns_and_still_summarises() {
        let d = tmp("warned");
        std::fs::write(
            d.join("pitcrew.yaml"),
            "apps:\n  a:\n    be:\n      cmd: x\n      port: 80\n    fe:\n      cmd: y\n      port: 80\n",
        )
        .unwrap();
        match check(Some(&d), None) {
            Outcome::Warned { summary, warnings } => {
                assert!(warnings
                    .iter()
                    .any(|w| w.contains("port 80 is used by both")));
                assert!(summary.contains("2 components"), "{summary}");
            }
            other => panic!(
                "expected warnings, got {}",
                match other {
                    Outcome::Clean(_) => "clean",
                    _ => "refused",
                }
            ),
        }
    }

    /// The bash format is a shell script. Saying "loading it means running it"
    /// is the honest reason, and it points at the tool that can convert it.
    #[test]
    fn the_bash_format_is_refused_with_the_reason_and_the_way_out() {
        let d = tmp("sh");
        std::fs::write(d.join("pitcrew.config.sh"), "PITCREW_APPS=(a)\n").unwrap();
        match check(Some(&d), None) {
            Outcome::Refused(e) => {
                assert!(e.contains("shell script"), "{e}");
                assert!(e.contains("pitcrew migrate"), "{e}");
            }
            _ => panic!("should have been refused"),
        }
    }

    #[test]
    fn a_missing_config_says_where_it_looked() {
        let d = tmp("empty");
        match check(Some(&d), None) {
            Outcome::Refused(e) => assert!(e.contains("no config in"), "{e}"),
            _ => panic!("should have been refused"),
        }
    }
}
