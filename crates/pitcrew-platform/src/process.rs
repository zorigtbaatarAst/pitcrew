//! The process table, the tree walk, and CPU as a real delta.

use std::collections::{HashMap, HashSet};
use std::time::Instant;

use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System};

/// One process, as pitcrew needs it.
#[derive(Debug, Clone)]
pub struct ProcInfo {
    pub pid: u32,
    /// `None` for pid 1 and for a process whose parent has already gone.
    pub ppid: Option<u32>,
    /// Resident set size, in bytes — what `ps -o rss` reports, to the page.
    pub rss: u64,
    /// Cumulative CPU time in milliseconds, summed across cores. This is the
    /// counter deltas are taken against; it is never shown to anyone directly.
    pub cpu_ms: u64,
    /// Unix seconds at which this process started.
    pub start_time: u64,
    /// The command, for the process view. Falls back to the executable name
    /// when the full argv is not readable (another user's process, or a
    /// hardened kernel).
    pub cmd: String,
}

/// A process table plus the parent→children index built from it.
///
/// Built once per sample. Everything that needs a tree walks this rather than
/// asking the OS again — in bash that was to avoid a `pgrep` per node, and here
/// it is because one syscall sweep beats N.
#[derive(Debug, Default, Clone)]
pub struct ProcessTable {
    procs: HashMap<u32, ProcInfo>,
    children: HashMap<u32, Vec<u32>>,
}

impl ProcessTable {
    pub fn get(&self, pid: u32) -> Option<&ProcInfo> {
        self.procs.get(&pid)
    }

    pub fn contains(&self, pid: u32) -> bool {
        self.procs.contains_key(&pid)
    }

    pub fn len(&self) -> usize {
        self.procs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.procs.is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = &ProcInfo> {
        self.procs.values()
    }

    /// Every pid in `root`'s tree, including `root` itself, or an empty vec if
    /// `root` is not in the table.
    ///
    /// **The visited set is not defensive programming.** Pids are recycled, and
    /// a recycled pid can make a process its own ancestor — at which point a
    /// naive descent never returns, and the dashboard never draws another
    /// frame. The bash implementation hit this and guarded it the same way
    /// (`lib/03a-snapshot.sh:445-451`).
    ///
    /// Order is deterministic (parents before children, siblings by pid) so a
    /// process view does not reshuffle between frames.
    pub fn tree(&self, root: u32) -> Vec<u32> {
        if !self.procs.contains_key(&root) {
            return Vec::new();
        }
        let mut out = Vec::new();
        let mut seen = HashSet::new();
        let mut stack = vec![root];
        while let Some(pid) = stack.pop() {
            if !seen.insert(pid) {
                continue;
            }
            out.push(pid);
            if let Some(kids) = self.children.get(&pid) {
                // Pushed in reverse so the pop order is ascending by pid.
                stack.extend(kids.iter().rev().copied());
            }
        }
        out
    }

    /// RSS summed over a whole tree.
    ///
    /// Summing the tree rather than reading the root is what makes the number
    /// identical with and without systemd, and it is the difference between
    /// "the JVM is using 2.1G" and "the wrapper shell is using 3M".
    pub fn tree_rss(&self, root: u32) -> u64 {
        self.tree(root)
            .iter()
            .filter_map(|p| self.procs.get(p))
            .map(|p| p.rss)
            .sum()
    }

    /// The earliest start time in a tree — when the component actually began,
    /// not when its newest child forked.
    pub fn tree_started(&self, root: u32) -> Option<u64> {
        self.tree(root)
            .iter()
            .filter_map(|p| self.procs.get(p))
            .map(|p| p.start_time)
            .min()
    }
}

/// Samples the process table and turns the cumulative CPU counters into a rate.
///
/// Holding the previous sample is the whole reason this is a struct: CPU% is a
/// delta over a window, and a single reading can only ever report "unknown".
/// That is also why the desktop app streams `json --watch` instead of polling
/// `status --json` on a timer — a fresh process has no previous sample and
/// reports null cpu forever.
pub struct Sampler {
    sys: System,
    /// pid → cumulative cpu_ms at the previous sample.
    prev: HashMap<u32, u64>,
    prev_at: Instant,
    /// False until a second sample has been taken; before that, every CPU
    /// reading is `None` rather than a fabricated zero.
    primed: bool,
}

impl Default for Sampler {
    fn default() -> Self {
        Self::new()
    }
}

/// One sample: the table, plus per-pid CPU% over the window since the last one.
pub struct Sample {
    pub table: ProcessTable,
    /// pid → percent, summed across cores, so a fully busy 4-thread process on
    /// a 4-core box reads 400. Absent while the sampler is unprimed.
    pub cpu: HashMap<u32, f64>,
}

impl Sample {
    /// CPU% summed over a whole tree. `None` until the sampler is primed.
    pub fn tree_cpu(&self, table: &ProcessTable, root: u32) -> Option<f64> {
        if self.cpu.is_empty() {
            return None;
        }
        Some(
            table
                .tree(root)
                .iter()
                .filter_map(|p| self.cpu.get(p))
                .sum(),
        )
    }
}

impl Sampler {
    pub fn new() -> Sampler {
        Sampler {
            sys: System::new(),
            prev: HashMap::new(),
            prev_at: Instant::now(),
            primed: false,
        }
    }

    /// Refresh the process table and compute CPU rates over the elapsed window.
    pub fn sample(&mut self) -> Sample {
        // `cpu()` is asked for because it is what populates the accumulated
        // counter; the rate below is computed here rather than taken from
        // sysinfo's own `cpu_usage`, which normalises per core. pitcrew's
        // meters have always been per-core-summed, and changing that would
        // silently rescale every RAM/CPU cell in the dashboard.
        self.sys.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            ProcessRefreshKind::nothing()
                .with_cpu()
                .with_memory()
                .with_cmd(sysinfo::UpdateKind::OnlyIfNotSet),
        );

        let now = Instant::now();
        let window_ms = now.duration_since(self.prev_at).as_secs_f64() * 1000.0;

        let mut procs = HashMap::with_capacity(self.sys.processes().len());
        let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
        let mut cpu = HashMap::new();
        // Rebuilt, never updated in place: a map that is only ever inserted
        // into accumulates every pid the machine has used since the dashboard
        // opened, and on a box that forks a lot that is a slow leak with a
        // wrong answer at the end of it.
        let mut next_prev = HashMap::with_capacity(self.sys.processes().len());

        for (pid, proc) in self.sys.processes() {
            let pid = pid.as_u32();
            let ppid = proc.parent().map(|p| p.as_u32());
            let cpu_ms = proc.accumulated_cpu_time();

            if let Some(&was) = self.prev.get(&pid) {
                // A saturating difference, because the counter can go backwards:
                // a pid recycled between samples belongs to a different process
                // whose counter starts near zero, and a negative rate rendered
                // as a bar is worse than no rate at all.
                let delta = cpu_ms.saturating_sub(was) as f64;
                if window_ms > 0.0 {
                    cpu.insert(pid, (delta / window_ms) * 100.0);
                }
            }
            next_prev.insert(pid, cpu_ms);

            if let Some(parent) = ppid {
                children.entry(parent).or_default().push(pid);
            }

            procs.insert(
                pid,
                ProcInfo {
                    pid,
                    ppid,
                    rss: proc.memory(),
                    cpu_ms,
                    start_time: proc.start_time(),
                    cmd: command_of(proc),
                },
            );
        }

        for kids in children.values_mut() {
            kids.sort_unstable();
        }

        self.prev = next_prev;
        self.prev_at = now;
        // The first sample has nothing to difference against. Report no CPU
        // rather than a zero that reads as "this service is idle".
        let cpu = if self.primed { cpu } else { HashMap::new() };
        self.primed = true;

        Sample {
            table: ProcessTable { procs, children },
            cpu,
        }
    }
}

/// The command line, joined, falling back to the process name.
///
/// A process pitcrew cannot read the argv of is still a process worth showing —
/// dropping it would leave a hole in the tree and an RSS total that does not add
/// up to what the meter says.
fn command_of(proc: &sysinfo::Process) -> String {
    let argv = proc.cmd();
    if argv.is_empty() {
        return proc.name().to_string_lossy().into_owned();
    }
    argv.iter()
        .map(|a| a.to_string_lossy())
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a table by hand so the tree tests do not depend on what happens
    /// to be running on the machine.
    fn table(edges: &[(u32, Option<u32>)]) -> ProcessTable {
        let mut procs = HashMap::new();
        let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
        for &(pid, ppid) in edges {
            procs.insert(
                pid,
                ProcInfo {
                    pid,
                    ppid,
                    rss: pid as u64 * 1000,
                    cpu_ms: 0,
                    start_time: 100 + pid as u64,
                    cmd: format!("proc{pid}"),
                },
            );
            if let Some(p) = ppid {
                children.entry(p).or_default().push(pid);
            }
        }
        for kids in children.values_mut() {
            kids.sort_unstable();
        }
        ProcessTable { procs, children }
    }

    #[test]
    fn tree_includes_the_root_and_every_descendant() {
        let t = table(&[
            (10, None),
            (11, Some(10)),
            (12, Some(10)),
            (13, Some(11)),
            (99, None),
        ]);
        assert_eq!(t.tree(10), vec![10, 11, 13, 12]);
        assert_eq!(t.tree(11), vec![11, 13]);
        assert_eq!(t.tree(99), vec![99]);
    }

    #[test]
    fn a_pid_that_is_not_running_has_no_tree() {
        let t = table(&[(10, None)]);
        assert!(t.tree(4242).is_empty());
    }

    /// The one that matters. A recycled pid can make a process its own
    /// ancestor; without the visited set this descent never returns and the
    /// dashboard stops repainting — which is indistinguishable from a hang.
    #[test]
    fn a_cycle_terminates_instead_of_hanging_the_dashboard() {
        let t = table(&[(10, Some(12)), (11, Some(10)), (12, Some(11))]);
        let walked = t.tree(10);
        assert_eq!(walked.len(), 3, "every node visited exactly once");
        let unique: HashSet<_> = walked.iter().collect();
        assert_eq!(unique.len(), 3);
    }

    /// A process that is its own parent is the degenerate case of the same bug.
    #[test]
    fn a_self_parented_process_terminates() {
        let t = table(&[(7, Some(7))]);
        assert_eq!(t.tree(7), vec![7]);
    }

    /// Summing the tree is what makes the number identical with and without
    /// systemd — and the difference between reporting a JVM and reporting the
    /// wrapper shell that launched it.
    #[test]
    fn tree_rss_sums_the_whole_tree_not_just_the_root() {
        let t = table(&[(1, None), (2, Some(1)), (3, Some(2))]);
        assert_eq!(t.tree_rss(1), 1000 + 2000 + 3000);
        assert_eq!(t.tree_rss(2), 2000 + 3000);
    }

    /// When a component started is the earliest process in its tree, not the
    /// newest child it happens to have forked a second ago.
    #[test]
    fn tree_started_is_the_earliest_process_in_it() {
        let t = table(&[(5, None), (6, Some(5)), (7, Some(6))]);
        assert_eq!(t.tree_started(5), Some(105));
        assert_eq!(t.tree_started(9), None);
    }

    /// The first sample has nothing to difference against, so it must report no
    /// CPU rather than a zero that reads as "this service is idle".
    #[test]
    fn the_first_sample_reports_no_cpu() {
        let mut s = Sampler::new();
        let first = s.sample();
        assert!(first.cpu.is_empty(), "an unprimed sampler invents no rates");
        assert!(!first.table.is_empty(), "but it does see processes");
        assert!(
            first.table.contains(std::process::id()),
            "including this one"
        );
    }

    /// And the second one does, because by then there is a window.
    #[test]
    fn a_primed_sampler_produces_rates() {
        let mut s = Sampler::new();
        s.sample();
        // Enough work to be sure at least one process on the box accumulated a
        // measurable millisecond, without sleeping in a test.
        let mut n: u64 = 0;
        for i in 0..8_000_000u64 {
            n = n.wrapping_add(i);
        }
        assert_ne!(n, u64::MAX);
        let second = s.sample();
        assert!(!second.cpu.is_empty(), "a primed sampler reports rates");
    }
}
