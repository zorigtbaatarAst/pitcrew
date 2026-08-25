//! Launching something that outlives us.
//!
//! pitcrew has no daemon: `start` launches a service and exits. The service
//! must therefore not be pitcrew's child in any way that matters — otherwise a
//! long-lived dashboard restarting components accumulates zombies, and a
//! Ctrl-C in the terminal takes the whole stack with it.
//!
//! The two platforms reach that differently, and the difference is real enough
//! to be worth naming rather than papering over.

use std::path::Path;
use std::process::{Command, Stdio};

/// Launch `script` so that it survives this process, and report the pid of the
/// thing that is actually running.
///
/// `pidfile` is written by the launcher itself rather than by the caller: on
/// Unix the pid that matters belongs to a background subshell, and only the
/// shell that forked it knows the number.
pub fn detached(script: &str, pidfile: &Path) -> std::io::Result<u32> {
    #[cfg(unix)]
    {
        // The service is backgrounded INSIDE the shell and the shell then
        // exits, so the service is orphaned and reparented to init. That is
        // what keeps it out of our process table: nothing here ever has to
        // reap it, and nothing here can leave it a zombie.
        let wrapper = format!(
            "{{\n{script}\n}} &\nprintf '%s\\n' \"$!\" > {}\n",
            quote(&pidfile.to_string_lossy())
        );
        let status = Command::new(shell())
            .arg("-c")
            .arg(&wrapper)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        if !status.success() {
            return Err(std::io::Error::other("the launcher shell failed"));
        }
        // Written by the shell a moment ago; read back rather than guessed.
        let pid = std::fs::read_to_string(pidfile)?
            .trim()
            .parse()
            .map_err(|_| std::io::Error::other("the launcher wrote no pid"))?;
        Ok(pid)
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // Windows has no zombies and no orphan problem: a process outlives its
        // parent by default. DETACHED_PROCESS keeps it off our console so a
        // Ctrl-C here does not reach it.
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        let child = Command::new(shell())
            .arg("/C")
            .arg(script)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP)
            .spawn()?;
        let pid = child.id();
        std::fs::write(pidfile, format!("{pid}\n"))?;
        Ok(pid)
    }
}

/// The shell a start command is handed to.
///
/// **This is a real portability limit, not an implementation detail.** A
/// pitcrew start command is a shell string — the shipped examples use
/// `{ [ -d node_modules ] || npm install; } && npm run dev` — and that is POSIX
/// shell syntax. On Windows it goes to `cmd.exe`, where `&&` and `cd` work and
/// a `{ ...; }` grouping does not. `doctor` should say so; a config written on
/// Linux is not guaranteed to run here.
pub fn shell() -> &'static str {
    #[cfg(windows)]
    {
        "cmd"
    }
    #[cfg(not(windows))]
    {
        // bash where there is one, because a config may legitimately use
        // bashisms and the format's own examples do. `sh` is the fallback
        // rather than the default, so a `{ ...; }` grouping cannot silently
        // mean something else.
        if Path::new("/bin/bash").exists() {
            "/bin/bash"
        } else {
            "/bin/sh"
        }
    }
}

/// True where a start command gets a POSIX shell.
pub const fn posix_shell() -> bool {
    cfg!(not(windows))
}

#[cfg(unix)]
fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn tmp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("pitcrew-spawn-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// The whole contract in one test: the thing that ends up running is NOT
    /// this process's child, so nothing here has to reap it.
    #[cfg(unix)]
    #[test]
    fn what_is_launched_outlives_the_launcher_and_is_not_our_child() {
        let d = tmp("detached");
        let pidfile = d.join("x.pid");
        let marker = d.join("ran");

        let pid = detached(
            &format!(
                "sleep 5 && printf done > {}",
                quote(&marker.to_string_lossy())
            ),
            &pidfile,
        )
        .expect("launch");

        assert!(
            crate::process::is_alive(pid),
            "the service should be running"
        );
        assert_eq!(
            std::fs::read_to_string(&pidfile).unwrap().trim(),
            pid.to_string()
        );

        // Not our child: its parent is init (or whatever adopted it), never us.
        let mut sampler = crate::process::Sampler::new();
        let table = sampler.sample().table;
        let ppid = table.get(pid).and_then(|p| p.ppid);
        assert_ne!(
            ppid,
            Some(std::process::id()),
            "the service is still our child, so it will become a zombie"
        );

        let _ = crate::process::signal(pid, crate::process::Signal::Kill);
    }

    /// The exit record is the point of the wrapper: without it a dead service
    /// is just an absence, and "exited 1 at 12:04" is the first thing anyone
    /// actually wants to know.
    #[cfg(unix)]
    #[test]
    fn a_wrapper_can_record_how_its_command_ended() {
        let d = tmp("exit");
        let pidfile = d.join("x.pid");
        let exitfile = d.join("x.exit");

        // The command and the recorder must be ONE shell, or `$?` belongs to
        // something else by the time it is read.
        let script = format!(
            "( exit 3 )\n__rc=$?\nprintf '%s %s\\n' \"$__rc\" \"$(date +%s)\" > {}\n",
            quote(&exitfile.to_string_lossy())
        );

        detached(&script, &pidfile).expect("launch");

        for _ in 0..100 {
            if exitfile.exists() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let recorded = std::fs::read_to_string(&exitfile).expect("the wrapper recorded an exit");
        let mut parts = recorded.split_whitespace();
        assert_eq!(parts.next(), Some("3"), "the exit code");
        let at: i64 = parts
            .next()
            .expect("a timestamp")
            .parse()
            .expect("a number");
        assert!(at > 1_700_000_000, "a plausible unix time, got {at}");
    }

    #[test]
    fn the_shell_limit_is_stated_rather_than_implied() {
        assert_eq!(posix_shell(), cfg!(not(windows)));
    }
}
