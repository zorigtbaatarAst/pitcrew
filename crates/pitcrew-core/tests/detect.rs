//! Detection, against a monorepo built for the purpose.
//!
//! The shapes here are the ones that broke it in the shell version: a Gradle
//! module that declares its plugins with `apply false`, a modern module that
//! names none of them because it uses a version catalog, a shared library that
//! must NOT become an app, and a `backend`/`frontend` pair that is two roles of
//! one app rather than two apps.

use std::fs;
use std::path::{Path, PathBuf};

use pitcrew_core::detect::{self, Kind};

fn make_executable(p: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(p).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(p, perms).unwrap();
    }
    #[cfg(not(unix))]
    let _ = p;
}

fn write(root: &Path, rel: &str, body: &str) {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, body).unwrap();
}

/// A monorepo with every shape that has caused a bug.
fn monorepo(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("pitcrew-detect-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).unwrap();

    // Executable, like a real one: `./gradlew` without the bit simply fails,
    // and detection is right to fall back to the system tool when it is
    // missing — there is a test for that below.
    write(&root, "gradlew", "#!/bin/sh\n");
    make_executable(&root.join("gradlew"));
    write(
        &root,
        "settings.gradle.kts",
        "rootProject.name = \"demo\"\n",
    );
    // The root build file DECLARES plugins for its subprojects. It is not
    // itself an app, and reading it as one was a real bug.
    write(
        &root,
        "build.gradle.kts",
        "plugins {\n  id(\"org.springframework.boot\") version \"3.2.0\" apply false\n}\n",
    );

    // sales: a classic Spring backend + a Next frontend, as two roles.
    write(
        &root,
        "sales/backend/build.gradle.kts",
        "plugins {\n  id(\"org.springframework.boot\")\n}\ndependencies {\n  implementation(\"org.springframework.boot:spring-boot-starter-web\")\n}\n",
    );
    write(
        &root,
        "sales/backend/src/main/resources/application.yml",
        "server:\n  port: 8082\nspring:\n  application:\n    name: sales\n",
    );
    write(
        &root,
        "sales/frontend/package.json",
        "{\"scripts\":{\"dev\":\"next dev -p 3002\"},\"dependencies\":{\"next\":\"14\"}}",
    );

    // reports: a MODERN Gradle module that names no plugin — the id lives in
    // the version catalog. This one was invisible before it was fixed.
    write(
        &root,
        "gradle/libs.versions.toml",
        "[plugins]\nspring-boot = { id = \"org.springframework.boot\", version = \"3.2.0\" }\n",
    );
    write(
        &root,
        "reports/build.gradle.kts",
        "plugins {\n  alias(libs.plugins.spring.boot)\n}\n",
    );

    // A shared library: a spring-boot STARTER in its dependencies and no
    // plugin. It must not become an app — one repo went from 7 to 34 that way.
    write(
        &root,
        "domain/build.gradle.kts",
        "plugins {\n  id(\"java-library\")\n}\ndependencies {\n  implementation(\"org.springframework.boot:spring-boot-starter\")\n}\n",
    );

    // A node package with no run script is a library too.
    write(
        &root,
        "uikit/package.json",
        "{\"name\":\"uikit\",\"main\":\"index.js\"}",
    );

    root
}

#[test]
fn a_backend_and_frontend_pair_is_two_roles_of_one_app() {
    let root = monorepo("roles");
    let d = detect::scan(&root);
    let sales: Vec<&detect::Found> = d.components.iter().filter(|c| c.app == "sales").collect();
    assert_eq!(sales.len(), 2, "expected two roles, got {sales:#?}");
    let mut roles: Vec<&str> = sales.iter().map(|c| c.role.as_str()).collect();
    roles.sort_unstable();
    assert_eq!(roles, ["be", "fe"]);
}

/// The distinguishing signal is the PLUGIN, not a mention of spring-boot. A
/// library has the starter in its dependencies and no boot plugin.
#[test]
fn a_shared_library_does_not_become_an_app() {
    let d = detect::scan(&monorepo("library"));
    assert!(
        !d.apps().contains(&"domain".to_string()),
        "a java-library module became an app: {:?}",
        d.apps()
    );
    assert!(
        !d.apps().contains(&"uikit".to_string()),
        "a node package with no run script became an app"
    );
}

/// `apply false` declares a plugin for the subprojects and does not apply it
/// here, so a root build file listing every plugin that way is not an app.
#[test]
fn a_root_build_file_that_only_declares_plugins_is_not_an_app() {
    let root = monorepo("rootdecl");
    let d = detect::scan(&root);
    let root_name = root.file_name().unwrap().to_string_lossy().to_string();
    assert!(!d.apps().contains(&root_name), "the root became an app");
}

/// A modern Gradle module does not name its plugins: `alias(libs.plugins.spring.boot)`
/// is the whole line. Reading only the module made this backend invisible.
#[test]
fn a_module_using_a_version_catalog_is_still_a_service() {
    let d = detect::scan(&monorepo("catalog"));
    let reports = d
        .components
        .iter()
        .find(|c| c.app == "reports")
        .expect("the catalog module should be a service");
    assert_eq!(reports.kind, Kind::Gradle);
    assert!(reports.cmd.contains(":reports:bootRun"), "{}", reports.cmd);
}

/// The port is in the config, not guessed.
#[test]
fn a_spring_port_is_read_out_of_the_application_yaml() {
    let d = detect::scan(&monorepo("port"));
    let be = d
        .components
        .iter()
        .find(|c| c.app == "sales" && c.role == "be")
        .unwrap();
    assert_eq!(be.port, Some(8082));
}

/// A dev script usually pins it: `next dev -p 3002`.
#[test]
fn a_node_port_is_read_out_of_the_dev_script() {
    let d = detect::scan(&monorepo("nodeport"));
    let fe = d
        .components
        .iter()
        .find(|c| c.app == "sales" && c.role == "fe")
        .unwrap();
    assert_eq!(fe.port, Some(3002));
    // The install guard is what makes a generated config run on a fresh clone.
    assert!(fe.cmd.contains("node_modules"), "{}", fe.cmd);
    assert!(fe.cmd.contains("npm run dev"), "{}", fe.cmd);
}

/// A backend that lost its health check lost the only thing that says it is UP
/// rather than merely running.
#[test]
fn a_spring_module_gets_an_actuator_health_path() {
    let d = detect::scan(&monorepo("health"));
    let be = d
        .components
        .iter()
        .find(|c| c.app == "sales" && c.role == "be")
        .unwrap();
    assert_eq!(be.health, "/actuator/health");
    let fe = d
        .components
        .iter()
        .find(|c| c.app == "sales" && c.role == "fe")
        .unwrap();
    assert_eq!(fe.health, "", "a frontend has no health endpoint to poll");
}

/// A gradle module is addressed by its project path, which is its directory
/// path with colons.
#[test]
fn a_gradle_module_is_started_by_its_project_path() {
    let d = detect::scan(&monorepo("cmd"));
    let be = d
        .components
        .iter()
        .find(|c| c.app == "sales" && c.role == "be")
        .unwrap();
    assert_eq!(be.cmd, "./gradlew :sales:backend:bootRun");
}

/// Two services on one port is a stack where one always fails to bind, and the
/// detector produced the collision, so the detector resolves it.
#[test]
fn detected_ports_do_not_collide() {
    let root = monorepo("collide");
    // Two Next apps both defaulting to 3000.
    write(
        &root,
        "admin/package.json",
        "{\"scripts\":{\"dev\":\"next dev\"},\"dependencies\":{\"next\":\"14\"}}",
    );
    write(
        &root,
        "portal/package.json",
        "{\"scripts\":{\"dev\":\"next dev\"},\"dependencies\":{\"next\":\"14\"}}",
    );
    let d = detect::scan(&root);
    let ports: Vec<u16> = d.components.iter().filter_map(|c| c.port).collect();
    let mut sorted = ports.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(
        sorted.len(),
        ports.len(),
        "two components share a port: {ports:?}"
    );
}

/// A repo with nothing in it is not an error, it is a repo with nothing in it.
#[test]
fn an_empty_directory_detects_nothing() {
    let d = std::env::temp_dir().join(format!("pitcrew-detect-empty-{}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    assert!(detect::scan(&d).components.is_empty());
}

/// Deterministic order: a config whose app order depends on inode order is a
/// config that reshuffles the dashboard between machines.
#[test]
fn the_scan_is_deterministic() {
    let root = monorepo("order");
    let first = detect::scan(&root).apps();
    for _ in 0..3 {
        assert_eq!(detect::scan(&root).apps(), first);
    }
}

/// A wrapper that is not executable cannot be run as `./gradlew`, so a command
/// naming it would simply fail. Falling back to the system tool is the honest
/// answer — and on Windows there is no execute bit, so there its presence IS
/// the whole question.
#[cfg(unix)]
#[test]
fn a_wrapper_without_the_execute_bit_is_not_used() {
    let root = monorepo("nonexec");
    let mut perms = fs::metadata(root.join("gradlew")).unwrap().permissions();
    use std::os::unix::fs::PermissionsExt;
    perms.set_mode(0o644);
    fs::set_permissions(root.join("gradlew"), perms).unwrap();

    let d = detect::scan(&root);
    let be = d
        .components
        .iter()
        .find(|c| c.app == "sales" && c.role == "be")
        .unwrap();
    assert_eq!(
        be.cmd, "gradle bootRun",
        "a command naming ./gradlew would fail"
    );
}

/// A role name only means a role when it is INSIDE an app directory. A
/// top-level `api/` is an app called api, not the backend of the repository —
/// and reading it the other way collapses two apps into one.
#[test]
fn a_top_level_role_name_is_an_app_not_a_role() {
    let root = monorepo("toplevel");
    write(
        &root,
        "api/build.gradle.kts",
        "plugins {\n  id(\"org.springframework.boot\")\n}\n",
    );
    write(
        &root,
        "web/package.json",
        "{\"scripts\":{\"dev\":\"next dev\"},\"dependencies\":{\"next\":\"14\"}}",
    );
    let apps = detect::scan(&root).apps();
    assert!(apps.contains(&"api".to_string()), "{apps:?}");
    assert!(apps.contains(&"web".to_string()), "{apps:?}");
}
