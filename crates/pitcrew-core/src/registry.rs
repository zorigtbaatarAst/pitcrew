//! pitcrew's own project registry.
//!
//! Configs used to have to live in the project, as `<project>/pitcrew.yaml`.
//! That works for a repo whose team all use pitcrew, and badly for everything
//! else: you cannot add a file to a repo you do not own, a config full of your
//! local paths and ports does not belong in version control, and there was no
//! way to see what pitcrew knows about without going and looking for it.
//!
//! So pitcrew keeps its own under `~/.config/pitcrew/projects/`. An in-project
//! config still works and still **wins** — a repo that ships one is making a
//! deliberate statement about how it should be run.

use std::path::{Path, PathBuf};

use crate::find;
use crate::model::Format;

/// A registry entry is `<name>.yaml` (what `init` writes) or `<name>.sh` (what
/// it used to write, and what a hand-written one may still be). The name is the
/// file's stem either way; only the loader differs.
///
/// `gui/pitcrewgui/registry.py` mirrors this list. Keep them together.
pub const EXTS: &[(&str, Format)] = &[
    ("yaml", Format::Yaml),
    ("yml", Format::Yaml),
    ("sh", Format::Sh),
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub file: PathBuf,
    pub format: Format,
    /// The checkout this entry points at.
    pub root: PathBuf,
}

/// `$PITCREW_HOME`, else `~/.config/pitcrew`.
pub fn home() -> PathBuf {
    if let Some(h) = std::env::var_os("PITCREW_HOME") {
        return PathBuf::from(h);
    }
    let base = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_default();
    base.join(".config/pitcrew")
}

pub fn projects_dir(home: &Path) -> PathBuf {
    home.join("projects")
}

/// A name that is safe as a file name AND as a systemd unit name.
///
/// Both, because the same string becomes both — and a slug that differed
/// between the two would put a project's state under one name and its scopes
/// under another.
pub fn slug(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        // Runs collapse whether the dashes came from the input or from a
        // replacement — otherwise `--Trim--Me--` keeps its doubles and the
        // slug depends on how the name was punctuated.
        let keep = if c.is_ascii_alphanumeric() || c == '_' {
            c.to_ascii_lowercase()
        } else {
            '-'
        };
        if keep == '-' && out.ends_with('-') {
            continue;
        }
        out.push(keep);
    }
    out.trim_matches('-').to_string()
}

/// Every registered project, by name.
pub fn list(home: &Path) -> Vec<Entry> {
    let dir = projects_dir(home);
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut out: Vec<Entry> = entries
        .flatten()
        .filter_map(|e| entry_from(&e.path()))
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// One registered project, if there is one by that name.
pub fn get(home: &Path, name: &str) -> Option<Entry> {
    let dir = projects_dir(home);
    EXTS.iter()
        .map(|(ext, _)| dir.join(format!("{name}.{ext}")))
        .find(|p| p.is_file())
        .and_then(|p| entry_from(&p))
}

fn entry_from(path: &Path) -> Option<Entry> {
    let ext = path.extension()?.to_str()?;
    let format = EXTS.iter().find(|(e, _)| *e == ext).map(|(_, f)| *f)?;
    let name = path.file_stem()?.to_string_lossy().into_owned();
    Some(Entry {
        // A registry entry that declares no root points at its own directory,
        // which is almost never useful — but reporting it is better than
        // dropping the entry and leaving the user to wonder where it went.
        root: find::declared_root(path)
            .unwrap_or_else(|| path.parent().unwrap_or(path).to_path_buf()),
        name,
        file: path.to_path_buf(),
        format,
    })
}

/// The name `pitcrew use` last selected.
pub fn current(home: &Path) -> Option<String> {
    let text = std::fs::read_to_string(home.join("current")).ok()?;
    let name = text.trim().to_string();
    (!name.is_empty()).then_some(name)
}

pub fn set_current(home: &Path, name: &str) -> Result<(), String> {
    std::fs::create_dir_all(home).map_err(|e| format!("{}: {e}", home.display()))?;
    std::fs::write(home.join("current"), format!("{name}\n"))
        .map_err(|e| format!("{}: {e}", home.display()))
}

/// The registered project whose root contains `dir`, if any.
///
/// This is what makes `cd ~/work/sales && pitcrew status` work for a repo that
/// ships no config of its own. The deepest root wins, so a checkout registered
/// inside another registered checkout resolves to the inner one.
pub fn containing(home: &Path, dir: &Path) -> Option<Entry> {
    list(home)
        .into_iter()
        .filter(|e| dir.starts_with(&e.root))
        .max_by_key(|e| e.root.components().count())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("pitcrew-reg-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("projects")).unwrap();
        d
    }

    fn write(home: &Path, file: &str, body: &str) {
        std::fs::write(projects_dir(home).join(file), body).unwrap();
    }

    /// The same string becomes a file name and a systemd unit name. A slug that
    /// differed between them would split a project's state from its scopes.
    #[test]
    fn slugs_are_safe_as_both_a_file_name_and_a_unit_name() {
        assert_eq!(slug("Sales API"), "sales-api");
        assert_eq!(slug("my.app/v2"), "my-app-v2");
        assert_eq!(slug("--Trim--Me--"), "trim-me");
        assert_eq!(slug("already-fine"), "already-fine");
        // Verified against the bash implementation, which collapses the same
        // way despite working on bytes where this works on chars.
        assert_eq!(slug("Ünïcode"), "n-code");
    }

    /// Roots are built from a real temp directory rather than written as
    /// `/work/zulu`: a leading slash with no drive letter is NOT absolute on
    /// Windows, so a hardcoded POSIX path silently tests something else there.
    #[test]
    fn entries_are_listed_by_name_with_their_roots() {
        let h = tmp("list");
        let zulu = h.join("work/zulu");
        write(
            &h,
            "zulu.yaml",
            &format!("root: {}\nname: Zulu\n", zulu.display()),
        );
        write(
            &h,
            "alpha.yaml",
            &format!("root: {}\n", h.join("work/alpha").display()),
        );
        let got = list(&h);
        assert_eq!(
            got.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
            ["alpha", "zulu"]
        );
        assert_eq!(got[1].root, zulu);
    }

    /// Entries written before YAML support are still entries.
    #[test]
    fn a_bash_entry_is_found_and_reported_as_one() {
        let h = tmp("sh");
        let root = h.join("work/legacy");
        write(
            &h,
            "legacy.sh",
            &format!("PITCREW_ROOT=\"{}\"\n", root.display()),
        );
        let e = get(&h, "legacy").expect("found");
        assert_eq!(e.format, Format::Sh);
        assert_eq!(e.root, root);
    }

    #[test]
    fn a_name_that_is_not_registered_is_none() {
        assert!(get(&tmp("none"), "ghost").is_none());
    }

    #[test]
    fn an_absent_registry_is_empty_not_an_error() {
        assert!(list(Path::new("/nonexistent")).is_empty());
    }

    #[test]
    fn the_current_selection_round_trips() {
        let h = tmp("current");
        assert_eq!(current(&h), None);
        set_current(&h, "alpha").unwrap();
        assert_eq!(current(&h).as_deref(), Some("alpha"));
    }

    /// What makes `cd ~/work/sales && pitcrew status` work for a repo that
    /// ships no config of its own.
    #[test]
    fn the_project_containing_a_directory_is_found() {
        let h = tmp("containing");
        // Built from a real temp directory rather than written as `/work`: a
        // leading slash with no drive letter is NOT absolute on Windows, so a
        // hardcoded POSIX path silently tests something else there.
        let work = h.join("work");
        write(&h, "outer.yaml", &format!("root: {}\n", work.display()));
        write(
            &h,
            "inner.yaml",
            &format!("root: {}\n", work.join("sales").display()),
        );

        assert_eq!(containing(&h, &work.join("other/x")).unwrap().name, "outer");
        // The deepest root wins: a checkout registered inside another one
        // resolves to the inner project, which is the one you are standing in.
        assert_eq!(
            containing(&h, &work.join("sales/api")).unwrap().name,
            "inner"
        );
        assert!(containing(&h, &h.join("elsewhere")).is_none());
    }
}
