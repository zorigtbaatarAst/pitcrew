//! Working out which project a command is about, and loading it.
//!
//! Resolution order, first hit wins — the same one the bash implementation
//! documents, so muscle memory and scripts carry over:
//!
//! 1. `-C <dir>` or an explicit path
//! 2. `-p <name>` — a registered project
//! 3. `$PITCREW_CONFIG`
//! 4. a config walked up from the current directory
//! 5. a registered project whose root contains the current directory
//! 6. whatever `pitcrew use` last selected
//!
//! **An in-project config outranks the registry** (4 before 5): a repo that
//! ships one is making a deliberate statement about how it should be run.

use std::path::{Path, PathBuf};

use pitcrew_core::{find, limits, load, model::Format, profiles, registry};

pub struct Session {
    pub found: find::Found,
    pub loaded: load::Loaded,
    /// Slug of the project name — the key for its state directory and its
    /// systemd units. Both, from one string, on purpose.
    pub session: String,
    pub home: PathBuf,
}

impl Session {
    pub fn profile_dir(&self) -> PathBuf {
        profiles::dir_for(&self.home, &self.session)
    }
    pub fn limits(&self) -> limits::Limits {
        limits::Limits::load(&limits::Limits::path_for(&self.home, &self.session))
    }
}

/// Find a project's config without loading it.
pub fn locate(target: Option<&Path>, name: Option<&str>) -> Result<find::Found, String> {
    let home = registry::home();

    if let Some(t) = target {
        return explicit(t);
    }
    if let Some(n) = name {
        let e = registry::get(&home, n).ok_or_else(|| {
            let known = registry::list(&home)
                .iter()
                .map(|e| e.name.clone())
                .collect::<Vec<_>>()
                .join(" ");
            if known.is_empty() {
                format!("no project '{n}', and nothing is registered — try: pitcrew init <dir>")
            } else {
                format!("no project '{n}' (registered: {known})")
            }
        })?;
        return Ok(find::Found {
            file: e.file,
            format: e.format,
            root: e.root,
            shadowed: None,
        });
    }
    if let Some(env) = std::env::var_os("PITCREW_CONFIG") {
        let p = PathBuf::from(env);
        if p.is_file() {
            return explicit(&p);
        }
    }

    let here = std::env::current_dir().map_err(|e| e.to_string())?;
    // An in-project config wins over the registry.
    if let Some(found) = find::walk_up(&here) {
        return Ok(found);
    }
    if let Some(e) = registry::containing(&home, &here) {
        return Ok(find::Found {
            file: e.file,
            format: e.format,
            root: e.root,
            shadowed: None,
        });
    }
    if let Some(name) = registry::current(&home) {
        if let Some(e) = registry::get(&home, &name) {
            return Ok(find::Found {
                file: e.file,
                format: e.format,
                root: e.root,
                shadowed: None,
            });
        }
    }
    Err("no config here — write a pitcrew.yaml, or: pitcrew init <dir>".into())
}

fn explicit(t: &Path) -> Result<find::Found, String> {
    if t.is_dir() {
        return find::in_dir(t).ok_or_else(|| format!("no config in {}", t.display()));
    }
    if t.is_file() {
        let dir = t.parent().unwrap_or(Path::new("."));
        let format = find::CONFIG_NAMES
            .iter()
            .find(|(n, _)| t.file_name().is_some_and(|f| f == *n))
            .map(|(_, f)| *f)
            .unwrap_or(Format::Yaml);
        return Ok(find::Found {
            root: find::declared_root(t).unwrap_or_else(|| dir.to_path_buf()),
            file: t.to_path_buf(),
            format,
            shadowed: None,
        });
    }
    Err(format!("no such config: {}", t.display()))
}

/// Find it and load it.
pub fn open(target: Option<&Path>, name: Option<&str>) -> Result<Session, String> {
    let found = locate(target, name)?;
    open_found(found)
}

pub fn open_found(found: find::Found) -> Result<Session, String> {
    if found.format == Format::Sh {
        // Honest rather than helpful-sounding. Reading it means running it.
        return Err(format!(
            "{}: the bash config format is not readable from this build — it is a \
             shell script, so loading it means running it.\n  Convert it first with \
             the bash implementation: pitcrew migrate",
            found.file.display()
        ));
    }
    let loaded = load::load_yaml(&found.file, &found.root)
        .map_err(|e| format!("{}:{e}", found.file.display()))?;
    let session = registry::slug(&loaded.project.name);
    Ok(Session {
        found,
        loaded,
        session,
        home: registry::home(),
    })
}
