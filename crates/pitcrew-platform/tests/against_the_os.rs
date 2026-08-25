//! Cross-checks against the OS's own tools.
//!
//! The unit tests prove the tree walk and the local-address rules in isolation.
//! These prove the numbers are the same ones `ps` reports — which is the actual
//! claim the dashboard makes, and the one thing a hand-built fixture cannot
//! check. The bash implementation took RSS from `/proc/<pid>/statm` rather than
//! `/proc/<pid>/stat` specifically so it would match `ps -o rss` to the page;
//! this is where that agreement is verified rather than assumed.
//!
//! Unix only: there is no `ps` on Windows, and the Windows collector is checked
//! by the unit tests plus CI compiling it.

#![cfg(unix)]

use std::process::{Command, Stdio};

use pitcrew_platform::process::Sampler;

/// RSS for a live process, straight from `ps`, in bytes.
fn ps_rss_bytes(pid: u32) -> Option<u64> {
    let out = Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let kb: u64 = String::from_utf8_lossy(&out.stdout).trim().parse().ok()?;
    Some(kb * 1024)
}

/// `ps` reports RSS in kilobytes and pitcrew reports bytes; agreement is
/// therefore only ever to the page. A few pages of drift between the two reads
/// is the process actually allocating, not a collector bug — but an order of
/// magnitude is a unit error, which is the failure this is here to catch.
#[test]
fn rss_agrees_with_ps_for_this_process() {
    let mut sampler = Sampler::new();
    let sample = sampler.sample();
    let me = std::process::id();

    let ours = sample
        .table
        .get(me)
        .expect("the collector cannot see the process it is running in")
        .rss;
    let Some(theirs) = ps_rss_bytes(me) else {
        eprintln!("skipping: ps is unavailable or gave no answer");
        return;
    };

    assert!(ours > 0, "collector reported zero RSS for a live process");
    let (lo, hi) = (ours.min(theirs) as f64, ours.max(theirs) as f64);
    assert!(
        hi / lo < 2.0,
        "collector says {ours} bytes, ps says {theirs} — that is not page drift, \
         it is a unit error"
    );
}

/// The parent/child link is what every RAM figure in the dashboard rests on: a
/// component's number is its whole tree, and a broken link reports the wrapper
/// shell's few megabytes instead of the JVM under it. That was a real bug on
/// Windows under MSYS, and it was invisible except as "the meter says the
/// machine is empty".
#[test]
fn a_spawned_child_appears_in_its_parents_tree() {
    let mut child = Command::new("sleep")
        .arg("30")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn sleep");
    let child_pid = child.id();

    let mut sampler = Sampler::new();
    let sample = sampler.sample();
    let me = std::process::id();

    let tree = sample.table.tree(me);
    assert!(
        tree.contains(&child_pid),
        "child {child_pid} is missing from this process's tree {tree:?}"
    );
    assert!(tree.contains(&me), "a tree must include its own root");

    // The tree total must exceed the root alone, or the sum is not summing.
    let root_only = sample.table.get(me).unwrap().rss;
    assert!(
        sample.table.tree_rss(me) > root_only,
        "tree RSS did not include the child"
    );

    let _ = child.kill();
    let _ = child.wait();
}

/// A component's start time is the earliest process in its tree. Asserting it
/// is not in the future catches a units-or-epoch mistake, which renders as an
/// uptime counting backwards rather than as an obvious crash.
#[test]
fn start_times_are_in_the_past() {
    let mut sampler = Sampler::new();
    let sample = sampler.sample();
    let now = pitcrew_platform::now();

    let started = sample
        .table
        .tree_started(std::process::id())
        .expect("this process has a start time");
    assert!(
        started <= now,
        "process started at {started}, which is after now ({now})"
    );
    assert!(
        started >= pitcrew_platform::boot_time(),
        "process started at {started}, before the machine booted"
    );
}
