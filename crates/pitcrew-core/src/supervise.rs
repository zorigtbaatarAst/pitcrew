//! Bringing crashed components back, with a budget.
//!
//! **In-loop policy, not a daemon.** This is called once per dashboard frame
//! and does nothing otherwise. A background supervisor would need its own
//! pidfile, its own stop path, and a way to notice it had died — three things
//! pitcrew deliberately does not have. The consequence is that auto-restart is
//! only active while a dashboard is open, which is stated rather than implied.
//!
//! The two rules that make this safe:
//!
//! **A first sighting only schedules.** The restart happens on a later frame,
//! once the backoff has elapsed — so a service that crashes during a frame is
//! not relaunched inside the same one, before anyone has seen it fail.
//!
//! **Staying healthy earns the budget back.** Without that, a service that
//! crashes once a week eventually exhausts its attempts and stops being
//! restarted at all, which is the opposite of what a budget is for.

use std::collections::HashMap;

use pitcrew_model::State;

pub struct Policy {
    /// Seconds before the first retry, doubling each time.
    pub backoff: i64,
    /// Attempts before giving up.
    pub max: u32,
    /// Seconds up before the attempt budget resets.
    pub reset: i64,
}

impl Default for Policy {
    fn default() -> Self {
        Policy {
            backoff: 2,
            max: 5,
            reset: 60,
        }
    }
}

#[derive(Default, Clone, Copy)]
struct Record {
    attempts: u32,
    /// When the next attempt is due. `None` means none is scheduled.
    due_at: Option<i64>,
    gave_up: bool,
    up_since: Option<i64>,
}

/// What the supervisor decided this frame.
#[derive(Debug, PartialEq, Eq)]
pub enum Action {
    /// Restart it now. Carries the attempt number and the budget, for the
    /// message — a restart that does not say which attempt it is looks like a
    /// loop.
    Restart { attempt: u32, of: u32 },
    /// It has crashed too many times. Said once, not every frame.
    GaveUp { after: u32 },
}

#[derive(Default)]
pub struct Supervisor {
    records: HashMap<String, Record>,
    policy: Policy,
    enabled: bool,
}

impl Supervisor {
    /// Off unless the project asked for it: relaunching a service somebody
    /// stopped on purpose is worse than leaving it down.
    pub fn new(enabled: bool, policy: Policy) -> Supervisor {
        Supervisor {
            records: HashMap::new(),
            policy,
            enabled,
        }
    }

    /// Called once per frame with every component's current state.
    pub fn tick(&mut self, states: &[(String, State)], now: i64) -> Vec<(String, Action)> {
        let mut out = Vec::new();
        if !self.enabled {
            return out;
        }
        for (name, state) in states {
            let r = self.records.entry(name.clone()).or_default();

            if *state == State::Up {
                let since = *r.up_since.get_or_insert(now);
                if now - since >= self.policy.reset {
                    // Healthy long enough: the streak is over.
                    *r = Record {
                        up_since: Some(since),
                        ..Default::default()
                    };
                }
                continue;
            }
            r.up_since = None;

            // `starting` is left alone — it has not failed yet. `down` is not
            // ours: nobody asked for it to be running.
            if *state != State::Crashed || r.gave_up {
                continue;
            }

            if r.attempts >= self.policy.max {
                r.gave_up = true;
                r.due_at = None;
                out.push((name.clone(), Action::GaveUp { after: r.attempts }));
                continue;
            }

            let Some(due) = r.due_at else {
                // First sighting of this crash: schedule, do not act.
                r.due_at = Some(now + self.policy.backoff * (1i64 << r.attempts.min(16)));
                continue;
            };
            if now < due {
                continue;
            }
            r.attempts += 1;
            r.due_at = None;
            out.push((
                name.clone(),
                Action::Restart {
                    attempt: r.attempts,
                    of: self.policy.max,
                },
            ));
        }
        out
    }

    /// Forget a component's crash history. A manual restart is a fresh start —
    /// the person has intervened, so the budget they exhausted is not theirs to
    /// keep paying.
    pub fn clear(&mut self, comp: &str) {
        self.records.remove(comp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sup() -> Supervisor {
        Supervisor::new(true, Policy::default())
    }

    fn crashed(name: &str) -> Vec<(String, State)> {
        vec![(name.to_string(), State::Crashed)]
    }

    #[test]
    fn it_does_nothing_unless_enabled() {
        let mut s = Supervisor::default();
        assert!(s.tick(&crashed("be-a"), 0).is_empty());
    }

    /// A first sighting only schedules. Relaunching inside the same frame the
    /// crash appeared in restarts a service before anyone has seen it fail.
    #[test]
    fn a_first_sighting_schedules_rather_than_acting() {
        let mut s = sup();
        assert!(s.tick(&crashed("be-a"), 100).is_empty());
    }

    #[test]
    fn the_restart_happens_once_the_backoff_has_elapsed() {
        let mut s = sup();
        s.tick(&crashed("be-a"), 100);
        assert!(s.tick(&crashed("be-a"), 101).is_empty(), "backoff is 2s");
        assert_eq!(
            s.tick(&crashed("be-a"), 102),
            [("be-a".to_string(), Action::Restart { attempt: 1, of: 5 })]
        );
    }

    /// Doubling, so a service failing on a syntax error is not relaunched in a
    /// tight loop for as long as the dashboard is open.
    #[test]
    fn the_backoff_doubles_each_attempt() {
        let mut s = sup();
        let mut t = 100;
        let mut waits = Vec::new();
        for _ in 0..3 {
            let scheduled = t;
            s.tick(&crashed("be-a"), t);
            // Advance until it fires.
            loop {
                t += 1;
                if !s.tick(&crashed("be-a"), t).is_empty() {
                    break;
                }
            }
            waits.push(t - scheduled);
        }
        assert_eq!(waits, [2, 4, 8]);
    }

    /// Said once, not on every frame — a dashboard repeating "gave up" every
    /// second is noise that hides the next real event.
    #[test]
    fn it_gives_up_once_and_then_stays_quiet() {
        let mut s = sup();
        let mut gave_up = 0;
        for t in 100..300 {
            for (_, a) in s.tick(&crashed("be-a"), t) {
                if matches!(a, Action::GaveUp { .. }) {
                    gave_up += 1;
                }
            }
        }
        assert_eq!(gave_up, 1, "it announced giving up more than once");
    }

    /// Without this a service that crashes once a week eventually exhausts its
    /// attempts and stops being restarted at all.
    #[test]
    fn staying_healthy_earns_the_budget_back() {
        let mut s = sup();
        let mut t = 100;
        // Burn two attempts.
        for _ in 0..2 {
            s.tick(&crashed("be-a"), t);
            loop {
                t += 1;
                if !s.tick(&crashed("be-a"), t).is_empty() {
                    break;
                }
            }
        }
        // Now stay up past the reset window.
        let up = vec![("be-a".to_string(), State::Up)];
        s.tick(&up, t);
        s.tick(&up, t + 61);

        // The next crash starts from the first backoff again.
        s.tick(&crashed("be-a"), t + 62);
        let fired = s.tick(&crashed("be-a"), t + 64);
        assert_eq!(
            fired,
            [("be-a".to_string(), Action::Restart { attempt: 1, of: 5 })],
            "the streak should have been forgotten"
        );
    }

    /// Being up briefly is not the same as being healthy.
    #[test]
    fn a_short_recovery_does_not_reset_the_budget() {
        let mut s = sup();
        s.tick(&crashed("be-a"), 100);
        s.tick(&crashed("be-a"), 102); // attempt 1
        let up = vec![("be-a".to_string(), State::Up)];
        s.tick(&up, 103);
        s.tick(&up, 110); // only 7s, under the 60s reset

        s.tick(&crashed("be-a"), 111);
        // Attempt 2 means the streak survived, and its backoff is 4s not 2s.
        assert!(
            s.tick(&crashed("be-a"), 113).is_empty(),
            "backoff should be 4s"
        );
        assert_eq!(
            s.tick(&crashed("be-a"), 115),
            [("be-a".to_string(), Action::Restart { attempt: 2, of: 5 })]
        );
    }

    /// `starting` has not failed yet, and `down` is not ours — nobody asked for
    /// it to be running.
    #[test]
    fn only_a_crash_is_acted_on() {
        let mut s = sup();
        for state in [State::Starting, State::Down, State::External, State::NotA] {
            let v = vec![("be-a".to_string(), state)];
            s.tick(&v, 100);
            assert!(s.tick(&v, 200).is_empty(), "{state:?} should be left alone");
            s.clear("be-a");
        }
    }

    /// The person intervened, so the budget they exhausted is not theirs to
    /// keep paying.
    #[test]
    fn a_manual_restart_is_a_fresh_start() {
        let mut s = sup();
        let mut t = 100;
        for _ in 0..5 {
            s.tick(&crashed("be-a"), t);
            loop {
                t += 1;
                if !s.tick(&crashed("be-a"), t).is_empty() {
                    break;
                }
            }
        }
        assert!(matches!(
            s.tick(&crashed("be-a"), t + 1).first(),
            Some((_, Action::GaveUp { .. }))
        ));

        s.clear("be-a");
        s.tick(&crashed("be-a"), t + 2);
        assert_eq!(
            s.tick(&crashed("be-a"), t + 4),
            [("be-a".to_string(), Action::Restart { attempt: 1, of: 5 })]
        );
    }
}
