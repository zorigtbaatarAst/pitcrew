//! What is wrong with a config that nonetheless loads.
//!
//! Separate from [`crate::load`] on purpose. The loader reports what it could
//! not understand; this reports what it understood perfectly well and which is
//! still probably not what anyone meant. Both only ever warn — *warn, never
//! die, on anything merely unusual* — because a config that is 90% right should
//! start the 90%, not refuse the lot.

use crate::model::Project;

/// Target words that are not component names. A role sharing one of these
/// becomes unreachable, which is the part worth saying.
const TARGET_KEYWORDS: &[&str] = &["all", "deps", "backends", "frontends"];

pub fn validate(p: &Project) -> Vec<String> {
    let mut out = Vec::new();

    if p.apps.is_empty() {
        out.push("no apps: — nothing would ever start".into());
    }

    // A role exists only when it has a command, so an app with no components is
    // an app that can never do anything.
    for app in &p.apps {
        if app.components.is_empty() {
            out.push(format!(
                "app '{}' has no component with a cmd: — nothing will ever start for it",
                app.name
            ));
        }
    }

    // A role and an app that share a name make `pitcrew start worker` mean two
    // things. Targets resolve the app first, so the role becomes unreachable —
    // silently, which is the part worth a warning.
    for role in p.role_names() {
        if p.app(&role).is_some() {
            out.push(format!(
                "'{role}' is both a role and an app name — 'pitcrew start {role}' will mean the app"
            ));
        }
        if TARGET_KEYWORDS.contains(&role.as_str()) {
            out.push(format!(
                "role '{role}' is also a target keyword — name it something else"
            ));
        }
    }
    for app in &p.apps {
        if TARGET_KEYWORDS.contains(&app.name.as_str()) {
            out.push(format!(
                "app '{}' is also a target keyword — name it something else",
                app.name
            ));
        }
    }

    // Two components on one port is a stack where one of them will always fail
    // to bind, and the other will be reported as up on its neighbour's behalf.
    let mut owner: Vec<(u16, &str)> = Vec::new();
    for c in p.components() {
        let Some(port) = c.port else { continue };
        match owner.iter().find(|(p, _)| *p == port) {
            Some((_, first)) => out.push(format!(
                "port {port} is used by both {first} and {}",
                c.name
            )),
            None => owner.push((port, &c.name)),
        }
    }

    for dep in &p.protected_deps {
        if !p.deps.contains(dep) {
            out.push(format!(
                "protected_deps has '{dep}' which isn't in deps — it protects nothing"
            ));
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{App, Component, Project};

    fn project(apps: Vec<App>) -> Project {
        Project {
            apps,
            ..Default::default()
        }
    }

    fn app(name: &str, comps: Vec<Component>) -> App {
        App {
            name: name.into(),
            enabled: true,
            components: comps,
            ..Default::default()
        }
    }

    fn comp(app: &str, role: &str, port: Option<u16>) -> Component {
        Component {
            name: format!("{role}-{app}"),
            app: app.into(),
            role: role.into(),
            port,
            enabled: true,
            ..Default::default()
        }
    }

    #[test]
    fn an_empty_config_says_nothing_would_start() {
        assert!(validate(&project(vec![]))
            .join("\n")
            .contains("nothing would ever start"));
    }

    #[test]
    fn an_app_with_no_components_is_reported() {
        let w = validate(&project(vec![app("ghost", vec![])])).join("\n");
        assert!(w.contains("app 'ghost' has no component"), "{w}");
    }

    /// One of them will always fail to bind, and the other gets reported as up
    /// on its neighbour's behalf.
    #[test]
    fn two_components_on_one_port_are_reported() {
        let p = project(vec![app(
            "a",
            vec![comp("a", "be", Some(8080)), comp("a", "fe", Some(8080))],
        )]);
        let w = validate(&p).join("\n");
        assert!(w.contains("port 8080 is used by both be-a and fe-a"), "{w}");
    }

    #[test]
    fn distinct_ports_are_fine() {
        let p = project(vec![app(
            "a",
            vec![comp("a", "be", Some(1)), comp("a", "fe", Some(2))],
        )]);
        assert!(validate(&p).is_empty());
    }

    /// Targets resolve the app first, so the role becomes silently unreachable.
    #[test]
    fn a_role_that_shares_a_name_with_an_app_is_reported() {
        let p = project(vec![
            app("worker", vec![comp("worker", "be", None)]),
            app("api", vec![comp("api", "worker", None)]),
        ]);
        let w = validate(&p).join("\n");
        assert!(w.contains("both a role and an app name"), "{w}");
    }

    #[test]
    fn a_name_that_collides_with_a_target_keyword_is_reported() {
        let p = project(vec![app("all", vec![comp("all", "be", None)])]);
        let w = validate(&p).join("\n");
        assert!(w.contains("app 'all' is also a target keyword"), "{w}");

        let p = project(vec![app("x", vec![comp("x", "deps", None)])]);
        assert!(validate(&p)
            .join("\n")
            .contains("role 'deps' is also a target keyword"));
    }

    /// Protecting a container that is not a dependency protects nothing, and
    /// reads as though it does.
    #[test]
    fn a_protected_dep_that_is_not_a_dep_is_reported() {
        let p = Project {
            deps: vec!["postgres".into()],
            protected_deps: vec!["redis".into()],
            apps: vec![app("a", vec![comp("a", "be", None)])],
            ..Default::default()
        };
        assert!(validate(&p)
            .join("\n")
            .contains("'redis' which isn't in deps"));
    }
}
