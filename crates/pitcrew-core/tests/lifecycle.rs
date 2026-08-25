//! Starting and stopping real processes.
//!
//! The unit tests prove the state machine and the log layout in isolation. This
//! is the one that proves a component actually runs, that its pidfile means
//! what the state machine assumes, that its port opens, that stopping it takes
//! the whole tree, and that a service which dies on its own leaves a record
//! saying how.
//!
//! Unix only: the shell used here is POSIX, and the Windows spawn path is
//! covered by its own unit tests plus CI compiling it.

#![cfg(unix)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use pitcrew_core::lifecycle::{Launcher, Started};
use pitcrew_core::logdir::LogDir;
use pitcrew_core::model::{App, Component, Project};
use pitcrew_core::state::{self, Facts};
use pitcrew_platform::{caps, ports, process};

fn tmp(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("pitcrew-life-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn component(name: &str, cmd: &str, port: Option<u16>) -> Component {
    Component {
        name: name.into(),
        app: "app".into(),
        role: "be".into(),
        run_cmd: cmd.into(),
        src_cmd: cmd.into(),
        port,
        enabled: true,
        ..Default::default()
    }
}

fn launcher(root: &Path, c: &Component) -> (Launcher<'static>, LogDir) {
    let project: &'static Project = Box::leak(Box::new(Project {
        apps: vec![App {
            name: "app".into(),
            enabled: true,
            components: vec![c.clone()],
            ..Default::default()
        }],
        ..Default::default()
    }));
    let logs = LogDir::new(root);
    (
        Launcher {
            project,
            logs: logs.clone(),
            session: "testsession".into(),
            // No cap: this test is about lifecycle, and asking systemd for a
            // transient scope on a CI runner is a different thing to verify.
            caps: HashMap::new(),
            enforcement: caps::Enforcement::None,
            log_keep: 2,
        },
        logs,
    )
}

fn wait_until(what: &str, mut f: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if f() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("timed out waiting for {what}");
}

/// The whole round trip: launch, observe it as the state machine would, stop
/// it, and confirm it is really gone.
#[test]
fn a_component_starts_serves_a_port_and_stops() {
    let root = tmp("round-trip");
    // A listener written in the shell that is already required to run a start
    // command, so the test needs no extra language on the box.
    let port = free_port();
    let cmd = format!(
        "exec 3<>/dev/tcp/127.0.0.1/1 2>/dev/null; \
         while :; do nc -l 127.0.0.1 {port} </dev/null >/dev/null 2>&1 || sleep 0.2; done"
    );
    let c = component("be-app", &cmd, Some(port));
    let (l, logs) = launcher(&root, &c);

    match l.start(&c).expect("start") {
        Started::Launched(pid) | Started::LaunchedAfterReclaim(pid) => {
            assert!(pid > 0);
            wait_until("the wrapper to be alive", || process::is_alive(pid));

            // What the state machine sees is what the dashboard would show.
            let facts = Facts {
                pid: logs.pid("be-app"),
                pid_alive: true,
                port_open: false,
                health_ok: true,
            };
            assert_eq!(state::derive(&facts), pitcrew_model::State::Starting);

            let mut sampler = process::Sampler::new();
            let table = sampler.sample().table;
            let stopped = l.stop(&c, &table);
            assert!(stopped.did_anything(), "stop reported doing nothing");

            wait_until("the wrapper to be gone", || !process::is_alive(pid));
            // The pidfile going away is what makes a clean stop distinguishable
            // from a crash on the next frame.
            assert_eq!(
                logs.pid("be-app"),
                None,
                "the pidfile survived a clean stop"
            );
        }
        Started::AlreadyRunning => panic!("nothing should have been running"),
    }
}

/// Without the exit record a dead service is just an absence: the dashboard can
/// say "crashed" but never "exited 3 at 12:04".
#[test]
fn a_service_that_dies_leaves_a_record_of_how() {
    let root = tmp("exit-record");
    let c = component("be-app", "exit 3", None);
    let (l, logs) = launcher(&root, &c);

    l.start(&c).expect("start");
    wait_until("the exit record", || logs.exit("be-app").is_some());

    let e = logs.exit("be-app").unwrap();
    assert_eq!(e.code, 3, "the code the service exited with");
    assert!(e.at > 1_700_000_000, "a plausible unix time, got {}", e.at);

    // And the state machine turns that into "crashed" rather than "down": the
    // pidfile is still there, and its process is gone.
    let pid = logs.pid("be-app");
    assert!(pid.is_some(), "the pidfile records what ran");
    wait_until("the process to be gone", || {
        !process::is_alive(pid.unwrap())
    });
    assert_eq!(
        state::derive(&Facts {
            pid,
            pid_alive: false,
            port_open: false,
            health_ok: true,
        }),
        pitcrew_model::State::Crashed
    );
}

/// Output is captured verbatim — ANSI escapes included, because the log view
/// knows how to render colour and stripping it here loses it for good.
#[test]
fn stdout_and_stderr_are_captured_to_the_log() {
    let root = tmp("log");
    let c = component("be-app", "printf 'to out\\n'; printf 'to err\\n' >&2", None);
    let (l, logs) = launcher(&root, &c);

    l.start(&c).expect("start");
    wait_until("both streams", || {
        std::fs::read_to_string(logs.log("be-app"))
            .map(|t| t.contains("to out") && t.contains("to err"))
            .unwrap_or(false)
    });
}

/// Starting something that is already running must not start a second copy —
/// two JVMs on one port is a confusing failure, not a loud one.
#[test]
fn starting_a_running_component_is_a_no_op() {
    let root = tmp("already");
    let c = component("be-app", "sleep 20", None);
    let (l, logs) = launcher(&root, &c);

    let pid = match l.start(&c).expect("start") {
        Started::Launched(p) | Started::LaunchedAfterReclaim(p) => p,
        Started::AlreadyRunning => panic!("nothing was running"),
    };
    wait_until("it to be alive", || process::is_alive(pid));

    assert_eq!(
        l.start(&c).expect("second start"),
        Started::AlreadyRunning,
        "a second copy was launched"
    );
    assert_eq!(logs.pid("be-app"), Some(pid), "the pidfile changed");

    let mut sampler = process::Sampler::new();
    l.stop(&c, &sampler.sample().table);
}

/// A component is a tree — the wrapper, the shell, and the service under it.
/// Stopping only the root is how a "stopped" JVM keeps holding two gigabytes.
#[test]
fn stopping_takes_the_whole_tree_not_just_the_wrapper() {
    let root = tmp("tree");
    let c = component("be-app", "sleep 40 & sleep 40 & wait", None);
    let (l, logs) = launcher(&root, &c);

    let pid = match l.start(&c).expect("start") {
        Started::Launched(p) | Started::LaunchedAfterReclaim(p) => p,
        Started::AlreadyRunning => panic!("nothing was running"),
    };
    wait_until("the tree to exist", || {
        let mut s = process::Sampler::new();
        s.sample().table.tree(pid).len() >= 2
    });

    let mut sampler = process::Sampler::new();
    let table = sampler.sample().table;
    let tree = table.tree(pid);
    assert!(tree.len() >= 2, "expected children, got {tree:?}");

    l.stop(&c, &table);
    for p in tree {
        wait_until(&format!("pid {p} to die"), || !process::is_alive(p));
    }
    assert_eq!(logs.pid("be-app"), None);
}

/// An ephemeral port that is free right now. Bound and released, so the number
/// is real rather than hoped for.
fn free_port() -> u16 {
    let l = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind");
    let p = l.local_addr().unwrap().port();
    drop(l);
    let _ = ports::scan();
    p
}
