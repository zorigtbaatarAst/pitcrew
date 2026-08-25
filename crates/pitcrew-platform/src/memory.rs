//! The system gauges: how much of this machine is left.
//!
//! These exist because the product's actual promise is "a RAM meter before your
//! laptop falls over running six JVMs and six Node processes at once". The
//! numbers are read once per frame and must agree with what the OS's own
//! monitor says, or the meter is decoration.

use sysinfo::{MemoryRefreshKind, RefreshKind, System};

/// Whole-machine resource gauges. Bytes, and a 0-100 CPU percentage.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Machine {
    pub mem_total: u64,
    pub mem_used: u64,
    pub swap_total: u64,
    pub swap_used: u64,
    /// 0-100 across the whole machine, already divided by core count — unlike
    /// the per-process rates in [`crate::process`], which are per-core-summed.
    /// The two are different scales on purpose and must not be compared.
    pub cpu_percent: u32,
}

/// Reads the system gauges, holding the state that a CPU percentage needs.
///
/// Separate from [`crate::process::Sampler`] because swap moves slowly and cost
/// real money to read in the bash version (`sysctl vm.swapusage` is a fork), so
/// it was sampled on its own slower clock. That is no longer forced on us, but
/// the caller is still free to poll this less often than the process table.
pub struct Gauges {
    sys: System,
}

impl Default for Gauges {
    fn default() -> Self {
        Self::new()
    }
}

impl Gauges {
    pub fn new() -> Gauges {
        Gauges {
            sys: System::new_with_specifics(
                RefreshKind::nothing()
                    .with_memory(MemoryRefreshKind::everything())
                    .with_cpu(sysinfo::CpuRefreshKind::nothing().with_cpu_usage()),
            ),
        }
    }

    pub fn read(&mut self) -> Machine {
        self.sys.refresh_memory();
        self.sys.refresh_cpu_usage();
        Machine {
            mem_total: self.sys.total_memory(),
            mem_used: self.sys.used_memory(),
            swap_total: self.sys.total_swap(),
            swap_used: self.sys.used_swap(),
            // Rounded, not truncated: a machine at 99.6% should not read 99.
            cpu_percent: self.sys.global_cpu_usage().round().clamp(0.0, 100.0) as u32,
        }
    }
}

/// How many cores this machine has, floored at 1.
///
/// Used to turn a per-core-summed CPU figure into something comparable with the
/// machine gauge. A zero here would divide by zero on a frame path, so it never
/// returns one.
pub fn cpu_count() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
        .max(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_gauges_describe_a_real_machine() {
        let m = Gauges::new().read();
        assert!(m.mem_total > 0, "a machine with no memory");
        assert!(
            m.mem_used <= m.mem_total,
            "used {} exceeds total {}",
            m.mem_used,
            m.mem_total
        );
        assert!(m.swap_used <= m.swap_total || m.swap_total == 0);
        assert!(m.cpu_percent <= 100, "cpu percent is a percentage");
    }

    /// A zero would divide by zero on the frame path.
    #[test]
    fn core_count_is_never_zero() {
        assert!(cpu_count() >= 1);
    }
}
