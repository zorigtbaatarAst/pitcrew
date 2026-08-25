//! The config model. One model, and front ends onto it.
//!
//! Everything below this layer is format-blind — nothing downstream learns
//! whether a project came from YAML or from anywhere else. The shape mirrors
//! what `pitcrew config --json` already emits, because that endpoint is the
//! desktop app's editable view of a project and is a contract in its own right.
//!
//! **A role exists for an app if, and only if, it has a start command.** That
//! is the whole of the asymmetric-role design: a missing role renders as `n/a`,
//! is never started, and is never counted as down. It is not the same as a role
//! that is present and disabled, which keeps its row, its port and its cap.

use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Yaml,
    /// The legacy `pitcrew.config.sh`. Not loadable from Rust — it is a shell
    /// script — but recognised so the tool can say so instead of reporting a
    /// missing config.
    Sh,
}

impl Format {
    pub const fn as_str(self) -> &'static str {
        match self {
            Format::Yaml => "yaml",
            Format::Sh => "sh",
        }
    }
}

/// A role's defaults, shared by every component that has that role.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Role {
    pub name: String,
    /// Prepended verbatim in front of every start command of this role, which
    /// is why it has to reach a shell rather than being an argv prefix.
    pub env: String,
    /// The role's RAM cap, as written (`4G`). A per-component `max:` overrides
    /// it, and a machine-local `pitcrew limit` overrides both.
    pub max: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Component {
    /// `<role>-<app>`. Also the log file name and the systemd unit name, which
    /// is why neither half may contain surprising characters.
    pub name: String,
    pub app: String,
    pub role: String,
    /// What the file says. Kept separate from [`Self::run_cmd`] because an
    /// editor showing the resolved command back to you would be showing you
    /// something you never wrote.
    pub src_cmd: String,
    /// What actually runs — [`Self::src_cmd`] with a `cd` folded in front when
    /// the config said where.
    pub run_cmd: String,
    pub src_dir: String,
    pub src_root: String,
    pub src_watch: Vec<String>,
    /// Resolved absolute source directories for `pitcrew stale`.
    pub watch: Vec<PathBuf>,
    pub port: Option<u16>,
    /// The health endpoint path. Empty means an open port is enough.
    pub health: String,
    pub max: String,
    /// Off keeps the row, the port and the cap, and simply says off — an
    /// excluded service that VANISHED is one you spend an afternoon looking for.
    pub enabled: bool,
    /// `diagnose` will never propose stopping this to free memory.
    pub protected: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct App {
    pub name: String,
    /// Cosmetic suffix after non-frontend URLs in `pitcrew urls`.
    pub url_path: String,
    pub src_root: String,
    pub enabled: bool,
    /// In the order the file declares them.
    pub components: Vec<Component>,
}

#[derive(Debug, Clone, Default)]
pub struct Project {
    pub file: PathBuf,
    pub root: PathBuf,
    pub name: String,
    pub emoji: String,
    pub format_sh: bool,
    /// In document order — this is where dashboard ordering comes from.
    pub apps: Vec<App>,
    pub deps: Vec<String>,
    pub protected_deps: Vec<String>,
    pub deps_ready: String,
    pub roles: Vec<Role>,
    pub wait_secs: u64,
    pub shells: Vec<(String, String)>,
    /// Label → shell command, in order. `doctor` runs each after its own.
    pub doctor: Vec<(String, String)>,
    /// Display settings a config pinned, already checked against the allowlist.
    pub dashboard: Vec<(String, String)>,
}

impl Project {
    /// Every component of every app, in declaration order.
    pub fn components(&self) -> impl Iterator<Item = &Component> {
        self.apps.iter().flat_map(|a| a.components.iter())
    }

    pub fn component(&self, name: &str) -> Option<&Component> {
        self.components().find(|c| c.name == name)
    }

    pub fn app(&self, name: &str) -> Option<&App> {
        self.apps.iter().find(|a| a.name == name)
    }

    /// A role's defaults, or an empty set if nothing declared it.
    pub fn role(&self, name: &str) -> Option<&Role> {
        self.roles.iter().find(|r| r.name == name)
    }

    /// Every distinct role name in use, in first-seen order.
    pub fn role_names(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for c in self.components() {
            if !out.contains(&c.role) {
                out.push(c.role.clone());
            }
        }
        out
    }

    /// The cap for a component, as written: per-component, then per-role, then
    /// the `be` default. A role nobody budgeted for still needs a number —
    /// a meter with no scale can draw nothing at all.
    pub fn max_for(&self, component: &Component) -> String {
        if !component.max.is_empty() {
            return component.max.clone();
        }
        if let Some(max) = self
            .role(&component.role)
            .map(|r| &r.max)
            .filter(|m| !m.is_empty())
        {
            return max.clone();
        }
        self.role("be")
            .map(|r| r.max.clone())
            .filter(|m| !m.is_empty())
            .unwrap_or_default()
    }
}

/// Is this usable as half of a component id?
///
/// A role name becomes the part before the first `-` in `<role>-<app>`, so it
/// may not contain one; letters, digits and `_` only.
pub fn role_name_ok(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// An app name is addressed by dotted path in the config, and becomes a
/// component name, a log file name and a systemd unit name. A dot in it would
/// be ambiguous in the first of those and awkward in the rest.
pub fn app_name_ok(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn comp(app: &str, role: &str, max: &str) -> Component {
        Component {
            name: format!("{role}-{app}"),
            app: app.into(),
            role: role.into(),
            max: max.into(),
            enabled: true,
            ..Default::default()
        }
    }

    #[test]
    fn role_names_may_not_contain_the_separator() {
        assert!(role_name_ok("be"));
        assert!(role_name_ok("admin_web"));
        assert!(
            !role_name_ok("admin-web"),
            "it becomes half of <role>-<app>"
        );
        assert!(!role_name_ok(""));
    }

    #[test]
    fn app_names_may_not_contain_a_dot() {
        assert!(app_name_ok("storefront"));
        assert!(app_name_ok("my-app"));
        assert!(
            !app_name_ok("my.app"),
            "the config addresses it by dotted path"
        );
    }

    /// Per-component beats per-role beats the `be` default. A role nobody
    /// budgeted for still needs a number, or its meter has no scale.
    #[test]
    fn cap_resolution_is_component_then_role_then_be() {
        let p = Project {
            roles: vec![
                Role {
                    name: "be".into(),
                    env: String::new(),
                    max: "4G".into(),
                },
                Role {
                    name: "fe".into(),
                    env: String::new(),
                    max: "6G".into(),
                },
            ],
            ..Default::default()
        };
        assert_eq!(p.max_for(&comp("a", "be", "1G")), "1G", "component wins");
        assert_eq!(p.max_for(&comp("a", "fe", "")), "6G", "then the role");
        assert_eq!(
            p.max_for(&comp("a", "worker", "")),
            "4G",
            "then be's default"
        );
    }

    #[test]
    fn roles_are_listed_in_first_seen_order() {
        let p = Project {
            apps: vec![App {
                name: "a".into(),
                components: vec![
                    comp("a", "worker", ""),
                    comp("a", "be", ""),
                    comp("a", "worker", ""),
                ],
                ..Default::default()
            }],
            ..Default::default()
        };
        assert_eq!(p.role_names(), ["worker", "be"]);
    }
}
