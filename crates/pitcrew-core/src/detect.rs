//! Looking at a repository and working out what it is.
//!
//! `pitcrew init` used to write a config full of placeholders, which meant the
//! first thing a new project did was fail. This reads the repository instead:
//! which directories are apps, what each is built with, how to start it, and
//! which port it will land on.
//!
//! **It is a guess, and it says so** — the generated config is meant to be read
//! and corrected. But a guess that runs beats a blank that does not.
//!
//! The one asymmetry worth knowing: **wrongly skipping a directory loses a
//! service with no warning; wrongly including one adds a line somebody
//! deletes.** Every judgement here leans the second way.

use std::path::{Path, PathBuf};

/// What a directory is built with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Gradle,
    Maven,
    Node,
    Go,
    Rust,
    Django,
    Python,
    Ruby,
}

/// Which JS framework, which decides both the default port and the role.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flavour {
    Plain,
    React,
    Vite,
    Nuxt,
    Angular,
    Next,
    /// A node BACKEND, which is why flavour and role are not the same question.
    Nest,
}

/// Directories that are never an app, in any project.
///
/// Keep this list UNIVERSAL — build output, dependencies, docs, conventional
/// library folders. An earlier version also skipped names lifted from one
/// particular repo (`manage`, `aws`, `cdn`, …), which silently lost real apps
/// in the next one.
const SKIP: &[&str] = &[
    "node_modules",
    "build",
    "dist",
    "out",
    "target",
    "obj",
    "vendor",
    "gradle",
    "docker",
    "docs",
    "doc",
    "logs",
    "log",
    "tmp",
    "temp",
    "scripts",
    "script",
    "assets",
    "public",
    "static",
    "coverage",
    "venv",
    "__pycache__",
    "shared",
    "common",
    "lib",
    "libs",
    "bin",
    "test",
    "tests",
    "e2e",
];

/// Subdirectory names that name a ROLE rather than an app.
fn role_of_dir(name: &str) -> Option<&'static str> {
    match name {
        "backend" | "server" | "api" | "be" => Some("be"),
        "frontend" | "web" | "client" | "ui" | "fe" => Some("fe"),
        _ => None,
    }
}

/// One component the scan found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    pub app: String,
    pub role: String,
    pub dir: PathBuf,
    pub kind: Kind,
    pub cmd: String,
    pub port: Option<u16>,
    pub health: String,
}

/// Everything the scan found, apps in the order they were met.
#[derive(Debug, Default)]
pub struct Detected {
    pub components: Vec<Found>,
}

impl Detected {
    pub fn apps(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for c in &self.components {
            if !out.contains(&c.app) {
                out.push(c.app.clone());
            }
        }
        out
    }
}

pub fn scan(root: &Path) -> Detected {
    let mut out = Detected::default();
    let mut used_ports: Vec<u16> = Vec::new();

    // The root itself may be the app — a single-service repo is the common
    // small case, and requiring a subdirectory would find nothing in it.
    if let Some(kind) = kind_of(root) {
        if runnable(root, kind) {
            push(
                root,
                root,
                name_of(root),
                None,
                kind,
                &mut out,
                &mut used_ports,
            );
        }
    }
    walk(root, root, 3, &mut out, &mut used_ports);
    out
}

fn walk(root: &Path, base: &Path, budget: u8, out: &mut Detected, ports: &mut Vec<u16>) {
    if budget == 0 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(base) else {
        return;
    };
    let mut dirs: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    // Deterministic: a config whose app order depends on inode order is a
    // config that reshuffles the dashboard between machines.
    dirs.sort();

    for dir in dirs {
        let name = name_of(&dir);
        if name.starts_with('.') || SKIP.contains(&name.as_str()) {
            continue;
        }

        // `sales/backend` and `sales/frontend` are two ROLES of one app.
        if let Some(role) = role_of_dir(&name) {
            if let Some(kind) = kind_of(&dir) {
                if runnable(&dir, kind) {
                    let app = dir
                        .parent()
                        .map(name_of)
                        .filter(|p| p != &name_of(root))
                        .unwrap_or_else(|| name_of(root));
                    push(root, &dir, app, Some(role.to_string()), kind, out, ports);
                    continue;
                }
            }
        }

        if let Some(kind) = kind_of(&dir) {
            if runnable(&dir, kind) {
                push(root, &dir, name.clone(), None, kind, out, ports);
                // A runnable module is a leaf: descending into a Spring
                // module's own src tree finds nothing but noise.
                continue;
            }
        }
        walk(root, &dir, budget - 1, out, ports);
    }
}

#[allow(clippy::too_many_arguments)]
fn push(
    root: &Path,
    dir: &Path,
    app: String,
    role: Option<String>,
    kind: Kind,
    out: &mut Detected,
    ports: &mut Vec<u16>,
) {
    let flavour = flavour_of(dir);
    let role = role.unwrap_or_else(|| role_of_kind(kind, flavour).to_string());
    if out
        .components
        .iter()
        .any(|c| c.app == app && c.role == role)
    {
        return;
    }
    let mut port = port_of(dir, kind, flavour);
    // Two services on one port is a stack where one always fails to bind. The
    // detector produced the collision, so the detector resolves it rather than
    // leaving it for `check` to report.
    if let Some(p) = port {
        let mut candidate = p;
        while ports.contains(&candidate) {
            candidate += 1;
        }
        ports.push(candidate);
        port = Some(candidate);
    }
    out.components.push(Found {
        cmd: command(root, dir, kind, port),
        health: health_of(dir, kind),
        app,
        role,
        dir: dir.to_path_buf(),
        kind,
        port,
    });
}

fn name_of(p: &Path) -> String {
    p.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

pub fn kind_of(d: &Path) -> Option<Kind> {
    let has = |f: &str| d.join(f).is_file();
    if has("build.gradle") || has("build.gradle.kts") {
        Some(Kind::Gradle)
    } else if has("pom.xml") {
        Some(Kind::Maven)
    } else if has("package.json") {
        Some(Kind::Node)
    } else if has("go.mod") {
        Some(Kind::Go)
    } else if has("Cargo.toml") {
        Some(Kind::Rust)
    } else if has("manage.py") {
        Some(Kind::Django)
    } else if has("pyproject.toml") || has("requirements.txt") {
        Some(Kind::Python)
    } else if has("Gemfile") {
        Some(Kind::Ruby)
    } else {
        None
    }
}

/// Can this module actually be STARTED, or is it a library the services depend
/// on?
///
/// Without this a Gradle monorepo reports every shared module as an app — one
/// real repo went from 7 apps to 34, nearly all of them jars.
pub fn runnable(d: &Path, kind: Kind) -> bool {
    match kind {
        Kind::Gradle => gradle_runnable(d),
        Kind::Maven => read(&d.join("pom.xml")).is_some_and(|t| {
            t.contains("spring-boot-maven-plugin") || t.contains("exec-maven-plugin")
        }),
        // A package with no way to run it is a library.
        Kind::Node => node_script(d).is_some(),
        Kind::Go => has_go_main(d),
        _ => true,
    }
}

/// The distinguishing signal is the PLUGIN, not a mention of spring-boot: a
/// library has `implementation "…spring-boot-starter-*"` in its dependencies
/// and no boot plugin.
fn gradle_runnable(d: &Path) -> bool {
    for f in ["build.gradle", "build.gradle.kts"] {
        let Some(text) = read(&d.join(f)) else {
            continue;
        };
        // `apply false` DECLARES a plugin for subprojects and does not apply it
        // here, so a root build file listing every plugin that way is not
        // itself an app.
        let applied: String = text
            .lines()
            .filter(|l| !l.contains("apply false"))
            .collect::<Vec<_>>()
            .join("\n");

        if applied.contains("org.springframework.boot\"")
            || applied.contains("org.springframework.boot'")
            || applied.contains("org.springframework.boot)")
        {
            return true;
        }
        for marker in ["id(\"application", "id 'application", "id(application"] {
            if applied.contains(marker) {
                return true;
            }
        }
        if applied.contains("apply plugin: \"application")
            || applied.contains("apply plugin: 'application")
        {
            return true;
        }
        for line in text.lines().map(str::trim) {
            if (line.starts_with("bootRun") || line.starts_with("application"))
                && line.ends_with('{')
            {
                return true;
            }
        }
        if gradle_alias_runnable(d, &applied) {
            return true;
        }
    }
    false
}

/// A modern Gradle module does not name its plugins: `alias(libs.plugins.spring.boot)`
/// is the whole line, and the id it stands for is declared in a version
/// catalog. Reading only the module made a Kotlin/Spring backend invisible.
fn gradle_alias_runnable(d: &Path, applied: &str) -> bool {
    for accessor in aliases(applied) {
        let id = catalog_dir(d)
            .and_then(|cat| plugin_id(&cat, &accessor))
            // Falls back to the alias NAME where the catalog cannot be found —
            // an alias called `spring.boot` is not a guess anybody regrets, and
            // a module wrongly skipped is a service that silently disappears.
            .unwrap_or(accessor);
        let lower = id.to_ascii_lowercase();
        if (lower.contains("spring") && lower.contains("boot"))
            || lower == "application"
            || lower.ends_with(".application")
        {
            return true;
        }
    }
    false
}

/// `alias(libs.plugins.spring.boot)` → `spring.boot`
fn aliases(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in text.lines() {
        let Some(start) = line.find("alias(") else {
            continue;
        };
        let rest = &line[start + 6..];
        let Some(end) = rest.find(')') else { continue };
        let inner = &rest[..end];
        // `<catalog>.plugins.<accessor>`
        if let Some(p) = inner.find(".plugins.") {
            out.push(inner[p + 9..].trim().to_string());
        }
    }
    out
}

/// The nearest directory at or above `d` holding a settings file or a catalog.
fn catalog_dir(d: &Path) -> Option<PathBuf> {
    let mut cur = Some(d);
    for _ in 0..4 {
        let c = cur?;
        if c.join("settings.gradle").is_file()
            || c.join("settings.gradle.kts").is_file()
            || c.join("gradle/libs.versions.toml").is_file()
        {
            return Some(c.to_path_buf());
        }
        cur = c.parent();
    }
    None
}

/// One catalog alias → the plugin id it stands for.
///
/// Gradle turns `-` and `_` in a catalog key into `.` in the accessor, so the
/// key is matched back with any of the three.
fn plugin_id(dir: &Path, accessor: &str) -> Option<String> {
    let key_matches = |k: &str| {
        k.len() == accessor.len()
            && k.chars()
                .zip(accessor.chars())
                .all(|(a, b)| a == b || (matches!(a, '-' | '_' | '.') && b == '.'))
    };

    if let Some(text) = read(&dir.join("gradle/libs.versions.toml")) {
        for line in text.lines() {
            let Some((k, v)) = line.split_once('=') else {
                continue;
            };
            if !key_matches(k.trim()) {
                continue;
            }
            if let Some(id) = quoted_after(v, "id") {
                return Some(id);
            }
        }
    }
    for f in ["settings.gradle.kts", "settings.gradle"] {
        let Some(text) = read(&dir.join(f)) else {
            continue;
        };
        for line in text.lines() {
            if !line.contains("plugin(") {
                continue;
            }
            let parts = quoted_all(line);
            if parts.len() >= 2 && key_matches(&parts[0]) {
                return Some(parts[1].clone());
            }
        }
    }
    None
}

/// The quoted value after `key =` on a TOML-ish line.
fn quoted_after(s: &str, key: &str) -> Option<String> {
    let i = s.to_ascii_lowercase().find(key)?;
    let rest = &s[i + key.len()..];
    let rest = rest.trim_start().strip_prefix('=')?;
    quoted_all(rest).into_iter().next()
}

fn quoted_all(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '"' && c != '\'' {
            continue;
        }
        let mut v = String::new();
        for n in chars.by_ref() {
            if n == c {
                break;
            }
            v.push(n);
        }
        out.push(v);
    }
    out
}

fn has_go_main(d: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(d) else {
        return false;
    };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            if !SKIP.contains(&name_of(&p).as_str()) && has_go_main(&p) {
                return true;
            }
        } else if p.extension().is_some_and(|x| x == "go")
            && read(&p).is_some_and(|t| t.lines().any(|l| l.trim() == "package main"))
        {
            return true;
        }
    }
    false
}

fn flavour_of(d: &Path) -> Flavour {
    let Some(pj) = read(&d.join("package.json")) else {
        return Flavour::Plain;
    };
    // Checked in this order because a Next app also depends on react, and a
    // Nest backend also has a build script. The most specific wins.
    for (needle, flavour) in [
        ("\"nest", Flavour::Nest),
        ("\"next\"", Flavour::Next),
        ("\"@angular/core\"", Flavour::Angular),
        ("\"nuxt\"", Flavour::Nuxt),
        ("\"vite\"", Flavour::Vite),
        ("\"react-scripts\"", Flavour::React),
    ] {
        if pj.contains(needle) {
            return flavour;
        }
    }
    Flavour::Plain
}

fn package_manager(d: &Path) -> &'static str {
    if d.join("pnpm-lock.yaml").is_file() {
        "pnpm"
    } else if d.join("yarn.lock").is_file() {
        "yarn"
    } else if d.join("bun.lockb").is_file() {
        "bun"
    } else {
        "npm"
    }
}

fn node_script(d: &Path) -> Option<String> {
    let pj = read(&d.join("package.json"))?;
    for s in ["dev", "develop", "start", "serve"] {
        if pj.contains(&format!("\"{s}\"")) {
            return Some(s.to_string());
        }
    }
    None
}

fn role_of_kind(kind: Kind, flavour: Flavour) -> &'static str {
    match (kind, flavour) {
        (
            Kind::Node,
            Flavour::Next | Flavour::React | Flavour::Vite | Flavour::Nuxt | Flavour::Angular,
        ) => "fe",
        _ => "be",
    }
}

fn port_of(d: &Path, kind: Kind, flavour: Flavour) -> Option<u16> {
    match kind {
        Kind::Gradle | Kind::Maven => spring_port(d),
        Kind::Node => {
            // A dev script usually pins it: `next dev -p 3002`.
            if let Some(p) = read(&d.join("package.json")).and_then(|t| flag_port(&t)) {
                return Some(p);
            }
            match flavour {
                Flavour::Next | Flavour::React | Flavour::Nuxt | Flavour::Nest => Some(3000),
                Flavour::Vite => Some(5173),
                Flavour::Angular => Some(4200),
                Flavour::Plain => None,
            }
        }
        Kind::Django => Some(8000),
        _ => None,
    }
}

fn spring_port(d: &Path) -> Option<u16> {
    let res = d.join("src/main/resources");
    let entries = std::fs::read_dir(&res).ok()?;
    let mut files: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
    files.sort();
    for f in files {
        let name = name_of(&f);
        let Some(text) = read(&f) else { continue };
        if name.starts_with("application") && name.ends_with(".properties") {
            for line in text.lines() {
                let line = line.trim();
                if let Some(v) = line.strip_prefix("server.port") {
                    if let Ok(p) = v.trim_start_matches([' ', '=', ':']).trim().parse() {
                        return Some(p);
                    }
                }
            }
        }
        if name.starts_with("application") && (name.ends_with(".yml") || name.ends_with(".yaml")) {
            let mut in_server = false;
            for line in text.lines() {
                if line.starts_with("server:") {
                    in_server = true;
                    continue;
                }
                if in_server {
                    if let Some(v) = line.trim().strip_prefix("port:") {
                        if let Ok(p) = v.trim().parse() {
                            return Some(p);
                        }
                    }
                    if !line.starts_with(char::is_whitespace) && !line.trim().is_empty() {
                        in_server = false;
                    }
                }
            }
        }
    }
    None
}

/// `--port 3002` or `-p 3002` in a script.
fn flag_port(text: &str) -> Option<u16> {
    let bytes: Vec<&str> = text.split_whitespace().collect();
    for (i, w) in bytes.iter().enumerate() {
        let candidate = if let Some(v) = w.strip_prefix("--port=") {
            Some(v)
        } else if let Some(v) = w.strip_prefix("-p=") {
            Some(v)
        } else if *w == "--port" || *w == "-p" {
            bytes.get(i + 1).copied()
        } else {
            None
        };
        if let Some(v) = candidate {
            let digits: String = v.chars().take_while(|c| c.is_ascii_digit()).collect();
            if digits.len() >= 2 {
                if let Ok(p) = digits.parse() {
                    return Some(p);
                }
            }
        }
    }
    None
}

/// A health path only where it is clearly Spring Boot.
///
/// `spring[-._]boot`, not `spring-boot`: through a version catalog the same
/// dependency is written `libs.bundles.spring.boot.starters`, and a backend
/// that lost its health check lost the only thing that says it is UP rather
/// than merely running.
fn health_of(d: &Path, kind: Kind) -> String {
    let files: &[&str] = match kind {
        Kind::Gradle => &["build.gradle", "build.gradle.kts"],
        Kind::Maven => &["pom.xml"],
        _ => return String::new(),
    };
    for f in files {
        let Some(text) = read(&d.join(f)) else {
            continue;
        };
        let lower = text.to_ascii_lowercase();
        for sep in ['-', '.', '_'] {
            if lower.contains(&format!("spring{sep}boot")) {
                return "/actuator/health".into();
            }
        }
    }
    String::new()
}

fn command(root: &Path, d: &Path, kind: Kind, port: Option<u16>) -> String {
    let rel = d
        .strip_prefix(root)
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_default();
    let rel = rel.trim_matches('/').to_string();

    // `pf_runnable`, not an executable-bit test: Windows has no execute bit, so
    // `[ -x gradlew ]` is false for a wrapper that runs perfectly — and every
    // Windows repo got told to use a system gradle instead of the one it ships.
    let has = |f: &str| root.join(f).is_file();

    match kind {
        Kind::Gradle => {
            // A module inside a Gradle build is addressed by its project path,
            // which is its directory path with colons: sales/backend →
            // :sales:backend
            if !rel.is_empty() && has("gradlew") {
                format!("./gradlew :{}:bootRun", rel.replace('/', ":"))
            } else if has("gradlew") {
                "./gradlew bootRun".into()
            } else {
                "gradle bootRun".into()
            }
        }
        Kind::Maven => {
            if !rel.is_empty() && has("mvnw") {
                format!("./mvnw -pl {rel} spring-boot:run")
            } else if has("mvnw") {
                "./mvnw spring-boot:run".into()
            } else {
                "mvn spring-boot:run".into()
            }
        }
        Kind::Node => {
            let pm = package_manager(d);
            let script = node_script(d).unwrap_or_else(|| "start".into());
            // The install guard is what makes a generated config run on a fresh
            // clone rather than failing on a missing node_modules.
            format!("{{ [ -d node_modules ] || {pm} install; }} && {pm} run {script}")
        }
        Kind::Go => "go run ./...".into(),
        Kind::Rust => "cargo run".into(),
        Kind::Django => format!(
            "python3 manage.py runserver 0.0.0.0:{}",
            port.unwrap_or(8000)
        ),
        Kind::Python => {
            let deps = read(&d.join("requirements.txt"))
                .unwrap_or_default()
                .to_ascii_lowercase()
                + &read(&d.join("pyproject.toml"))
                    .unwrap_or_default()
                    .to_ascii_lowercase();
            if deps.contains("fastapi") {
                format!(
                    "python3 -m uvicorn main:app --reload --port {}",
                    port.unwrap_or(8000)
                )
            } else if deps.contains("flask") {
                format!("python3 -m flask run --port {}", port.unwrap_or(8000))
            } else if d.join("main.py").is_file() {
                "python3 main.py".into()
            } else {
                "python3 app.py".into()
            }
        }
        Kind::Ruby => {
            if d.join("config.ru").is_file() {
                format!("bundle exec rails s -p {}", port.unwrap_or(3000))
            } else {
                "bundle exec ruby main.rb".into()
            }
        }
    }
}

fn read(p: &Path) -> Option<String> {
    std::fs::read_to_string(p).ok()
}
