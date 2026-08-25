//! Is a component up, starting, crashed, down or external, right now?
//!
//! Derived every frame from the pidfile, the port and the last health probe.
//! Nothing is remembered between frames, which is why there is nothing to
//! reconcile when pitcrew is not running.
//!
//! The definitions, and what each one is protecting against:
//!
//! * **up** — the port is open, it is *our* process holding it, and the health
//!   endpoint (if one is configured) says so. A port alone is not up: a Spring
//!   app binds long before it can serve a request.
//! * **starting** — our process is alive but the port is not open yet, or it is
//!   open and health has not said UP. This is the state a booting JVM sits in.
//! * **crashed** — a pidfile was recorded and that process is gone. `stop`
//!   removes the pidfile on a clean stop, which is exactly what makes a
//!   surviving one mean something died.
//! * **external** — something is listening on the port and it is not ours.
//!   Reporting that as up is how a project appears to be running when it is
//!   not: two checkouts sharing 8080 each see the other's service and count it
//!   as their own.
//! * **down** — no pidfile.
//!
//! `n/a` is not produced here. A role with no start command is not a component
//! at all, so there is nothing to ask about; it renders as `n/a`, is never
//! started, and is never counted as down.

use pitcrew_model::State;

/// Everything the decision needs, and nothing else — so it can be exhaustively
/// tested without a process, a port or a filesystem.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Facts {
    /// The pid from the pidfile. `None` means no pidfile at all.
    pub pid: Option<u32>,
    /// Is that pid a live process? Already false when the pidfile predates the
    /// last boot — see [`crate::logdir::LogDir::predates_boot`].
    pub pid_alive: bool,
    /// Is a port configured, and is something listening on it?
    pub port_open: bool,
    /// The last health verdict. `true` when no health path is configured, in
    /// which case an open port is what makes a component up.
    pub health_ok: bool,
}

pub fn derive(f: &Facts) -> State {
    let ours = f.pid.is_some() && f.pid_alive;
    if f.port_open {
        if !ours {
            return State::External;
        }
        return if f.health_ok {
            State::Up
        } else {
            State::Starting
        };
    }
    if ours {
        // Alive, port not open yet — still booting.
        return State::Starting;
    }
    if f.pid.is_some() {
        // A pidfile was recorded and the process is gone.
        return State::Crashed;
    }
    State::Down
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts(pid: Option<u32>, alive: bool, port_open: bool, health_ok: bool) -> Facts {
        Facts {
            pid,
            pid_alive: alive,
            port_open,
            health_ok,
        }
    }

    #[test]
    fn no_pidfile_is_down() {
        assert_eq!(derive(&facts(None, false, false, true)), State::Down);
    }

    /// `stop` removes the pidfile on a clean stop, so a surviving one means
    /// something died on its own.
    #[test]
    fn a_recorded_pid_that_is_gone_is_crashed() {
        assert_eq!(derive(&facts(Some(42), false, false, true)), State::Crashed);
    }

    /// The state a booting JVM sits in for thirty seconds.
    #[test]
    fn alive_with_no_port_yet_is_starting() {
        assert_eq!(derive(&facts(Some(42), true, false, true)), State::Starting);
    }

    #[test]
    fn alive_with_the_port_open_is_up() {
        assert_eq!(derive(&facts(Some(42), true, true, true)), State::Up);
    }

    /// A port alone is not up. A Spring app binds long before it can serve a
    /// request, and calling that up sends people to a URL that 503s.
    #[test]
    fn the_port_alone_is_not_up_when_health_is_configured() {
        assert_eq!(derive(&facts(Some(42), true, true, false)), State::Starting);
    }

    /// The one that stops a project appearing to run when it does not: two
    /// checkouts sharing 8080 each see the other's service.
    #[test]
    fn a_port_held_by_someone_else_is_external_not_up() {
        assert_eq!(derive(&facts(None, false, true, true)), State::External);
        // Even with a pidfile — if OUR process is gone, the listener is not ours.
        assert_eq!(derive(&facts(Some(42), false, true, true)), State::External);
    }

    /// External beats crashed, and that ordering matters: a component whose
    /// process died while something else took its port is a port conflict to
    /// resolve, not a crash to restart into.
    #[test]
    fn external_is_reported_ahead_of_crashed() {
        let f = facts(Some(42), false, true, true);
        assert_eq!(derive(&f), State::External);
    }

    /// Health is only consulted once the port is open and the process is ours.
    /// A stale UP from a previous run must not resurrect a dead component.
    #[test]
    fn health_cannot_make_a_dead_component_look_alive() {
        assert_eq!(derive(&facts(Some(42), false, false, true)), State::Crashed);
        assert_eq!(derive(&facts(None, false, false, true)), State::Down);
    }

    /// Every combination lands somewhere, and nothing that is not running is
    /// ever reported as running.
    #[test]
    fn no_combination_reports_a_stopped_component_as_running() {
        for pid in [None, Some(42u32)] {
            for alive in [false, true] {
                for port_open in [false, true] {
                    for health_ok in [false, true] {
                        let f = facts(pid, alive, port_open, health_ok);
                        let s = derive(&f);
                        if s == State::Up {
                            assert!(
                                pid.is_some() && alive && port_open && health_ok,
                                "up requires all four: {f:?}"
                            );
                        }
                        if !port_open && !(pid.is_some() && alive) {
                            assert!(
                                matches!(s, State::Down | State::Crashed),
                                "nothing is listening and nothing is alive: {f:?} -> {s:?}"
                            );
                        }
                    }
                }
            }
        }
    }
}
