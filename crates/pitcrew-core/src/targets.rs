//! Turning CLI words into a concrete list of components.
//!
//! `all`, `backends`, `sales`, `worker`, `be-sales`, `@profile` — one grammar,
//! used by `start`, `stop`, `restart` and everything else that acts on part of
//! a stack.
//!
//! Two rules here look like details and are not:
//!
//! **A group target skips disabled components; naming one directly does not.**
//! `enabled: false` is exactly the statement "not part of the group by
//! default", so `all` passes it by — but `pitcrew start be-reports` is a
//! deliberate instruction, and a switch you cannot override is a trap.
//!
//! **`deps` resolves to no components, and that is not the same as nothing.**
//! Docker dependencies are not components, so there is nothing to put in the
//! list — but the word is meaningful and the caller has to act on it. Dropping
//! it silently is what once made `pitcrew stop deps` a no-op that exited 0.

use crate::model::Project;

/// What a set of target words came to.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Resolved {
    /// Component names, deduped, in the order the words asked for them.
    pub components: Vec<String>,
    /// `deps` was named. Carries no components; the caller acts on it.
    pub deps: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnknownTarget {
    pub word: String,
    pub apps: Vec<String>,
    pub roles: Vec<String>,
}

impl std::fmt::Display for UnknownTarget {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "unknown target '{}' (apps: {} · roles: {})",
            self.word,
            self.apps.join(" "),
            self.roles.join(" ")
        )
    }
}

impl std::error::Error for UnknownTarget {}

/// Resolve target words against a project.
///
/// Profile references (`@name`) must already have been expanded — see
/// [`crate::profiles::expand`]. Keeping that out of here is what lets this
/// function stay pure and testable without a filesystem.
pub fn resolve(p: &Project, words: &[String]) -> Result<Resolved, UnknownTarget> {
    let mut out = Resolved::default();
    let push = |name: &str, out: &mut Resolved| {
        if !out.components.iter().any(|c| c == name) {
            out.components.push(name.to_string());
        }
    };

    for word in words {
        match word.as_str() {
            "all" => {
                for c in enabled(p) {
                    push(c, &mut out);
                }
            }
            "backends" => {
                for c in enabled_role(p, "be") {
                    push(c, &mut out);
                }
            }
            "frontends" => {
                for c in enabled_role(p, "fe") {
                    push(c, &mut out);
                }
            }
            "deps" => out.deps = true,
            w => {
                // A component named outright — including a disabled one.
                if p.component(w).is_some() {
                    push(w, &mut out);
                    continue;
                }
                // An app: every role in the group, minus the ones switched off.
                // Apps win a name clash with a role; `validate` warns when
                // there is one, because the role then becomes unreachable.
                if p.app(w).is_some() {
                    for c in p
                        .components()
                        .filter(|c| c.app == w && c.enabled)
                        .map(|c| c.name.as_str())
                        .collect::<Vec<_>>()
                    {
                        push(c, &mut out);
                    }
                    continue;
                }
                // A role, across every app that has one — `pitcrew restart worker`.
                if p.components().any(|c| c.role == w) {
                    for c in enabled_role(p, w) {
                        push(c, &mut out);
                    }
                    continue;
                }
                return Err(UnknownTarget {
                    word: w.to_string(),
                    apps: p.apps.iter().map(|a| a.name.clone()).collect(),
                    roles: p.role_names(),
                });
            }
        }
    }
    Ok(out)
}

fn enabled(p: &Project) -> Vec<&str> {
    p.components()
        .filter(|c| c.enabled)
        .map(|c| c.name.as_str())
        .collect()
}

fn enabled_role<'a>(p: &'a Project, role: &str) -> Vec<&'a str> {
    p.components()
        .filter(|c| c.enabled && c.role == role)
        .map(|c| c.name.as_str())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{App, Component};

    /// two apps: `sales` (be + fe + worker, fe disabled), `admin` (fe only)
    fn project() -> Project {
        let comp = |app: &str, role: &str, enabled: bool| Component {
            name: format!("{role}-{app}"),
            app: app.into(),
            role: role.into(),
            enabled,
            ..Default::default()
        };
        Project {
            apps: vec![
                App {
                    name: "sales".into(),
                    enabled: true,
                    components: vec![
                        comp("sales", "be", true),
                        comp("sales", "fe", false),
                        comp("sales", "worker", true),
                    ],
                    ..Default::default()
                },
                App {
                    name: "admin".into(),
                    enabled: true,
                    components: vec![comp("admin", "fe", true)],
                    ..Default::default()
                },
            ],
            ..Default::default()
        }
    }

    fn go(words: &[&str]) -> Resolved {
        let w: Vec<String> = words.iter().map(|s| s.to_string()).collect();
        resolve(&project(), &w).expect("resolves")
    }

    /// `enabled: false` means "not part of the group by default", so a group
    /// target passes it by.
    #[test]
    fn all_covers_every_enabled_component_in_declaration_order() {
        assert_eq!(
            go(&["all"]).components,
            ["be-sales", "worker-sales", "fe-admin"]
        );
    }

    /// …but naming it outright is a deliberate instruction, and a switch you
    /// cannot override is a trap.
    #[test]
    fn a_disabled_component_named_outright_is_still_reached() {
        assert_eq!(go(&["fe-sales"]).components, ["fe-sales"]);
    }

    #[test]
    fn an_app_covers_its_enabled_group() {
        assert_eq!(go(&["sales"]).components, ["be-sales", "worker-sales"]);
    }

    /// `pitcrew restart worker` restarts every app's worker. This is what makes
    /// a role an ordinary name rather than one of two hard-coded slots.
    #[test]
    fn a_role_covers_every_app_that_has_one() {
        assert_eq!(go(&["fe"]).components, ["fe-admin"], "fe-sales is disabled");
        assert_eq!(go(&["worker"]).components, ["worker-sales"]);
        assert_eq!(go(&["backends"]).components, ["be-sales"]);
    }

    /// Docker deps are not components. The word still has to survive, or
    /// `pitcrew stop deps` is a no-op that exits 0.
    #[test]
    fn deps_carries_no_components_but_is_not_nothing() {
        let r = go(&["deps"]);
        assert!(r.components.is_empty());
        assert!(r.deps, "the word must reach the caller");
        // And it composes with everything else.
        let both = go(&["deps", "admin"]);
        assert!(both.deps);
        assert_eq!(both.components, ["fe-admin"]);
    }

    /// Overlapping words are normal — `pitcrew start all sales` — and acting
    /// on a component twice is at best wasted work and at worst a double start.
    #[test]
    fn overlapping_targets_are_deduped_keeping_first_order() {
        assert_eq!(
            go(&["be-sales", "all"]).components,
            ["be-sales", "worker-sales", "fe-admin"]
        );
        assert_eq!(
            go(&["sales", "sales"]).components,
            ["be-sales", "worker-sales"]
        );
    }

    /// An unknown word lists what WOULD have worked. "unknown target 'sale'"
    /// on its own leaves the reader to go and find the config.
    #[test]
    fn an_unknown_target_names_the_alternatives() {
        let e = resolve(&project(), &["sale".to_string()]).expect_err("unknown");
        assert_eq!(e.word, "sale");
        let msg = e.to_string();
        assert!(msg.contains("apps: sales admin"), "{msg}");
        assert!(msg.contains("roles: be fe worker"), "{msg}");
    }

    #[test]
    fn no_words_resolve_to_nothing_rather_than_everything() {
        assert_eq!(go(&[]), Resolved::default());
    }

    /// An app and a role sharing a name: the app wins, which is why `validate`
    /// warns about it — the role silently becomes unreachable.
    #[test]
    fn an_app_beats_a_role_on_a_name_clash() {
        let mut p = project();
        p.apps.push(App {
            name: "worker".into(),
            enabled: true,
            components: vec![Component {
                name: "be-worker".into(),
                app: "worker".into(),
                role: "be".into(),
                enabled: true,
                ..Default::default()
            }],
            ..Default::default()
        });
        let got = resolve(&p, &["worker".to_string()]).unwrap();
        assert_eq!(got.components, ["be-worker"], "the app, not worker-sales");
    }
}
