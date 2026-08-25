//! Mapping flattened YAML paths onto the config model.
//!
//! Two things here are worth knowing before changing anything.
//!
//! **Warnings are returned, not printed.** The bash version wrote them to
//! stderr from deep inside the loader, which meant `pitcrew check` could not
//! render them any differently from a live load and the GUI could not show them
//! at all. They are data now. The policy is unchanged: *warn, never die, on
//! anything merely unusual* — only a genuinely unloadable config is an error.
//!
//! **Path resolution is deferred to the end.** `root:`, `dir:`, `cmd:` and
//! `watch:` may appear in any order, so a path resolved the moment it is read
//! would be resolved against whatever root had been seen so far. Everything is
//! recorded raw, then resolved in one pass once the whole document is known.

use std::path::{Path, PathBuf};

use crate::model::{app_name_ok, role_name_ok, App, Component, Project, Role};
use crate::yaml::{self, Entry};

/// Display settings a config may pin, each becoming `PITCREW_<NAME>`.
///
/// An allowlist rather than "anything under `dashboard:`" so that a typo is
/// still an error. Catching typos is the main reason this format exists.
const DASHBOARD_KEYS: &[&str] = &[
    "theme",
    "color",
    "icons",
    "refresh",
    "graph",
    "graph_scale",
    "gauge",
    "ram_cell",
    "history",
    "mouse",
    "narrow_at",
    "compact_at",
    "micro_at",
    "xl_at",
    "error_pattern",
    "error_scan_max",
    "health_interval",
    "dep_interval",
    "log_keep",
    "restart",
    "restart_backoff",
    "restart_max",
    "restart_reset",
    "start_concurrency",
    "start_slot_secs",
];

/// A config that could not be loaded at all.
#[derive(Debug)]
pub enum LoadError {
    Io(std::io::Error),
    Parse(yaml::ParseError),
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoadError::Io(e) => write!(f, "{e}"),
            LoadError::Parse(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for LoadError {}

/// A loaded project, plus everything odd that was noticed on the way.
pub struct Loaded {
    pub project: Project,
    pub warnings: Vec<String>,
}

/// The include depth limit.
///
/// A config that needs five levels of indirection to say what it runs is a
/// config nobody can follow, and the limit is also what stops a cycle from
/// being a hang.
const MAX_INCLUDE_DEPTH: usize = 4;

/// Read a `pitcrew.yaml` into the model.
///
/// `root` is the project root, which must already be known: paths resolve
/// against it, so it cannot come out of the file it is used to read.
pub fn load_yaml(file: &Path, root: &Path) -> Result<Loaded, LoadError> {
    let mut entries = Vec::new();
    let mut warnings = Vec::new();
    collect(file, 0, &mut entries, &mut warnings)?;
    let mut loaded = from_entries(entries, file, root);
    // Include warnings come first: they are about which files were read at
    // all, which is context for everything the loader says afterwards.
    warnings.extend(loaded.warnings);
    loaded.warnings = warnings;
    Ok(loaded)
}

/// Flatten a file and everything it includes, in the order the model should
/// see them.
///
/// An included file's entries come FIRST, so the includer's own keys override
/// them. That is what makes a registry entry able to point at a repo's config
/// and still say `name:` differently.
fn collect(
    file: &Path,
    depth: usize,
    out: &mut Vec<Entry>,
    warnings: &mut Vec<String>,
) -> Result<(), LoadError> {
    let text = std::fs::read_to_string(file).map_err(LoadError::Io)?;
    let entries = yaml::parse(&text).map_err(LoadError::Parse)?;

    // `include:` must be the FIRST key. Anywhere else and whether a key
    // overrides the include or is overridden BY it depends on line order,
    // which is not a thing anyone should have to reason about.
    let include = entries.first().filter(|e| e.path == "include").cloned();
    for e in entries.iter().skip(1) {
        if e.path == "include" {
            warnings.push(format!(
                "config: {}: include must be the first key — this one is ignored",
                name_of(file)
            ));
        }
    }

    if let Some(inc) = include {
        if depth >= MAX_INCLUDE_DEPTH {
            warnings.push(format!(
                "config: {}: includes are nested more than {MAX_INCLUDE_DEPTH} deep —                  '{}' was not read",
                name_of(file),
                inc.value
            ));
        } else {
            // Relative to the including file, which is the only base that
            // makes a registry entry portable.
            let target = if Path::new(&inc.value).is_absolute() {
                PathBuf::from(&inc.value)
            } else {
                file.parent().unwrap_or(Path::new(".")).join(&inc.value)
            };
            match collect(&target, depth + 1, out, warnings) {
                Ok(()) => {}
                // A missing include is a warning, not a refusal: the rest of
                // the config is still a config, and saying which file is
                // missing is more use than refusing to load anything.
                Err(e) => warnings.push(format!(
                    "config: {}: include '{}' could not be read — {e}",
                    name_of(file),
                    inc.value
                )),
            }
        }
    }

    out.extend(entries);
    Ok(())
}

fn name_of(p: &Path) -> String {
    p.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| p.to_string_lossy().into_owned())
}

/// The mapping itself, split out so it can be driven from a string in tests.
pub fn from_entries(entries: Vec<Entry>, file: &Path, root: &Path) -> Loaded {
    let mut w = Warnings::new(file);
    let mut p = Project {
        file: file.to_path_buf(),
        root: root.to_path_buf(),
        name: root
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default(),
        emoji: "🏁".into(),
        wait_secs: 120,
        ..Default::default()
    };

    // Raw, unresolved paths, kept until the whole document has been read.
    let mut app_roots: Vec<(String, String)> = Vec::new();
    let mut comp_roots: Vec<(String, String)> = Vec::new();
    let mut comp_dirs: Vec<(String, String)> = Vec::new();
    let mut apps_off: Vec<String> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    // Entries from an included file arrive before the includer's own.
    let crossed_include = entries.iter().any(|e| e.path == "include");

    for e in &entries {
        // A scalar written twice is one of them being ignored. Which one wins
        // is defined (the later), but silently is not good enough.
        //
        // Deliberately NOT reported across an include boundary: overriding an
        // included value is exactly what including is for, and warning on it
        // would make every registry entry noisy.
        if !e.path.ends_with(|c: char| c.is_ascii_digit())
            && seen.contains(&e.path)
            && !crossed_include
        {
            w.push(format!("'{}' is set twice — the later one wins", e.path));
        }
        seen.push(e.path.clone());

        let v = expand(&e.value, root);
        let path = e.path.as_str();
        match path {
            "name" => p.name = v,
            "emoji" => p.emoji = v,
            // Already resolved before the file was opened; see load_yaml.
            "root" | "include" => {}
            "wait" => match v.parse() {
                Ok(n) => p.wait_secs = n,
                Err(_) => w.push(format!("wait: '{v}' is not a number of seconds")),
            },
            "deps_ready" => p.deps_ready = v,
            _ if path.starts_with("deps.") => p.deps.push(v),
            _ if path.starts_with("protected_deps.") => p.protected_deps.push(v),
            _ if path.starts_with("env.") => role_mut(&mut p, &path[4..]).env = v,
            _ if path.starts_with("max.") => role_mut(&mut p, &path[4..]).max = v,
            _ if path.starts_with("shells.") => p.shells.push((path[7..].into(), v)),
            _ if path.starts_with("doctor.") => p.doctor.push((path[7..].into(), v)),
            _ if path.starts_with("dashboard.") => {
                let key = &path[10..];
                if DASHBOARD_KEYS.contains(&key) {
                    p.dashboard.push((key.into(), v));
                } else {
                    w.push(format!("unknown dashboard setting '{key}'"));
                }
            }
            _ if path.starts_with("apps.") => app_key(
                &mut p,
                &path[5..],
                v,
                &mut w,
                &mut app_roots,
                &mut comp_roots,
                &mut comp_dirs,
                &mut apps_off,
            ),
            // A block key with a scalar under it. Says what is wrong rather
            // than reporting it as unknown, which it is not.
            "deps" | "protected_deps" | "env" | "max" | "apps" | "shells" | "doctor"
            | "dashboard" => w.push(format!("'{path}' has no value under it")),
            _ => w.push(format!("unknown key '{path}'")),
        }
    }

    resolve_paths(&mut p, &app_roots, &comp_roots, &comp_dirs);

    // A group switched off switches off everything in it — including roles
    // declared after the `enabled: false` line, which is why it is applied here
    // rather than when the key was read.
    for app in &mut p.apps {
        if apps_off.contains(&app.name) {
            app.enabled = false;
            for c in &mut app.components {
                c.enabled = false;
            }
        }
    }

    Loaded {
        project: p,
        warnings: w.into_inner(),
    }
}

#[allow(clippy::too_many_arguments)]
fn app_key(
    p: &mut Project,
    rest: &str,
    v: String,
    w: &mut Warnings,
    app_roots: &mut Vec<(String, String)>,
    comp_roots: &mut Vec<(String, String)>,
    comp_dirs: &mut Vec<(String, String)>,
    apps_off: &mut Vec<String>,
) {
    let Some((app, key)) = rest.split_once('.') else {
        w.push(format!(
            "apps.{rest} must be a block of settings, not a value"
        ));
        return;
    };
    if !app_name_ok(app) {
        w.push(format!(
            "apps.{app}: an app name must be letters, digits, _ or - — it becomes \
             half of a component id, a log file name and a unit name"
        ));
        return;
    }
    ensure_app(p, app);

    match key {
        "url_path" => p.app_mut(app).url_path = v,
        "enabled" => {
            if !truthy(&v, &format!("apps.{app}.enabled"), w) {
                apps_off.push(app.into());
            }
        }
        "root" => {
            p.app_mut(app).src_root = v.clone();
            app_roots.push((app.into(), v));
        }
        _ => match key.split_once('.') {
            Some((role, sub)) => {
                if !role_name_ok(role) {
                    w.push(format!(
                        "apps.{app}.{role}: a role name must be letters, digits or _ \
                         — it becomes half of a component id"
                    ));
                    return;
                }
                // `watch.0`, `watch.1` — a list of paths under one key.
                let sub = if sub.starts_with("watch.") {
                    "watch"
                } else {
                    sub
                };
                role_key(p, app, role, sub, v, w, comp_roots, comp_dirs);
            }
            None => {
                // A bare key with a scalar under it. If it looks like a role
                // someone forgot to indent, say so in those words.
                if role_name_ok(key) {
                    w.push(format!(
                        "apps.{app}.{key} must be a block of settings (cmd:, port:, …), \
                         not a value"
                    ));
                } else {
                    w.push(format!("unknown key 'apps.{app}.{key}'"));
                }
            }
        },
    }
}

#[allow(clippy::too_many_arguments)]
fn role_key(
    p: &mut Project,
    app: &str,
    role: &str,
    key: &str,
    v: String,
    w: &mut Warnings,
    comp_roots: &mut Vec<(String, String)>,
    comp_dirs: &mut Vec<(String, String)>,
) {
    let name = format!("{role}-{app}");
    match key {
        // The command is what brings a component into existence. A role
        // without one is absent, not down.
        "cmd" => {
            ensure_component(p, app, role);
            let c = p.component_mut(&name);
            c.src_cmd = v.clone();
            c.run_cmd = v;
        }
        "port" => match v.parse::<u16>() {
            Ok(n) => set_field(p, app, role, |c| c.port = Some(n)),
            Err(_) => w.push(format!(
                "apps.{app}.{role}.port: '{v}' is not a port number"
            )),
        },
        "health" => set_field(p, app, role, |c| c.health = v.clone()),
        "max" => set_field(p, app, role, |c| c.max = v.clone()),
        "protected" => {
            let on = truthy(&v, &format!("apps.{app}.{role}.protected"), w);
            set_field(p, app, role, |c| c.protected = on);
        }
        "enabled" => {
            let on = truthy(&v, &format!("apps.{app}.{role}.enabled"), w);
            set_field(p, app, role, |c| c.enabled = on);
        }
        "root" => {
            set_field(p, app, role, |c| c.src_root = v.clone());
            comp_roots.push((name, v));
        }
        "dir" => {
            set_field(p, app, role, |c| c.src_dir = v.clone());
            comp_dirs.push((name, v));
        }
        "watch" => set_field(p, app, role, |c| c.src_watch.push(v.clone())),
        _ => w.push(format!("unknown key 'apps.{app}.{role}.{key}'")),
    }
}

/// Resolve `root`/`dir`/`watch` and fold the `cd` into each command.
///
/// Three layers, most specific first: the component's own root, the app's root,
/// the project root. Only now is every one of them known.
fn resolve_paths(
    p: &mut Project,
    app_roots: &[(String, String)],
    comp_roots: &[(String, String)],
    comp_dirs: &[(String, String)],
) {
    let project_root = p.root.clone();
    let lookup = |list: &[(String, String)], k: &str| {
        list.iter()
            .rev()
            .find(|(n, _)| n == k)
            .map(|(_, v)| v.clone())
    };

    for app in &mut p.apps {
        let app_root = lookup(app_roots, &app.name);
        for c in &mut app.components {
            let own_root = lookup(comp_roots, &c.name);
            let base = own_root
                .clone()
                .or_else(|| app_root.clone())
                .map(|r| abs(&r, &project_root))
                .unwrap_or_else(|| project_root.clone());

            let dir_raw = lookup(comp_dirs, &c.name);
            let dir = match &dir_raw {
                Some(d) => abs(d, &base),
                None => base.clone(),
            };

            // `cd` into it only when the config actually said where. An app
            // with no dir and no root has always run from wherever pitcrew was
            // invoked, and changing that would move every such command.
            if dir_raw.is_some() || own_root.is_some() || app_root.is_some() {
                c.run_cmd = format!(
                    "cd {} && {}",
                    shell_quote(&dir.to_string_lossy()),
                    c.run_cmd
                );
                // A component with a dir and no watch dir watches where it runs.
                if c.src_watch.is_empty() {
                    c.watch = vec![dir.clone()];
                }
            }
            for raw in &c.src_watch {
                c.watch.push(abs(raw, &base));
            }
        }
    }
}

/// Absolute stays; `~` is the home directory; anything else is relative to
/// `base`.
///
/// `~` used to be the one path spelling that did NOT work: `$HOME` expanded and
/// `~` did not, so `dir: ~/work/api` became `$ROOT/~/work/api` — a directory
/// that cannot exist, which `check` reported as loading clean and which then
/// failed at start time with a path nobody could parse.
fn abs(p: &str, base: &Path) -> PathBuf {
    if p.is_empty() {
        return base.to_path_buf();
    }
    if let Some(rest) = p.strip_prefix("~/") {
        if let Some(home) = home_dir() {
            return home.join(rest);
        }
    }
    if p == "~" {
        if let Some(home) = home_dir() {
            return home;
        }
    }
    let path = Path::new(p);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        base.join(path)
    }
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

/// Only `$ROOT` and `$HOME` expand, in both `$X` and `${X}` spellings.
///
/// Everything else is left exactly as written: start commands are handed to a
/// shell, and expanding `$JAVA_HOME` or `$PWD` here instead of there would be
/// both surprising and wrong. A variable that merely *starts* with `ROOT` —
/// `$ROOTLESS` — is not `$ROOT`, which is why the bare form checks the next
/// character.
fn expand(s: &str, root: &Path) -> String {
    if !s.contains('$') {
        return s.to_string();
    }
    let root = root.to_string_lossy().into_owned();
    let home = home_dir()
        .map(|h| h.to_string_lossy().into_owned())
        .unwrap_or_default();

    let mut out = String::with_capacity(s.len());
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] != '$' {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        let rest: String = chars[i + 1..].iter().collect();
        let mut matched = false;
        for (name, value) in [("ROOT", &root), ("HOME", &home)] {
            let braced = format!("{{{name}}}");
            if rest.starts_with(&braced) {
                out.push_str(value);
                i += 1 + braced.len();
                matched = true;
                break;
            }
            if rest.starts_with(name) {
                let after = chars.get(i + 1 + name.len());
                // `$ROOTLESS` is not `$ROOT`.
                if !after.is_some_and(|c| c.is_ascii_alphanumeric() || *c == '_') {
                    out.push_str(value);
                    i += 1 + name.len();
                    matched = true;
                    break;
                }
            }
        }
        if !matched {
            out.push('$');
            i += 1;
        }
    }
    out
}

/// Single-quote for a shell, the way bash's `${x@Q}` does.
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// The spellings people actually write. An unrecognised word is reported rather
/// than treated as false: a config that meant to protect something and quietly
/// did not is the failure that matters.
fn truthy(v: &str, path: &str, w: &mut Warnings) -> bool {
    match v {
        "true" | "True" | "TRUE" | "yes" | "Yes" | "YES" | "on" | "On" | "ON" | "1" => true,
        "false" | "False" | "FALSE" | "no" | "No" | "NO" | "off" | "Off" | "OFF" | "0" | "" => {
            false
        }
        other => {
            w.push(format!(
                "{path}: '{other}' is not a yes/no value — treating it as no"
            ));
            false
        }
    }
}

struct Warnings {
    file: String,
    out: Vec<String>,
}

impl Warnings {
    fn new(file: &Path) -> Warnings {
        Warnings {
            file: file
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| file.to_string_lossy().into_owned()),
            out: Vec::new(),
        }
    }
    fn push(&mut self, msg: String) {
        self.out.push(format!("config: {}: {msg}", self.file));
    }
    fn into_inner(self) -> Vec<String> {
        self.out
    }
}

// ── small mutable helpers ───────────────────────────────────────────────────

fn ensure_app(p: &mut Project, name: &str) {
    if !p.apps.iter().any(|a| a.name == name) {
        p.apps.push(App {
            name: name.into(),
            enabled: true,
            ..Default::default()
        });
    }
}

fn ensure_component(p: &mut Project, app: &str, role: &str) {
    ensure_app(p, app);
    let name = format!("{role}-{app}");
    let a = p.app_mut(app);
    if !a.components.iter().any(|c| c.name == name) {
        a.components.push(Component {
            name,
            app: app.into(),
            role: role.into(),
            enabled: true,
            ..Default::default()
        });
    }
}

/// Apply a setting to a component, creating it if a key arrived before `cmd:`.
///
/// A component created this way still has no command, so it still does not
/// exist as a role until one arrives — `port:` alone never conjures a service.
fn set_field(p: &mut Project, app: &str, role: &str, f: impl FnOnce(&mut Component)) {
    ensure_component(p, app, role);
    let name = format!("{role}-{app}");
    f(p.component_mut(&name));
}

fn role_mut<'a>(p: &'a mut Project, name: &str) -> &'a mut Role {
    if !p.roles.iter().any(|r| r.name == name) {
        p.roles.push(Role {
            name: name.into(),
            ..Default::default()
        });
    }
    p.roles.iter_mut().find(|r| r.name == name).unwrap()
}

impl Project {
    fn app_mut(&mut self, name: &str) -> &mut App {
        self.apps
            .iter_mut()
            .find(|a| a.name == name)
            .expect("app exists")
    }
    fn component_mut(&mut self, name: &str) -> &mut Component {
        self.apps
            .iter_mut()
            .flat_map(|a| a.components.iter_mut())
            .find(|c| c.name == name)
            .expect("component exists")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load(text: &str) -> Loaded {
        let entries = yaml::parse(text).expect("parses");
        from_entries(entries, Path::new("/p/pitcrew.yaml"), Path::new("/p"))
    }

    fn warnings(text: &str) -> String {
        load(text).warnings.join("\n")
    }

    /// Catching typos is the main reason this format exists, so an unknown key
    /// is reported with its exact path rather than ignored.
    #[test]
    fn an_unknown_key_is_reported_with_its_path() {
        assert!(
            warnings("apps:\n  a:\n    be:\n      cmd: x\n      prot: yes\n")
                .contains("unknown key 'apps.a.be.prot'")
        );
        assert!(warnings("nmae: x\n").contains("unknown key 'nmae'"));
        assert!(
            warnings("dashboard:\n  thmee: mono\n").contains("unknown dashboard setting 'thmee'")
        );
    }

    /// A block key with a scalar under it is not an unknown key, and saying so
    /// points at the actual mistake.
    #[test]
    fn a_block_key_with_a_value_says_what_is_wrong() {
        assert!(warnings("apps: x\n").contains("has no value under it"));
        assert!(warnings("apps:\n  a:\n    be: x\n")
            .contains("must be a block of settings (cmd:, port:, …)"));
    }

    /// Which one wins is defined; being quiet about it is not good enough.
    #[test]
    fn a_key_written_twice_says_so() {
        let w = warnings("name: one\nname: two\n");
        assert!(w.contains("is set twice"), "{w}");
        assert_eq!(load("name: one\nname: two\n").project.name, "two");
    }

    /// A list is not a duplicate key — `deps.0`, `deps.1` are different paths,
    /// and warning on every list would make the check useless.
    #[test]
    fn a_list_is_not_a_duplicate_key() {
        assert!(!warnings("deps: [a, b, c]\n").contains("set twice"));
    }

    /// An unrecognised word is reported rather than treated as false. A config
    /// that meant to protect something and quietly did not is the failure that
    /// matters.
    #[test]
    fn a_yes_no_value_that_is_neither_is_reported() {
        let w = warnings("apps:\n  a:\n    be:\n      cmd: x\n      protected: maybe\n");
        assert!(w.contains("'maybe' is not a yes/no value"), "{w}");
        assert!(
            !load("apps:\n  a:\n    be:\n      cmd: x\n      protected: maybe\n")
                .project
                .component("be-a")
                .unwrap()
                .protected
        );
    }

    #[test]
    fn protected_accepts_the_spellings_people_actually_write() {
        for word in ["true", "True", "yes", "YES", "on", "1"] {
            let text = format!("apps:\n  a:\n    be:\n      cmd: x\n      protected: {word}\n");
            assert!(
                load(&text).project.component("be-a").unwrap().protected,
                "{word} should mean yes"
            );
        }
        for word in ["false", "No", "off", "0"] {
            let text = format!("apps:\n  a:\n    be:\n      cmd: x\n      protected: {word}\n");
            assert!(
                !load(&text).project.component("be-a").unwrap().protected,
                "{word}"
            );
        }
    }

    /// Switching off a group switches off every role it has AND every role it
    /// gains later in the file — which is why it is applied after the whole
    /// document is read, not when the key is seen.
    #[test]
    fn a_disabled_app_disables_roles_declared_after_it() {
        let p =
            load("apps:\n  a:\n    enabled: false\n    be:\n      cmd: x\n    fe:\n      cmd: y\n")
                .project;
        assert!(!p.app("a").unwrap().enabled);
        assert!(!p.component("be-a").unwrap().enabled);
        assert!(
            !p.component("fe-a").unwrap().enabled,
            "declared after the switch"
        );
        // It keeps its row and its port; off is not absent.
        assert_eq!(p.components().count(), 2);
    }

    /// Only `$ROOT` and `$HOME` expand. Everything else reaches the shell that
    /// runs the command, where it means what the user expects.
    #[test]
    fn root_and_home_expand_and_nothing_else_does() {
        let p = load("apps:\n  a:\n    be:\n      cmd: $ROOT/x $JAVA_HOME ${ROOT}/y\n").project;
        let cmd = &p.component("be-a").unwrap().src_cmd;
        assert!(cmd.starts_with("/p/x "), "{cmd}");
        assert!(cmd.contains("$JAVA_HOME"), "left for the shell: {cmd}");
        assert!(cmd.ends_with("/p/y"), "{cmd}");
    }

    /// `$ROOTLESS` is not `$ROOT`. Expanding the prefix would corrupt a
    /// variable name that merely starts the same way.
    #[test]
    fn a_variable_that_merely_starts_with_root_is_left_alone() {
        let p = load("apps:\n  a:\n    be:\n      cmd: $ROOTLESS\n").project;
        assert_eq!(p.component("be-a").unwrap().src_cmd, "$ROOTLESS");
    }

    #[test]
    fn a_role_name_with_a_dash_is_reported() {
        let w = warnings("apps:\n  a:\n    admin-web:\n      cmd: x\n");
        assert!(w.contains("a role name must be"), "{w}");
    }

    /// A port that is not a port is a warning, not a silent zero — zero renders
    /// as a real port number.
    #[test]
    fn a_port_that_is_not_a_number_is_reported() {
        let w = warnings("apps:\n  a:\n    be:\n      cmd: x\n      port: eighty\n");
        assert!(w.contains("is not a port number"), "{w}");
        assert_eq!(
            load("apps:\n  a:\n    be:\n      cmd: x\n      port: eighty\n")
                .project
                .component("be-a")
                .unwrap()
                .port,
            None
        );
    }

    #[test]
    fn shell_quoting_survives_a_directory_with_a_quote_in_it() {
        assert_eq!(shell_quote("/a/b"), "'/a/b'");
        assert_eq!(shell_quote("/it's"), r"'/it'\''s'");
    }

    /// A tilde used to be the one path spelling that did NOT work: `$HOME`
    /// expanded and `~` did not, so `dir: ~/work/api` became `$ROOT/~/work/api`
    /// — a directory that cannot exist, which `check` reported as clean.
    #[test]
    fn a_tilde_is_the_home_directory_not_a_relative_path() {
        let home = home_dir().expect("HOME is set in a test environment");
        assert_eq!(abs("~/work/api", Path::new("/p")), home.join("work/api"));
        assert_eq!(abs("~", Path::new("/p")), home);
        assert_eq!(abs("rel", Path::new("/p")), Path::new("/p/rel"));
        // A genuinely absolute path per platform: a leading slash with no
        // drive letter is not absolute on Windows, so `/abs` there is a
        // relative path and would be joined rather than kept.
        let already = std::env::temp_dir();
        assert!(already.is_absolute());
        assert_eq!(abs(&already.to_string_lossy(), Path::new("/p")), already);
    }
}
