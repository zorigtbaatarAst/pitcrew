//! The loader, against the real fixture the bash suite uses.
//!
//! `test/fixture-yaml/` deliberately covers the awkward shapes — an app with
//! both roles, one backend-only, one frontend-only, health on one backend only,
//! a folded block scalar, a `dir:` that has to be folded into the command, and
//! watch lists in both block and flow style. The expected values here were read
//! off `./bin/pitcrew -C test/fixture-yaml config --json`, so this is a
//! cross-implementation check and not a restatement of what the Rust does.

use std::path::{Path, PathBuf};

use pitcrew_core::load;

fn fixture_root() -> PathBuf {
    // CARGO_MANIFEST_DIR is crates/pitcrew-core.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../test/fixture-yaml")
        .canonicalize()
        .expect("the bash fixture is still where it was")
}

fn load_fixture() -> load::Loaded {
    let root = fixture_root();
    load::load_yaml(&root.join("pitcrew.yaml"), &root).expect("the fixture loads")
}

/// Document order is the dashboard's order. A loader that sorted would silently
/// reshuffle every project.
#[test]
fn apps_keep_the_order_they_are_written_in() {
    let p = load_fixture().project;
    let names: Vec<&str> = p.apps.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(names, ["both", "beonly", "feonly"]);
}

/// A role exists for an app if and only if it has a start command. `beonly` has
/// no frontend at all — that slot is absent, not disabled, and must never be
/// counted as down.
#[test]
fn a_role_exists_only_when_it_has_a_command() {
    let p = load_fixture().project;
    let names: Vec<&str> = p.components().map(|c| c.name.as_str()).collect();
    assert_eq!(names, ["be-both", "fe-both", "be-beonly", "fe-feonly"]);
    assert!(
        p.component("fe-beonly").is_none(),
        "an absent role is absent"
    );
    assert!(p.component("be-feonly").is_none());
}

#[test]
fn ports_health_and_url_path_land_where_the_model_wants_them() {
    let p = load_fixture().project;
    assert_eq!(p.component("be-both").unwrap().port, Some(19801));
    assert_eq!(p.component("fe-both").unwrap().port, Some(19802));
    assert_eq!(p.component("be-both").unwrap().health, "/health");
    // Health on one backend only: the others must not inherit it, or every
    // component would sit on "starting" waiting for an endpoint nobody serves.
    assert_eq!(p.component("fe-both").unwrap().health, "");
    assert_eq!(p.component("be-beonly").unwrap().health, "");
    assert_eq!(p.app("both").unwrap().url_path, "/api");
    assert_eq!(p.app("beonly").unwrap().url_path, "");
}

/// `dir:` is the boilerplate every hand-written config repeats. It becomes a
/// correctly-quoted `cd` in front of the command, and the command the file
/// says stays separately readable — an editor showing the resolved one back
/// would be showing you something you never wrote.
#[test]
fn dir_becomes_a_quoted_cd_in_front_of_the_command() {
    let p = load_fixture().project;
    let c = p.component("be-beonly").unwrap();
    let expected = format!(
        "cd '{}' && true",
        fixture_root().join("services/beonly").display()
    );
    assert_eq!(c.run_cmd, expected);
    assert_eq!(c.src_cmd, "true", "what the file says is kept intact");
    assert_eq!(c.src_dir, "services/beonly");
}

/// A command with no dir and no root runs from wherever pitcrew was invoked.
/// Folding a `cd` in anyway would move every such command.
#[test]
fn a_component_with_no_dir_gets_no_cd() {
    let p = load_fixture().project;
    assert_eq!(p.component("be-both").unwrap().run_cmd, "true");
}

/// `>-` folds newlines into spaces, so a command written over several lines for
/// readability is still one command.
#[test]
fn a_folded_block_scalar_becomes_one_line() {
    let p = load_fixture().project;
    assert_eq!(p.component("fe-feonly").unwrap().src_cmd, "true --folded");
}

#[test]
fn watch_lists_work_in_both_styles_and_resolve_against_the_root() {
    let p = load_fixture().project;
    let root = fixture_root();
    assert_eq!(p.component("be-both").unwrap().src_watch, ["src/be"]);
    assert_eq!(
        p.component("fe-both").unwrap().src_watch,
        ["src/fe", "src/shared"]
    );
    assert_eq!(
        p.component("fe-both").unwrap().watch,
        [root.join("src/fe"), root.join("src/shared")]
    );
}

/// A component with a dir and no watch dir watches the directory it runs in —
/// otherwise `pitcrew stale` has nothing to compare against and silently never
/// reports anything.
#[test]
fn a_component_with_a_dir_and_no_watch_watches_where_it_runs() {
    let p = load_fixture().project;
    assert_eq!(
        p.component("be-beonly").unwrap().watch,
        [fixture_root().join("services/beonly")]
    );
}

#[test]
fn role_defaults_are_read_per_role() {
    let p = load_fixture().project;
    assert_eq!(p.role("be").unwrap().env, "FIX_BE=1");
    assert_eq!(p.role("be").unwrap().max, "2G");
    assert_eq!(p.role("fe").unwrap().env, "");
    assert_eq!(p.role("fe").unwrap().max, "4G");
}

#[test]
fn deps_shells_doctor_and_dashboard_are_read() {
    let p = load_fixture().project;
    assert_eq!(p.deps, ["fixture-db", "fixture-cache"]);
    assert_eq!(p.protected_deps, ["fixture-db"]);
    assert_eq!(p.shells, [("db".to_string(), "echo db".to_string())]);
    assert_eq!(
        p.doctor,
        [("bash is present".to_string(), "command -v bash".to_string())]
    );
    assert!(p.dashboard.contains(&("theme".into(), "mono".into())));
    assert!(p
        .dashboard
        .contains(&("error_pattern".into(), "BOOM|KABOOM".into())));
}

/// The fixture is a config that is meant to be clean. A warning here means
/// either the loader invented one or the fixture drifted — both worth knowing.
#[test]
fn the_fixture_loads_without_complaint() {
    let warnings = load_fixture().warnings;
    assert!(warnings.is_empty(), "unexpected warnings: {warnings:#?}");
}

/// The shipped example is the schema, annotated. If the loader cannot read it
/// without complaint, the documentation and the implementation disagree — and
/// the documentation is what people copy from.
#[test]
fn the_shipped_example_config_loads_without_complaint() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../examples")
        .canonicalize()
        .unwrap();
    let loaded = load::load_yaml(&dir.join("pitcrew.yaml"), &dir).expect("the example loads");
    assert!(
        loaded.warnings.is_empty(),
        "the annotated example warns: {:#?}",
        loaded.warnings
    );
}

/// A registry entry that points at a repo's config is the whole reason
/// `include:` exists — you often cannot add a file to a repo you do not own.
#[test]
fn an_include_pulls_in_another_config_and_the_includer_overrides_it() {
    let d = std::env::temp_dir().join(format!("pitcrew-incl-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    std::fs::write(
        d.join("base.yaml"),
        "name: base\napps:\n  a:\n    be:\n      cmd: \"true\"\n      port: 1\n",
    )
    .unwrap();
    std::fs::write(
        d.join("pitcrew.yaml"),
        "include: base.yaml\nname: override\n",
    )
    .unwrap();

    let loaded = load::load_yaml(&d.join("pitcrew.yaml"), &d).expect("loads");
    let p = &loaded.project;
    assert_eq!(
        p.component("be-a").unwrap().port,
        Some(1),
        "from the include"
    );
    assert_eq!(p.name, "override", "the includer wins");
    // Overriding an included value is what including is FOR: warning about it
    // would make every registry entry noisy.
    assert!(
        !loaded.warnings.iter().any(|w| w.contains("set twice")),
        "{:#?}",
        loaded.warnings
    );
}

/// Anywhere but first and whether a key overrides the include or is overridden
/// BY it depends on line order, which is not a thing anyone should reason about.
#[test]
fn an_include_that_is_not_the_first_key_is_reported_and_ignored() {
    let d = std::env::temp_dir().join(format!("pitcrew-incl2-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    std::fs::write(d.join("base.yaml"), "name: base\n").unwrap();
    std::fs::write(d.join("pitcrew.yaml"), "name: mine\ninclude: base.yaml\n").unwrap();

    let loaded = load::load_yaml(&d.join("pitcrew.yaml"), &d).expect("loads");
    assert!(loaded
        .warnings
        .iter()
        .any(|w| w.contains("include must be the first key")));
    assert_eq!(loaded.project.name, "mine");
}

/// A missing include is a warning, not a refusal: the rest of the config is
/// still a config, and naming the missing file is more use than loading nothing.
#[test]
fn a_missing_include_is_reported_rather_than_fatal() {
    let d = std::env::temp_dir().join(format!("pitcrew-incl3-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    std::fs::write(
        d.join("pitcrew.yaml"),
        "include: nope.yaml\nname: mine\napps:\n  a:\n    be:\n      cmd: \"true\"\n",
    )
    .unwrap();

    let loaded = load::load_yaml(&d.join("pitcrew.yaml"), &d).expect("still loads");
    assert!(loaded
        .warnings
        .iter()
        .any(|w| w.contains("could not be read")));
    assert_eq!(loaded.project.name, "mine");
    assert!(loaded.project.component("be-a").is_some());
}

/// A cycle must be a bounded warning, not a hang.
#[test]
fn an_include_cycle_stops_at_the_depth_limit() {
    let d = std::env::temp_dir().join(format!("pitcrew-incl4-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    std::fs::write(d.join("a.yaml"), "include: b.yaml\nname: a\n").unwrap();
    std::fs::write(d.join("b.yaml"), "include: a.yaml\nname: b\n").unwrap();

    let loaded = load::load_yaml(&d.join("a.yaml"), &d).expect("loads");
    assert!(loaded
        .warnings
        .iter()
        .any(|w| w.contains("nested more than")));
}
