//! Named, saved sets of targets — `pitcrew start @morning`.
//!
//! **A profile is a file of target WORDS, not of components.** `sales` stays
//! `sales`, so a profile keeps meaning what you meant when that app later grows
//! a worker. The flip side is that a profile can rot: rename an app and the file
//! still names the old one.
//!
//! So everything here reports what a profile resolves to **today**, missing
//! entries included, rather than echoing the file back. A profile naming a
//! deleted app is a thing to say out loud, not to silently drop — which is why
//! [`Profile::missing`] exists and travels all the way into the JSON contract.

use std::path::{Path, PathBuf};

use crate::model::Project;
use crate::targets;

/// One profile, resolved against the project as it is now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Profile {
    pub name: String,
    /// The words as written, so the reader sees what the profile *says*.
    pub targets: Vec<String>,
    /// …and what it *covers*, so nothing has to re-resolve target words.
    pub components: Vec<String>,
    /// Words that resolve to nothing today.
    pub missing: Vec<String>,
}

/// `<pitcrew home>/<session>/profiles`.
pub fn dir_for(home: &Path, session: &str) -> PathBuf {
    home.join(session).join("profiles")
}

/// Every profile name, sorted. An empty or absent directory is not an error.
pub fn names(dir: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<String> = entries
        .flatten()
        .filter(|e| e.path().is_file())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    out.sort();
    out
}

/// The words a profile holds, as written. `None` if there is no such profile.
pub fn targets_of(dir: &Path, name: &str) -> Option<Vec<String>> {
    let text = std::fs::read_to_string(dir.join(name)).ok()?;
    Some(
        text.lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .map(String::from)
            .collect(),
    )
}

pub fn save(dir: &Path, name: &str, targets: &[String]) -> Result<(), String> {
    if name.is_empty() || name.contains(['/', '\\', '.']) {
        return Err(format!(
            "'{name}' is not a usable profile name — it becomes a file name"
        ));
    }
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let body: String = targets.iter().map(|t| format!("{t}\n")).collect();
    std::fs::write(dir.join(name), body).map_err(|e| format!("{name}: {e}"))
}

pub fn remove(dir: &Path, name: &str) -> Result<(), String> {
    std::fs::remove_file(dir.join(name)).map_err(|e| format!("{name}: {e}"))
}

/// Replace `@name` with the words that profile holds, leaving everything else
/// alone.
///
/// Done before [`targets::resolve`] rather than inside it, so that resolution
/// stays a pure function of the project and needs no filesystem to test.
pub fn expand(dir: &Path, words: &[String]) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for word in words {
        match word.strip_prefix('@') {
            None => out.push(word.clone()),
            Some(name) => match targets_of(dir, name) {
                Some(t) => out.extend(t),
                None => return Err(format!("no profile '{word}' — see: pitcrew profile list")),
            },
        }
    }
    Ok(out)
}

/// Resolve one profile against the project as it is now.
///
/// A word that resolves to nothing lands in `missing` instead of failing the
/// whole profile: a profile that names five apps and has lost one should still
/// start the four.
pub fn resolve(dir: &Path, name: &str, p: &Project) -> Option<Profile> {
    let words = targets_of(dir, name)?;
    let mut components = Vec::new();
    let mut missing = Vec::new();
    for word in &words {
        match targets::resolve(p, std::slice::from_ref(word)) {
            Ok(r) => {
                // `deps` covers no components but is not missing — it is a real
                // target that simply is not one.
                if r.components.is_empty() && !r.deps {
                    missing.push(word.clone());
                }
                for c in r.components {
                    if !components.contains(&c) {
                        components.push(c);
                    }
                }
            }
            Err(_) => missing.push(word.clone()),
        }
    }
    Some(Profile {
        name: name.to_string(),
        targets: words,
        components,
        missing,
    })
}

/// Every profile, resolved. What `pitcrew json` reports on each frame.
pub fn all(dir: &Path, p: &Project) -> Vec<Profile> {
    names(dir)
        .into_iter()
        .filter_map(|n| resolve(dir, &n, p))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{App, Component};

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("pitcrew-prof-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn project() -> Project {
        let comp = |app: &str, role: &str| Component {
            name: format!("{role}-{app}"),
            app: app.into(),
            role: role.into(),
            enabled: true,
            ..Default::default()
        };
        Project {
            apps: vec![
                App {
                    name: "sales".into(),
                    enabled: true,
                    components: vec![comp("sales", "be"), comp("sales", "fe")],
                    ..Default::default()
                },
                App {
                    name: "admin".into(),
                    enabled: true,
                    components: vec![comp("admin", "be")],
                    ..Default::default()
                },
            ],
            ..Default::default()
        }
    }

    #[test]
    fn names_are_sorted_and_an_absent_directory_is_not_an_error() {
        let d = tmp("names");
        assert!(names(&d).is_empty());
        assert!(names(Path::new("/nonexistent")).is_empty());
        save(&d, "zulu", &["all".into()]).unwrap();
        save(&d, "alpha", &["sales".into()]).unwrap();
        assert_eq!(names(&d), ["alpha", "zulu"]);
    }

    #[test]
    fn saving_and_reading_round_trips_the_words_as_written() {
        let d = tmp("round");
        save(&d, "morning", &["sales".into(), "deps".into()]).unwrap();
        assert_eq!(targets_of(&d, "morning").unwrap(), ["sales", "deps"]);
        remove(&d, "morning").unwrap();
        assert_eq!(targets_of(&d, "morning"), None);
    }

    /// A profile name becomes a file name, so the characters that would make it
    /// something else are refused rather than written somewhere surprising.
    #[test]
    fn a_profile_name_that_is_not_a_file_name_is_refused() {
        let d = tmp("badname");
        for bad in ["", "a/b", "../escape", "with.dot"] {
            assert!(save(&d, bad, &["all".into()]).is_err(), "{bad}");
        }
    }

    #[test]
    fn expand_replaces_a_reference_and_leaves_everything_else() {
        let d = tmp("expand");
        save(&d, "morning", &["sales".into(), "deps".into()]).unwrap();
        let words = vec!["@morning".to_string(), "admin".to_string()];
        assert_eq!(expand(&d, &words).unwrap(), ["sales", "deps", "admin"]);
    }

    #[test]
    fn expanding_a_profile_that_does_not_exist_says_where_to_look() {
        let d = tmp("noexpand");
        let e = expand(&d, &["@ghost".to_string()]).expect_err("no such profile");
        assert!(e.contains("no profile '@ghost'"), "{e}");
        assert!(e.contains("pitcrew profile list"), "{e}");
    }

    /// The point of the whole module: a profile keeps meaning what you meant.
    /// `sales` covers a worker the app grows later, without anyone editing it.
    #[test]
    fn a_profile_resolves_against_the_project_as_it_is_now() {
        let d = tmp("resolve");
        save(&d, "morning", &["sales".into()]).unwrap();
        let before = resolve(&d, "morning", &project()).unwrap();
        assert_eq!(before.components, ["be-sales", "fe-sales"]);

        let mut grown = project();
        grown.apps[0].components.push(Component {
            name: "worker-sales".into(),
            app: "sales".into(),
            role: "worker".into(),
            enabled: true,
            ..Default::default()
        });
        let after = resolve(&d, "morning", &grown).unwrap();
        assert_eq!(after.components, ["be-sales", "fe-sales", "worker-sales"]);
        assert_eq!(after.targets, ["sales"], "the file did not change");
    }

    /// A profile that has lost one app should still start the rest — and say
    /// which one it lost, rather than dropping it silently.
    #[test]
    fn a_word_that_resolves_to_nothing_is_reported_not_fatal() {
        let d = tmp("rot");
        save(&d, "old", &["sales".into(), "deleted-app".into()]).unwrap();
        let r = resolve(&d, "old", &project()).unwrap();
        assert_eq!(r.components, ["be-sales", "fe-sales"]);
        assert_eq!(r.missing, ["deleted-app"]);
    }

    /// `deps` covers no components and is not missing — it is a real target
    /// that simply is not one.
    #[test]
    fn deps_is_not_reported_as_missing() {
        let d = tmp("deps");
        save(&d, "infra", &["deps".into()]).unwrap();
        let r = resolve(&d, "infra", &project()).unwrap();
        assert!(r.components.is_empty());
        assert!(r.missing.is_empty(), "deps is a target, not a typo");
    }

    #[test]
    fn overlapping_words_within_one_profile_are_deduped() {
        let d = tmp("dedup");
        save(&d, "twice", &["sales".into(), "be-sales".into()]).unwrap();
        assert_eq!(
            resolve(&d, "twice", &project()).unwrap().components,
            ["be-sales", "fe-sales"]
        );
    }
}
