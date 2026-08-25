//! Diagnostics: is this **stack** healthy right now?
//!
//! Not to be confused with `doctor`, which asks whether this **environment**
//! can run pitcrew at all. Doctor is static and about the machine; this is
//! derived from a live snapshot and about the services.
//!
//! Four surfaces read the result and nothing else — the dashboard's verdict
//! line, `pitcrew diagnose`, the `health` object in the JSON stream, and the
//! desktop app's overview. A check added here appears in all four without
//! touching any of them.
//!
//! Two rules the checks hold to, and they are the reason this is worth reading
//! before adding one:
//!
//! **Never claim more than was measured.** A finding prints its evidence
//! (`quiet 41m · up 3h20m`) rather than rounding it into an assertion. The idle
//! check in particular is a suggestion with the evidence attached, not an offer
//! to kill things — pitcrew proposes, the person decides.
//!
//! **Protected components are excluded from proposals but still listed.** A
//! list of candidates that quietly omits the one you expected to see reads as a
//! bug in the tool.

use pitcrew_model::{Finding, Severity, State, Verdict};

use crate::format::{human_bytes, human_duration};
use crate::model::Project;
use crate::snapshot::Snapshot;

/// Thresholds, all overridable through the environment exactly as in the shell
/// implementation, so a project that tuned them keeps its tuning.
pub struct Thresholds {
    /// Machine RAM in use before memory pressure is worth saying.
    pub mem_warn_pct: u64,
    pub mem_crit_pct: u64,
    /// A component against its own cap.
    pub cap_near_pct: u64,
    /// Seconds up before "idle" is worth saying. A service started ten seconds
    /// ago is not a candidate for stopping however quiet it is.
    pub idle_min: i64,
    /// × the project's `wait` before a boot counts as stuck.
    pub slow_start_mult: i64,
}

impl Default for Thresholds {
    fn default() -> Self {
        Thresholds {
            mem_warn_pct: env_num("PITCREW_MEM_WARN_PCT", 85),
            mem_crit_pct: env_num("PITCREW_MEM_CRIT_PCT", 93),
            cap_near_pct: env_num("PITCREW_CAP_NEAR_PCT", 90),
            idle_min: env_num("PITCREW_IDLE_MIN", 600) as i64,
            slow_start_mult: env_num("PITCREW_SLOW_START_MULT", 1) as i64,
        }
    }
}

fn env_num(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// The verdict, the headline, and everything that produced them.
pub struct Health {
    pub verdict: Verdict,
    pub headline: String,
    /// Whether the expensive checks ran.
    pub deep: bool,
    pub findings: Vec<Finding>,
    pub recoverable: Recoverable,
}

#[derive(Default)]
pub struct Recoverable {
    pub components: Vec<String>,
    pub protected: Vec<String>,
    pub bytes: u64,
}

/// Everything the checks need that is not in the snapshot.
pub struct Context<'a> {
    pub project: &'a Project,
    pub snapshot: &'a Snapshot,
    /// Resolved caps in bytes, keyed by component.
    pub caps: &'a std::collections::HashMap<String, u64>,
    /// Error counts from the radar, keyed by component.
    pub errors: &'a std::collections::HashMap<String, u64>,
    /// Which dependencies are running. Absent means not checked.
    pub deps_up: &'a std::collections::HashMap<String, bool>,
    /// Idle seconds per component, where a CPU baseline exists.
    pub idle: &'a std::collections::HashMap<String, i64>,
    pub thresholds: Thresholds,
    /// Run the expensive checks too.
    pub deep: bool,
}

pub fn run(ctx: &Context<'_>) -> Health {
    let mut f = Vec::new();
    check_crashed(ctx, &mut f);
    check_stuck(ctx, &mut f);
    check_external(ctx, &mut f);
    check_memory(ctx, &mut f);
    check_caps(ctx, &mut f);
    check_deps(ctx, &mut f);
    check_errors(ctx, &mut f);
    let recoverable = check_idle(ctx, &mut f);

    // Worst severity present. The headline is the FIRST finding at that
    // severity: when a stack is on fire, the thing you need on the one line you
    // will actually read is the worst thing, not the most recent.
    let verdict = f
        .iter()
        .map(|x| x.severity)
        .max()
        .map(|s| match s {
            Severity::Crit => Verdict::Crit,
            Severity::Warn => Verdict::Warn,
            Severity::Info => Verdict::Info,
        })
        .unwrap_or(Verdict::Ok);
    let headline = f
        .iter()
        .find(|x| match verdict {
            Verdict::Crit => x.severity == Severity::Crit,
            Verdict::Warn => x.severity == Severity::Warn,
            Verdict::Info => x.severity == Severity::Info,
            Verdict::Ok => false,
        })
        .map(|x| x.title.clone())
        .unwrap_or_default();

    Health {
        verdict,
        headline,
        deep: ctx.deep,
        findings: f,
        recoverable,
    }
}

fn add(
    out: &mut Vec<Finding>,
    severity: Severity,
    id: &str,
    title: String,
    detail: String,
    fix: &str,
    scope: &str,
) {
    out.push(Finding {
        severity,
        id: id.into(),
        title,
        detail,
        fix: fix.into(),
        scope: scope.into(),
    });
}

fn check_crashed(ctx: &Context<'_>, out: &mut Vec<Finding>) {
    for c in ctx
        .snapshot
        .components
        .iter()
        .filter(|c| c.state == State::Crashed)
    {
        // "crashed" on its own tells you nothing actionable.
        let detail = match c.exit {
            Some(e) if e.at > 0 => format!(
                "exited {}, {} ago",
                e.code,
                human_duration(ctx.snapshot.at - e.at)
            ),
            Some(e) => format!("exited {}", e.code),
            None => "the process is gone and left no exit status".into(),
        };
        add(
            out,
            Severity::Crit,
            "crashed",
            format!("{} crashed", c.name),
            detail,
            &format!("pitcrew logs {}", c.name),
            &c.name,
        );
    }
}

/// A service "starting" for longer than the boot timeout is not booting, it is
/// stuck — and an amber dot looks identical at ten seconds and at ten minutes.
fn check_stuck(ctx: &Context<'_>, out: &mut Vec<Finding>) {
    let limit = ctx.project.wait_secs as i64 * ctx.thresholds.slow_start_mult;
    for c in ctx
        .snapshot
        .components
        .iter()
        .filter(|c| c.state == State::Starting)
    {
        let Some(since) = c.since else { continue };
        let age = ctx.snapshot.at - since;
        if age <= limit {
            continue;
        }
        let configured = ctx
            .project
            .component(&c.name)
            .is_some_and(|comp| !comp.health.is_empty());
        let detail = if configured {
            "its health endpoint has not reported UP yet".to_string()
        } else {
            "the process is alive but nothing is listening on its port".to_string()
        };
        add(
            out,
            Severity::Warn,
            "stuck",
            format!("{} has been starting for {}", c.name, human_duration(age)),
            detail,
            &format!("pitcrew logs {}", c.name),
            &c.name,
        );
    }
}

/// The failure that looks most like success: the port answers, so a casual
/// glance says "up".
fn check_external(ctx: &Context<'_>, out: &mut Vec<Finding>) {
    for c in ctx
        .snapshot
        .components
        .iter()
        .filter(|c| c.state == State::External)
    {
        let port = ctx
            .project
            .component(&c.name)
            .and_then(|x| x.port)
            .map(|p| p.to_string())
            .unwrap_or_default();
        add(
            out,
            Severity::Warn,
            "external",
            format!("port {port} is not being served by pitcrew"),
            format!(
                "{} is configured for it, but the listener is a process pitcrew did not start",
                c.name
            ),
            "pitcrew ports",
            &c.name,
        );
    }
}

/// The number on its own is the least useful half: what matters is who is
/// holding the memory and whether the machine has started swapping to cope.
fn check_memory(ctx: &Context<'_>, out: &mut Vec<Finding>) {
    let m = &ctx.snapshot.machine;
    if m.mem_total == 0 {
        return;
    }
    let pct = m.mem_used * 100 / m.mem_total;
    // 64MB of swap is noise on most machines; beyond it something is paging.
    let swapping = m.swap_used > 64 * 1024 * 1024;
    if pct < ctx.thresholds.mem_warn_pct && !swapping {
        return;
    }

    // Name the three biggest things THIS project is holding. Not "some
    // process": the whole point is that the reader can act on it.
    let mut by_rss: Vec<(&str, u64)> = ctx
        .snapshot
        .components
        .iter()
        .filter_map(|c| c.rss.map(|r| (c.name.as_str(), r)))
        .collect();
    by_rss.sort_by_key(|(_, rss)| std::cmp::Reverse(*rss));
    let share: u64 = by_rss.iter().map(|(_, r)| r).sum();
    let names: Vec<String> = by_rss
        .iter()
        .take(3)
        .map(|(n, r)| format!("{n} {}", human_bytes(*r)))
        .collect();

    let (severity, title) = if swapping {
        (
            Severity::Crit,
            format!(
                "memory pressure — {} of swap in use",
                human_bytes(m.swap_used)
            ),
        )
    } else {
        (
            if pct >= ctx.thresholds.mem_crit_pct {
                Severity::Crit
            } else {
                Severity::Warn
            },
            format!(
                "memory pressure — {} of {} in use ({pct}%)",
                human_bytes(m.mem_used),
                human_bytes(m.mem_total)
            ),
        )
    };
    let detail = if names.is_empty() {
        format!(
            "this project is holding {}, so the pressure is coming from elsewhere",
            human_bytes(share)
        )
    } else {
        format!(
            "this project holds {} of it — largest: {}",
            human_bytes(share),
            names.join(", ")
        )
    };
    add(
        out,
        severity,
        "memory",
        title,
        detail,
        "pitcrew diagnose",
        "",
    );
}

/// A cap that cannot bite is worse than no cap: the OOM killer picks the victim
/// instead, and it does not pick the one you would have.
fn check_caps(ctx: &Context<'_>, out: &mut Vec<Finding>) {
    let total = ctx.snapshot.machine.mem_total;
    let committed: u64 = ctx
        .project
        .components()
        .filter_map(|c| ctx.caps.get(&c.name))
        .sum();
    if total > 0 && committed > total {
        add(
            out,
            Severity::Warn,
            "caps-overcommit",
            format!(
                "RAM caps commit {} on a {} machine",
                human_bytes(committed),
                human_bytes(total)
            ),
            "if everything runs at its cap the kernel runs out before any cap applies".into(),
            "pitcrew limit",
            "",
        );
    }

    for c in ctx
        .snapshot
        .components
        .iter()
        .filter(|c| c.state == State::Up)
    {
        let (Some(rss), Some(&cap)) = (c.rss, ctx.caps.get(&c.name)) else {
            continue;
        };
        if cap == 0 || rss == 0 {
            continue;
        }
        let pct = rss * 100 / cap;
        if pct < ctx.thresholds.cap_near_pct {
            continue;
        }
        add(
            out,
            Severity::Warn,
            "cap-near",
            format!("{} is at {pct}% of its RAM cap", c.name),
            format!(
                "{} of {} — at the cap it is killed, not throttled",
                human_bytes(rss),
                human_bytes(cap)
            ),
            &format!("pitcrew limit {}", c.name),
            &c.name,
        );
    }
}

/// Everything downstream of a missing dependency fails in a way that looks like
/// the service's own fault.
fn check_deps(ctx: &Context<'_>, out: &mut Vec<Finding>) {
    for dep in &ctx.project.deps {
        if ctx.deps_up.get(dep).copied().unwrap_or(false) {
            continue;
        }
        add(
            out,
            Severity::Warn,
            "dep-down",
            format!("dependency {dep} is not running"),
            "services that need it will fail in ways that look like their own bug".into(),
            "pitcrew start deps",
            dep,
        );
    }
}

/// A service that is up and quietly logging exceptions is exactly the thing
/// nobody notices.
fn check_errors(ctx: &Context<'_>, out: &mut Vec<Finding>) {
    for c in ctx
        .snapshot
        .components
        .iter()
        .filter(|c| c.state == State::Up)
    {
        let n = ctx.errors.get(&c.name).copied().unwrap_or(0);
        if n == 0 {
            continue;
        }
        add(
            out,
            Severity::Info,
            "log-errors",
            format!("{} has {n} error lines in its log", c.name),
            "it is up and serving, so nothing else is going to tell you".into(),
            &format!("pitcrew logs {}", c.name),
            &c.name,
        );
    }
}

/// What could be given back, and at what cost.
///
/// Two conditions, and both are things pitcrew actually measured: **quiet** —
/// its process tree has stayed under the idle threshold for every sample since
/// this process started watching; and **old** — it has been up long enough to
/// have been forgotten. Neither is proof that nothing needs it, which is
/// exactly why this is an observation with a command attached rather than an
/// action.
fn check_idle(ctx: &Context<'_>, out: &mut Vec<Finding>) -> Recoverable {
    let mut r = Recoverable::default();
    let mut why: Vec<String> = Vec::new();

    for c in ctx
        .snapshot
        .components
        .iter()
        .filter(|c| c.state == State::Up)
    {
        // No CPU baseline yet — say nothing rather than guess.
        let (Some(&idle), Some(since), Some(rss)) = (ctx.idle.get(&c.name), c.since, c.rss) else {
            continue;
        };
        let up = ctx.snapshot.at - since;
        if up < ctx.thresholds.idle_min || rss == 0 {
            continue;
        }
        // Excluded here rather than filtered later, so a protected component
        // can never appear in a command a UI is about to run — but it is still
        // reported, because a list that quietly omits the one you expected
        // reads as a bug in the tool.
        if ctx
            .project
            .component(&c.name)
            .is_some_and(|comp| comp.protected)
        {
            r.protected.push(c.name.clone());
            continue;
        }
        r.components.push(c.name.clone());
        r.bytes += rss;
        why.push(format!(
            "quiet {} · up {}",
            human_duration(idle),
            human_duration(up)
        ));
    }

    if r.components.is_empty() {
        return r;
    }
    // Only worth raising when memory is actually tight. Otherwise a quiet
    // service is one you are not using this minute, which is fine and not news.
    let m = &ctx.snapshot.machine;
    let pct = (m.mem_used * 100).checked_div(m.mem_total).unwrap_or(0);
    if pct < ctx.thresholds.mem_warn_pct && m.swap_used <= 64 * 1024 * 1024 {
        return r;
    }

    let noun = if r.components.len() == 1 {
        "idle service is"
    } else {
        "idle services are"
    };
    add(
        out,
        Severity::Info,
        "recoverable",
        format!(
            "{} {noun} holding {}",
            r.components.len(),
            human_bytes(r.bytes)
        ),
        "no CPU since pitcrew started watching, and up long enough to be forgotten".into(),
        &format!("pitcrew stop {}", r.components.join(" ")),
        "",
    );
    r
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::logdir::Exit;
    use crate::model::{App, Component};
    use crate::snapshot::CompSnapshot;
    use std::collections::HashMap;

    fn comp(name: &str, state: State) -> CompSnapshot {
        CompSnapshot {
            name: name.into(),
            state,
            pid: Some(1),
            rss: Some(1024 * 1024 * 1024),
            cpu: Some(0.0),
            since: Some(1000),
            exit: None,
            processes: Vec::new(),
        }
    }

    fn project(components: Vec<Component>) -> Project {
        Project {
            wait_secs: 120,
            apps: vec![App {
                name: "app".into(),
                enabled: true,
                components,
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    fn model_comp(name: &str, protected: bool, health: &str) -> Component {
        Component {
            name: name.into(),
            app: "app".into(),
            role: "be".into(),
            port: Some(8080),
            health: health.into(),
            protected,
            enabled: true,
            ..Default::default()
        }
    }

    struct Fixture {
        project: Project,
        snapshot: Snapshot,
        caps: HashMap<String, u64>,
        errors: HashMap<String, u64>,
        deps_up: HashMap<String, bool>,
        idle: HashMap<String, i64>,
    }

    impl Fixture {
        fn new(components: Vec<CompSnapshot>, model: Vec<Component>) -> Fixture {
            Fixture {
                project: project(model),
                snapshot: Snapshot {
                    at: 100_000,
                    components,
                    machine: pitcrew_platform::Machine {
                        mem_total: 32 * 1024 * 1024 * 1024,
                        mem_used: 8 * 1024 * 1024 * 1024,
                        swap_total: 0,
                        swap_used: 0,
                        cpu_percent: 5,
                    },
                },
                caps: HashMap::new(),
                errors: HashMap::new(),
                deps_up: HashMap::new(),
                idle: HashMap::new(),
            }
        }
        fn health(&self) -> Health {
            run(&Context {
                project: &self.project,
                snapshot: &self.snapshot,
                caps: &self.caps,
                errors: &self.errors,
                deps_up: &self.deps_up,
                idle: &self.idle,
                thresholds: Thresholds::default(),
                deep: false,
            })
        }
    }

    fn ids(h: &Health) -> Vec<&str> {
        h.findings.iter().map(|f| f.id.as_str()).collect()
    }

    #[test]
    fn a_healthy_stack_says_nothing_and_is_ok() {
        let f = Fixture::new(
            vec![comp("be-a", State::Up)],
            vec![model_comp("be-a", false, "")],
        );
        let h = f.health();
        assert_eq!(h.verdict, Verdict::Ok);
        assert!(h.findings.is_empty());
        assert_eq!(h.headline, "");
    }

    /// "crashed" on its own tells you nothing actionable, so the record of HOW
    /// travels with it.
    #[test]
    fn a_crash_reports_the_exit_code_and_how_long_ago() {
        let mut c = comp("be-a", State::Crashed);
        c.exit = Some(Exit {
            code: 3,
            at: 99_940,
        });
        let f = Fixture::new(vec![c], vec![model_comp("be-a", false, "")]);
        let h = f.health();
        assert_eq!(h.verdict, Verdict::Crit);
        assert_eq!(h.findings[0].detail, "exited 3, 1m ago");
        assert_eq!(h.findings[0].fix, "pitcrew logs be-a");
    }

    #[test]
    fn a_crash_with_no_record_says_that_rather_than_inventing_one() {
        let f = Fixture::new(
            vec![comp("be-a", State::Crashed)],
            vec![model_comp("be-a", false, "")],
        );
        assert_eq!(
            f.health().findings[0].detail,
            "the process is gone and left no exit status"
        );
    }

    /// An amber dot looks identical at ten seconds and at ten minutes.
    #[test]
    fn a_boot_past_the_timeout_is_stuck_and_says_which_signal_is_missing() {
        let mut c = comp("be-a", State::Starting);
        c.since = Some(100_000 - 500); // well past wait_secs of 120
        let f = Fixture::new(vec![c.clone()], vec![model_comp("be-a", false, "/health")]);
        let h = f.health();
        assert_eq!(ids(&h), ["stuck"]);
        assert!(h.findings[0].detail.contains("health endpoint"));

        // Without a health path it is the port that has not opened.
        let f = Fixture::new(vec![c], vec![model_comp("be-a", false, "")]);
        assert!(f.health().findings[0]
            .detail
            .contains("nothing is listening"));
    }

    /// A boot still inside its timeout is booting, not stuck.
    #[test]
    fn a_recent_boot_is_not_reported() {
        let mut c = comp("be-a", State::Starting);
        c.since = Some(100_000 - 10);
        let f = Fixture::new(vec![c], vec![model_comp("be-a", false, "")]);
        assert!(f.health().findings.is_empty());
    }

    /// The failure that looks most like success: the port answers.
    #[test]
    fn an_external_listener_is_reported_with_its_port() {
        let f = Fixture::new(
            vec![comp("be-a", State::External)],
            vec![model_comp("be-a", false, "")],
        );
        let h = f.health();
        assert_eq!(ids(&h), ["external"]);
        assert!(h.findings[0].title.contains("port 8080"));
    }

    /// The number alone is the least useful half: who is holding it is what
    /// anyone can act on.
    #[test]
    fn memory_pressure_names_the_biggest_consumers() {
        let mut f = Fixture::new(
            vec![comp("be-a", State::Up), comp("fe-a", State::Up)],
            vec![model_comp("be-a", false, ""), model_comp("fe-a", false, "")],
        );
        f.snapshot.machine.mem_used = 30 * 1024 * 1024 * 1024; // 93%+
        let h = f.health();
        assert!(ids(&h).contains(&"memory"));
        let m = h.findings.iter().find(|x| x.id == "memory").unwrap();
        assert_eq!(m.severity, Severity::Crit, "93% is critical, not a warning");
        assert!(m.detail.contains("largest: be-a 1G"), "{}", m.detail);
    }

    /// Swap in use is worse than a high percentage: the machine has already
    /// started paging to cope.
    #[test]
    fn swapping_is_critical_whatever_the_percentage_says() {
        let mut f = Fixture::new(
            vec![comp("be-a", State::Up)],
            vec![model_comp("be-a", false, "")],
        );
        f.snapshot.machine.swap_used = 512 * 1024 * 1024;
        let h = f.health();
        let m = h.findings.iter().find(|x| x.id == "memory").unwrap();
        assert_eq!(m.severity, Severity::Crit);
        assert!(m.title.contains("swap in use"));
    }

    /// A cap that cannot bite is worse than no cap: the OOM killer picks the
    /// victim instead, and it does not pick the one you would have.
    #[test]
    fn caps_that_exceed_the_machine_are_reported() {
        let mut f = Fixture::new(
            vec![comp("be-a", State::Up)],
            vec![model_comp("be-a", false, "")],
        );
        f.caps.insert("be-a".into(), 64 * 1024 * 1024 * 1024);
        let h = f.health();
        assert!(ids(&h).contains(&"caps-overcommit"));
    }

    #[test]
    fn a_component_near_its_own_cap_is_reported() {
        let mut f = Fixture::new(
            vec![comp("be-a", State::Up)],
            vec![model_comp("be-a", false, "")],
        );
        // rss is 1G in the fixture; a 1G cap is 100%.
        f.caps.insert("be-a".into(), 1024 * 1024 * 1024);
        let h = f.health();
        let near = h.findings.iter().find(|x| x.id == "cap-near").unwrap();
        assert!(near.detail.contains("killed, not throttled"));
    }

    #[test]
    fn a_dependency_that_is_not_running_is_reported() {
        let mut f = Fixture::new(vec![], vec![]);
        f.project.deps = vec!["postgres".into(), "redis".into()];
        f.deps_up.insert("postgres".into(), true);
        let h = f.health();
        assert_eq!(ids(&h), ["dep-down"]);
        assert_eq!(h.findings[0].scope, "redis");
    }

    /// A service that is up and quietly logging exceptions is exactly the thing
    /// nobody notices — and it is info, not a warning, because errors in a log
    /// are not necessarily a problem.
    #[test]
    fn errors_in_a_running_services_log_are_information() {
        let mut f = Fixture::new(
            vec![comp("be-a", State::Up)],
            vec![model_comp("be-a", false, "")],
        );
        f.errors.insert("be-a".into(), 12);
        let h = f.health();
        assert_eq!(h.findings[0].severity, Severity::Info);
        assert_eq!(h.verdict, Verdict::Info);
        assert!(h.findings[0].title.contains("12 error lines"));
    }

    /// A crashed service's log errors are not news — the crash is.
    #[test]
    fn errors_are_only_reported_for_a_service_that_is_up() {
        let mut f = Fixture::new(
            vec![comp("be-a", State::Crashed)],
            vec![model_comp("be-a", false, "")],
        );
        f.errors.insert("be-a".into(), 12);
        assert!(!ids(&f.health()).contains(&"log-errors"));
    }

    /// The verdict is the worst severity present, and the headline is the first
    /// finding at it: when a stack is on fire, the one line you actually read
    /// should be the worst thing.
    #[test]
    fn the_headline_is_the_worst_finding_not_the_latest() {
        let mut c = comp("be-a", State::Crashed);
        c.exit = Some(Exit {
            code: 1,
            at: 99_990,
        });
        let mut f = Fixture::new(
            vec![c, comp("fe-a", State::Up)],
            vec![model_comp("be-a", false, ""), model_comp("fe-a", false, "")],
        );
        f.errors.insert("fe-a".into(), 3);
        let h = f.health();
        assert_eq!(h.verdict, Verdict::Crit);
        assert_eq!(h.headline, "be-a crashed");
    }

    /// Only worth raising when memory is tight; otherwise a quiet service is
    /// one you are not using this minute, which is fine and not news.
    #[test]
    fn idle_services_are_only_proposed_when_memory_is_tight() {
        let mut f = Fixture::new(
            vec![comp("be-a", State::Up)],
            vec![model_comp("be-a", false, "")],
        );
        f.idle.insert("be-a".into(), 3600);
        f.snapshot.components[0].since = Some(100_000 - 7200);

        assert!(
            !ids(&f.health()).contains(&"recoverable"),
            "not news at 25% memory"
        );

        f.snapshot.machine.mem_used = 30 * 1024 * 1024 * 1024;
        let h = f.health();
        let r = h.findings.iter().find(|x| x.id == "recoverable").unwrap();
        // The command is the proposal; the person decides.
        assert_eq!(r.fix, "pitcrew stop be-a");
        assert_eq!(h.recoverable.components, ["be-a"]);
    }

    /// Excluded from the command a UI is about to run, but still listed — a
    /// list that quietly omits the one you expected reads as a bug in the tool.
    #[test]
    fn a_protected_service_is_never_proposed_but_is_still_listed() {
        let mut f = Fixture::new(
            vec![comp("be-a", State::Up), comp("db-a", State::Up)],
            vec![model_comp("be-a", false, ""), model_comp("db-a", true, "")],
        );
        f.snapshot.machine.mem_used = 30 * 1024 * 1024 * 1024;
        for c in ["be-a", "db-a"] {
            f.idle.insert(c.into(), 3600);
        }
        for c in &mut f.snapshot.components {
            c.since = Some(100_000 - 7200);
        }
        let h = f.health();
        assert_eq!(
            h.recoverable.components,
            ["be-a"],
            "the protected one is not proposed"
        );
        assert_eq!(
            h.recoverable.protected,
            ["db-a"],
            "but it is still reported"
        );
        let r = h.findings.iter().find(|x| x.id == "recoverable").unwrap();
        assert!(
            !r.fix.contains("db-a"),
            "a UI must never be handed it: {}",
            r.fix
        );
    }

    /// A service started ten seconds ago is not a candidate for stopping,
    /// however quiet it is.
    #[test]
    fn a_recently_started_service_is_never_a_candidate() {
        let mut f = Fixture::new(
            vec![comp("be-a", State::Up)],
            vec![model_comp("be-a", false, "")],
        );
        f.snapshot.machine.mem_used = 30 * 1024 * 1024 * 1024;
        f.idle.insert("be-a".into(), 3600);
        f.snapshot.components[0].since = Some(100_000 - 30);
        assert!(f.health().recoverable.components.is_empty());
    }

    /// No CPU baseline yet means nothing to say — not a confident zero.
    #[test]
    fn a_component_with_no_idle_measurement_is_not_a_candidate() {
        let mut f = Fixture::new(
            vec![comp("be-a", State::Up)],
            vec![model_comp("be-a", false, "")],
        );
        f.snapshot.machine.mem_used = 30 * 1024 * 1024 * 1024;
        f.snapshot.components[0].since = Some(100_000 - 7200);
        assert!(f.health().recoverable.components.is_empty());
    }
}
