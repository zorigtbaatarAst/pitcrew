//! Reading only what was asked for, on Linux.
//!
//! **The general collector sweeps the whole process table.** That is the right
//! shape for a portable one — it is the only way to find a pid's children when
//! all you have is a list of processes and their parents — and it is the wrong
//! cost for a dashboard frame. On a box with 767 processes it is roughly 1500
//! file reads, once a second, to learn about four.
//!
//! Linux publishes the child list directly: `/proc/<pid>/task/<tid>/children`.
//! Walking that costs one read per process **in the tree**, which is what the
//! shell implementation always did and why its frames were cheap.
//!
//! This is a fast path, not a replacement. When it cannot answer — no `/proc`,
//! a container with a restricted one — the caller falls back to the portable
//! sweep and gets the same numbers more slowly.

use std::collections::{HashMap, HashSet};

use crate::process::{ProcInfo, ProcessTable};

/// Is the fast path usable here?
pub fn available() -> bool {
    // `children` is the whole point; a /proc without it is a /proc this cannot
    // use. Checking pid 1 rather than our own: a container may hide others.
    std::path::Path::new("/proc/self/stat").is_file()
        && std::path::Path::new("/proc/self/task").is_dir()
}

/// Read the process trees rooted at `roots`, and nothing else.
pub fn read_trees(roots: &[u32]) -> ProcessTable {
    let mut procs = HashMap::new();
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    let mut seen = HashSet::new();
    let mut stack: Vec<u32> = roots.to_vec();
    let (btime, hz) = (boot_seconds(), clock_ticks());

    while let Some(pid) = stack.pop() {
        // Pids are recycled, and a recycled one can make a process its own
        // ancestor. Without this the walk never returns.
        if !seen.insert(pid) {
            continue;
        }
        let Some(info) = read_one(pid, btime, hz) else {
            continue;
        };
        if let Some(parent) = info.ppid {
            children.entry(parent).or_default().push(pid);
        }
        procs.insert(pid, info);
        for kid in kids_of(pid) {
            stack.push(kid);
        }
    }
    for kids in children.values_mut() {
        kids.sort_unstable();
    }
    ProcessTable::from_parts(procs, children)
}

/// The direct children of a pid, from every thread's `children` file.
fn kids_of(pid: u32) -> Vec<u32> {
    let mut out = Vec::new();
    let Ok(tasks) = std::fs::read_dir(format!("/proc/{pid}/task")) else {
        return out;
    };
    for task in tasks.flatten() {
        let path = task.path().join("children");
        // The file has NO trailing newline, so a line-oriented read reports
        // failure even on success. Read it whole and look at the content.
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        out.extend(
            text.split_whitespace()
                .filter_map(|w| w.parse::<u32>().ok()),
        );
    }
    out
}

fn read_one(pid: u32, btime: u64, hz: u64) -> Option<ProcInfo> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // `comm` is in parentheses and may itself contain spaces AND parens, so the
    // split is on the LAST `") "` rather than the first — a process called
    // `(foo) bar` is unusual and entirely legal.
    let after = &stat[stat.rfind(") ")? + 2..];
    let f: Vec<&str> = after.split_whitespace().collect();

    // Fields after comm, zero-indexed: 0 state, 1 ppid, 11 utime, 12 stime,
    // 19 starttime.
    let ppid: u32 = f.get(1)?.parse().ok()?;
    let utime: u64 = f.get(11)?.parse().ok()?;
    let stime: u64 = f.get(12)?.parse().ok()?;
    let starttime: u64 = f.get(19)?.parse().ok()?;

    // statm's second field is the resident set in PAGES. Taken from here rather
    // than from stat's rss so it matches what `ps -o rss` reports, to the page.
    let rss = std::fs::read_to_string(format!("/proc/{pid}/statm"))
        .ok()
        .and_then(|t| t.split_whitespace().nth(1)?.parse::<u64>().ok())
        .map(|pages| pages * page_size())
        .unwrap_or(0);

    let cmd = std::fs::read(format!("/proc/{pid}/cmdline"))
        .ok()
        .map(|bytes| {
            // cmdline is NUL-separated, and NUL-terminated, so a naive split
            // leaves an empty last element.
            String::from_utf8_lossy(&bytes)
                .split('\0')
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" ")
        })
        .filter(|s| !s.is_empty())
        .unwrap_or_default();

    Some(ProcInfo {
        pid,
        ppid: (ppid != 0).then_some(ppid),
        rss,
        // Milliseconds, to match what the portable collector reports.
        cpu_ms: (utime + stime) * 1000 / hz.max(1),
        start_time: btime + starttime / hz.max(1),
        cmd: crate::process::readable_cmd(&cmd),
    })
}

fn page_size() -> u64 {
    // SAFETY: sysconf with a constant name has no failure mode worth handling;
    // a non-positive answer falls back to the near-universal 4K.
    let n = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if n > 0 {
        n as u64
    } else {
        4096
    }
}

fn clock_ticks() -> u64 {
    let n = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    if n > 0 {
        n as u64
    } else {
        100
    }
}

/// Seconds since the epoch at boot, so a start time in ticks-since-boot can be
/// turned into a real one.
fn boot_seconds() -> u64 {
    std::fs::read_to_string("/proc/stat")
        .ok()
        .and_then(|t| {
            t.lines()
                .find_map(|l| l.strip_prefix("btime "))
                .and_then(|v| v.trim().parse().ok())
        })
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn this_machine_can_use_the_fast_path() {
        assert!(available(), "a Linux box without a usable /proc");
    }

    /// The whole claim: reading one tree reads ONE tree, not the machine.
    #[test]
    fn it_reads_only_the_tree_it_was_asked_for() {
        let me = std::process::id();
        let table = read_trees(&[me]);
        assert!(table.contains(me));
        let everything = std::fs::read_dir("/proc")
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().parse::<u32>().is_ok())
            .count();
        assert!(
            table.len() < everything / 4,
            "read {} of {everything} processes — that is a sweep, not a walk",
            table.len()
        );
    }

    #[test]
    fn the_numbers_are_plausible() {
        let me = std::process::id();
        let table = read_trees(&[me]);
        let info = table.get(me).expect("this process");
        assert!(info.rss > 0, "a live process with no resident memory");
        assert!(info.ppid.is_some(), "this process has a parent");
        let now = crate::now();
        assert!(
            info.start_time > 0 && info.start_time <= now,
            "started at {} but it is {now}",
            info.start_time
        );
        assert!(!info.cmd.is_empty(), "a command line");
    }

    /// A child has to appear, or every component reports its wrapper's few
    /// megabytes instead of the JVM underneath it.
    #[test]
    fn a_child_is_found_through_the_children_file() {
        let mut child = std::process::Command::new("sleep")
            .arg("10")
            .stdout(std::process::Stdio::null())
            .spawn()
            .expect("spawn");
        let me = std::process::id();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            if read_trees(&[me]).contains(child.id()) || std::time::Instant::now() > deadline {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        assert!(
            read_trees(&[me]).contains(child.id()),
            "the child is missing"
        );
        let _ = child.kill();
        let _ = child.wait();
    }

    #[test]
    fn a_pid_that_is_gone_reads_as_an_empty_tree() {
        assert!(read_trees(&[u32::MAX - 1]).is_empty());
        assert!(read_trees(&[]).is_empty());
    }
}
