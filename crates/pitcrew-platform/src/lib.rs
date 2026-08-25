//! The only crate that knows which OS it is running on.
//!
//! Linux, macOS and Windows are first-class targets: same features, same numbers
//! on screen, different plumbing underneath. A `cfg(target_os)` anywhere outside
//! this crate is a bug — that rule is inherited verbatim from the bash
//! implementation's `lib/00-platform.sh`, and it is the only reason the macOS and
//! Windows paths were ever verifiable from a Linux box.
//!
//! ## What this replaces, and what it deletes
//!
//! `lib/00-platform.sh` (624 lines) plus the collectors in
//! `lib/03a-snapshot.sh` (687 lines). Most of that was not design, it was the
//! cost of asking a shell to read a process table:
//!
//! * `_cputime_cs` / `_etime_secs` — hand-written parsers for
//!   `[[DD-]HH:]MM:SS[.cc]` across the macOS/Linux spelling difference. Gone;
//!   the numbers arrive typed.
//! * `_addr_is_local` — a little-endian hex table for matching `/proc/net/tcp`
//!   local addresses. Gone; [`ports`] gets real `IpAddr`s.
//! * `_wmic_ps_parse` and `_PF_DAYS_FROM_CIVIL` — WMI CSV parsing with manual
//!   timezone arithmetic, and Howard Hinnant's `days_from_civil` reimplemented
//!   in awk because `mktime()` is a GNU extension that makes BSD awk refuse the
//!   whole program. Gone.
//! * `_pf_win_msys_kids` — reconstructing the POSIX process tree that the
//!   Windows process table cannot express, because Cygwin implements `exec` by
//!   creating a *new* Windows process. Gone: a native binary has one pid
//!   namespace.
//!
//! ## What is new
//!
//! RAM caps are **enforceable on Windows** for the first time — see [`caps`].
//! The bash version could only apologise for this (`lib/12-doctor.sh:48`).
//!
//! ## What has NOT changed
//!
//! macOS still cannot enforce a memory cap; there is no cgroup equivalent and
//! `ulimit -v` is not honoured there. [`caps::Enforcement`] says so plainly
//! rather than letting identical-looking meters imply otherwise.

pub mod caps;
pub mod memory;
pub mod ports;
#[cfg(target_os = "linux")]
mod proc_linux;
pub mod process;
pub mod spawn;

pub use caps::Enforcement;
pub use memory::Machine;
pub use ports::Listening;
pub use process::{ProcInfo, ProcessTable, Sampler};

/// Which platform this binary is running on.
///
/// Deliberately coarser than `target_os`: the tool only ever branches on the
/// three behaviours that actually differ (cgroups, no enforcement, job
/// objects), and every BSD takes the same path macOS does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Os {
    Linux,
    MacOs,
    Bsd,
    Windows,
    Other,
}

impl Os {
    pub const fn current() -> Os {
        if cfg!(target_os = "linux") {
            Os::Linux
        } else if cfg!(target_os = "macos") {
            Os::MacOs
        } else if cfg!(any(
            target_os = "freebsd",
            target_os = "openbsd",
            target_os = "netbsd",
            target_os = "dragonfly"
        )) {
            Os::Bsd
        } else if cfg!(target_os = "windows") {
            Os::Windows
        } else {
            Os::Other
        }
    }

    /// The word that appears in `pitcrew doctor` and in the JSON contract.
    pub const fn as_str(self) -> &'static str {
        match self {
            Os::Linux => "linux",
            Os::MacOs => "macos",
            Os::Bsd => "bsd",
            Os::Windows => "windows",
            Os::Other => "other",
        }
    }
}

/// Seconds since the epoch at which this machine booted.
///
/// Used to decide whether a pidfile survived a reboot: a recorded pid that
/// predates boot cannot be the process that wrote it, whatever is running under
/// that number now. The bash version got this from `/proc/1`'s mtime on Linux
/// and by parsing `sysctl kern.boottime` elsewhere, then compared with a `-nt`
/// test against a stamp file so the per-frame check cost no fork.
pub fn boot_time() -> u64 {
    sysinfo::System::boot_time()
}

/// Seconds since the epoch, now.
pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The strings are the contract — they appear in `doctor --json` as `os`.
    #[test]
    fn os_names_match_the_bash_spellings() {
        assert_eq!(Os::Linux.as_str(), "linux");
        assert_eq!(Os::MacOs.as_str(), "macos");
        assert_eq!(Os::Bsd.as_str(), "bsd");
        assert_eq!(Os::Windows.as_str(), "windows");
    }

    /// A machine that booted in the future, or at the epoch, means the reboot
    /// check silently stops working — so assert it is at least plausible.
    #[test]
    fn boot_time_precedes_now() {
        let (boot, now) = (boot_time(), now());
        assert!(boot > 0, "boot time is unavailable");
        assert!(boot <= now, "boot time {boot} is after now {now}");
    }
}
