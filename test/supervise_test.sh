#!/usr/bin/env bash
# Auto-restart and log retention.
#
# The supervisor is a small state machine whose failure modes are all invisible
# in normal use: restarting too eagerly buries the log you need, giving up too
# early leaves a service down, and never resetting the counter means a service
# that crashes once a month eventually stops being restarted at all. Exactly
# the shape of thing worth pinning down.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

LOG_DIR=$(mktemp -d)
C=be-both

# stub the launcher: the state machine is under test, not the process spawner
RESTARTS=0
start_comp() { RESTARTS=$((RESTARTS + 1)); }
stop_comp()  { :; }

_reset() {
  RESTARTS=0
  RESTART_N=(); RESTART_AT=(); RESTART_GAVEUP=(); UP_SINCE=()
  PITCREW_RESTART=1
  PITCREW_RESTART_BACKOFF=2
  PITCREW_RESTART_MAX=3
  PITCREW_RESTART_RESET=60
  PITCREW_COMPS=("$C")
  SNAP_STATE=([$C]=crashed)
  SNAP_NOW_S=1000
}

# advance the clock and run one frame's worth of supervision
_tick() { SNAP_NOW_S=$(( SNAP_NOW_S + ${1:-1} )); supervise; }

# ── log retention ───────────────────────────────────────────────────────────

test_rotation_keeps_the_previous_runs_log() {
  # restarting a service used to erase the log you were restarting it to read
  PITCREW_LOG_KEEP=2
  local f="$LOG_DIR/rot.log"
  printf 'run one\n' > "$f";  rotate_log rot
  printf 'run two\n' > "$f";  rotate_log rot
  printf 'run three\n' > "$f"
  assert_eq "$(cat "$f")"     "run three" "live log"
  assert_eq "$(cat "$f.1")"   "run two"   "previous run"
  assert_eq "$(cat "$f.2")"   "run one"   "the one before that"
  assert_fails test -f "$f.3"             # budget respected
  rm -f "$f" "$f".[0-9]
}

test_rotation_can_be_turned_off() {
  PITCREW_LOG_KEEP=0
  local f="$LOG_DIR/off.log"
  printf 'old\n' > "$f"; rotate_log off
  assert_empty "$(cat "$f")" "log truncated"
  assert_fails test -f "$f.1"
  PITCREW_LOG_KEEP=2
  rm -f "$f"
}

test_rotation_does_not_create_an_empty_generation() {
  # nothing was written last run; keeping a blank .1 would push a useful one out
  PITCREW_LOG_KEEP=2
  local f="$LOG_DIR/empty.log"
  : > "$f"; rotate_log empty
  assert_fails test -f "$f.1"
  rm -f "$f"
}

# ── supervision ─────────────────────────────────────────────────────────────

test_is_off_by_default() {
  _reset; PITCREW_RESTART=0
  local i; for ((i = 0; i < 20; i++)); do _tick 10; done
  assert_eq "$RESTARTS" 0 "nothing restarts unless asked"
}

test_waits_for_the_backoff_before_the_first_attempt() {
  # restarting the instant a crash is seen races the crash itself: a service
  # dying during boot would be relaunched into the same failure immediately
  _reset
  _tick 0
  assert_eq "$RESTARTS" 0 "first sighting only schedules"
  _tick 1
  assert_eq "$RESTARTS" 0 "still inside the backoff"
  _tick 5
  assert_eq "$RESTARTS" 1 "restarted once the delay elapsed"
}

test_backoff_grows_with_each_attempt() {
  _reset
  local delays=() before after
  local a
  for a in 1 2 3; do
    before=$SNAP_NOW_S
    _tick 0                                  # schedules
    while [ "$RESTARTS" -lt "$a" ]; do _tick 1; [ $(( SNAP_NOW_S - before )) -gt 60 ] && break; done
    delays+=( $(( SNAP_NOW_S - before )) )
  done
  # 2s, then 4s, then 8s — each attempt waits longer than the last
  assert_eq "${#delays[@]}" 3 "three attempts observed"
  [ "${delays[1]}" -gt "${delays[0]}" ] || _t_bad "second delay ${delays[1]}s not longer than first ${delays[0]}s"
  [ "${delays[2]}" -gt "${delays[1]}" ] || _t_bad "third delay ${delays[2]}s not longer than second ${delays[1]}s"
}

test_gives_up_after_the_attempt_budget() {
  # a service crashing on a syntax error must not be relaunched forever; the
  # log you need would be buried under a thousand identical boot attempts
  _reset
  local i; for ((i = 0; i < 200; i++)); do _tick 5; done
  assert_eq "$RESTARTS" "$PITCREW_RESTART_MAX" "stops at the budget"
  assert_eq "${RESTART_GAVEUP[$C]:-}" 1 "marked as given up"
  assert_match "$(plain "$TOAST")" 'keeps crashing' "and says so"
}

test_a_manual_restart_clears_a_give_up() {
  _reset
  local i; for ((i = 0; i < 200; i++)); do _tick 5; done
  assert_eq "${RESTART_GAVEUP[$C]:-}" 1 "given up first"
  supervise_clear "$C"
  assert_empty "${RESTART_GAVEUP[$C]:-}" "give-up cleared"
  RESTARTS=0
  for ((i = 0; i < 20; i++)); do _tick 5; done
  assert_ne "$RESTARTS" 0 "supervision resumes after an explicit retry"
}

test_staying_up_earns_the_budget_back() {
  # without this a service that crashes once a week eventually exhausts its
  # attempts and stops being restarted at all
  _reset
  _tick 0; _tick 5
  assert_eq "$RESTARTS" 1 "crashed and restarted"
  SNAP_STATE=([$C]=up)
  _tick 1;  assert_eq "${RESTART_N[$C]:-0}" 1 "counter held while only briefly up"
  _tick 120
  assert_eq "${RESTART_N[$C]:-0}" 0 "counter cleared after a healthy stretch"
}

test_a_starting_component_is_left_alone() {
  # mid-boot is not a crash; restarting here would make a slow service
  # impossible to start at all
  _reset
  SNAP_STATE=([$C]=starting)
  local i; for ((i = 0; i < 50; i++)); do _tick 5; done
  assert_eq "$RESTARTS" 0 "no restart while starting"
}

test_a_stopped_component_is_left_alone() {
  # `down` means you stopped it on purpose; the supervisor must not fight you
  _reset
  SNAP_STATE=([$C]=down)
  local i; for ((i = 0; i < 50; i++)); do _tick 5; done
  assert_eq "$RESTARTS" 0 "no restart when deliberately stopped"
}

# ── the scope a previous run left behind ────────────────────────────────────
#
# `systemd-run --unit X` refuses while a unit called X is still loaded, and a
# scope outlives the process pitcrew watched whenever that process forked
# something that stays: `./gradlew bootRun` leaves a Gradle daemon in the
# cgroup, so the app exits 1, the component reads as "crashed", and the scope
# goes on holding two gigabytes. Pressing start then failed with
#
#     Failed to start transient scope unit: Unit X.scope was already loaded
#
# inside the log file, which arrived as one more crash and no explanation.

_systemctl_calls() { # run $1 with systemctl stubbed → CALLS, one per line
  CALLS=""
  # shellcheck disable=SC2317
  systemctl() {
    CALLS+="$* "
    case "$*" in
      *is-active*) return "$STUB_ACTIVE" ;;
    esac
    return 0
  }
  HAS_SYSTEMD=1 SESSION=proj
  eval "$1"
  unset -f systemctl
}

test_a_scope_that_outlived_its_process_is_cleared_before_the_next_start() {
  STUB_ACTIVE=0                      # is-active says yes: the daemon is still in it
  _systemctl_calls 'scope_reclaim be-api && CLEARED=yes'
  assert_eq "${CLEARED:-no}" "yes" "it reports that there was something to clear"
  assert_match "$CALLS" 'stop proj-be-api\.scope' "the leftover scope is stopped"
  assert_match "$CALLS" 'reset-failed proj-be-api\.scope' "and the name is released"
  CLEARED=""
}

test_a_scope_whose_processes_ignore_sigterm_is_killed_rather_than_left() {
  # Still active after `stop` means the name is still taken, and every later
  # start would fail with the same opaque message.
  STUB_ACTIVE=0
  _systemctl_calls 'scope_reclaim be-api'
  assert_match "$CALLS" 'kill --signal=SIGKILL proj-be-api\.scope' "SIGKILL is the backstop"
}

test_nothing_is_stopped_when_there_is_no_leftover_scope() {
  STUB_ACTIVE=1                      # is-active says no
  _systemctl_calls 'scope_reclaim be-api || NOTHING=yes'
  assert_eq "${NOTHING:-no}" "yes" "it says so rather than claiming a clean-up"
  assert_not_match "$CALLS" 'stop ' "a component that is not running is not stopped"
  NOTHING=""
}

test_without_systemd_there_is_no_scope_to_reclaim() {
  CALLS=""
  # shellcheck disable=SC2317
  systemctl() { CALLS+="$* "; }
  HAS_SYSTEMD=0 SESSION=proj
  scope_reclaim be-api && _t_bad "it claimed to clear a scope on a box with no systemd"
  assert_empty "$CALLS" "and did not shell out to systemctl to find that out"
  unset -f systemctl
}

trap 'rm -rf "$LOG_DIR"' EXIT
run_tests
