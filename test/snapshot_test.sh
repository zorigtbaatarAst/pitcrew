#!/usr/bin/env bash
# The collector: /proc parsing, pidfile trust, and the state machine those
# feed. These are the functions where a wrong answer is silent rather than
# loud — a mis-parsed field just shows a plausible number.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

test_local_address_recognition() {
  # /proc/net/tcp writes each 32-bit word little-endian, so 127.0.0.1 is
  # 0100007F. Matching only loopback-reachable binds is what keeps "up"
  # meaning what /dev/tcp/127.0.0.1 used to mean.
  assert_ok   _addr_is_local 00000000                          # 0.0.0.0
  assert_ok   _addr_is_local 0100007F                          # 127.0.0.1
  assert_ok   _addr_is_local 00000000000000000000000000000000  # ::
  assert_ok   _addr_is_local 00000000000000000000000001000000  # ::1
  assert_ok   _addr_is_local 0000000000000000FFFF00000100007F  # ::ffff:127.0.0.1
  assert_fails _addr_is_local 0101A8C0                         # 192.168.1.1 — not loopback
  assert_fails _addr_is_local DEADBEEF
}

test_pid_stat_matches_what_ps_reports() {
  [ "$PITCREW_COLLECTOR" = proc ] || return 0     # /proc-only assertion
  # Measure a SLEEPING process, not this shell. Comparing $$ against ps is
  # flaky by construction: the test shell allocates between the two reads, so
  # an exact match fails intermittently for a reason that has nothing to do
  # with the parser. A quiescent process's RSS does not move, which keeps the
  # assertion exact — and exact is the point, since the bug this guards
  # against (reading stat's rss instead of statm's) was only 0.6% off.
  sleep 30 & local p=$!
  sleep 0.3
  _pid_stat "$p"
  local ps_rss; ps_rss=$(( $(ps -o rss= -p "$p" | tr -d ' ') * 1024 ))
  assert_eq "$_P_RSS" "$ps_rss" "RSS must agree with ps to the byte"
  assert_match "$_P_JIFF" '^[0-9]+$' "jiffies is a number"
  assert_eq "$_P_CMD" "sleep" "comm"
  kill "$p" 2>/dev/null
}

test_pid_stat_survives_a_comm_containing_spaces_and_parens() {
  [ "$PITCREW_COLLECTOR" = proc ] || return 0
  # /proc/<pid>/stat field 2 can contain anything, so the parser splits on the
  # LAST ") " — a naive whitespace split silently shifts every later field.
  # comm comes from the executable's NAME, not argv[0], so `exec -a` will not
  # do it — the binary itself has to be called something awkward.
  local d; d=$(mktemp -d)
  cp "$(command -v sleep)" "$d/we ) ird"
  "$d/we ) ird" 30 & local p=$!
  sleep 0.4
  _pid_stat "$p"
  assert_match "$_P_CMD"  'ird' "comm with spaces and parens is recovered"
  assert_match "$_P_JIFF" '^[0-9]+$' "later fields did not shift"
  assert_match "$_P_RSS"  '^[0-9]+$' "rss still parses"
  kill "$p" 2>/dev/null; rm -rf "$d"
}

test_pidfile_from_a_previous_boot_is_not_trusted() {
  # A pidfile that survived a reboot names a pid that is either gone or now
  # belongs to something unrelated. Reporting it as "crashed" is wrong AND
  # sticky — the file outlives every reboot.
  [ -d /proc/1 ] || return 0
  local d; d=$(mktemp -d); LOG_DIR=$d
  echo 999999 > "$d/be-both.pid"

  touch -t 200001010000 "$d/be-both.pid"
  _read_pidfile be-both
  assert_empty "$PIDF" "pre-boot pidfile is discarded"

  touch "$d/be-both.pid"                 # now, i.e. after this boot
  _read_pidfile be-both
  assert_eq "$PIDF" "999999" "post-boot pidfile is kept even though the pid is dead"

  # a LIVE pid is always trusted, whatever the file's mtime claims
  echo $$ > "$d/be-both.pid"; touch -t 200001010000 "$d/be-both.pid"
  _read_pidfile be-both
  assert_eq "$PIDF" "$$" "a live pid is trusted regardless of mtime"
  rm -rf "$d"
}

# ── the state machine, driven from a fabricated snapshot ────────────────────
_state_of() { # $1 comp, $2 port-open?, $3 pid, $4 health
  SNAP_PORT_OPEN=(); SNAP_PID=(); SNAP_HEALTH=(); SNAP_STATE=()
  local port=${PITCREW_PORT[$1]:-}
  [ "$2" = open ] && SNAP_PORT_OPEN[$port]=1
  SNAP_PID[$1]=$3
  # Health is per COMPONENT now: it was a backend-only idea only because there
  # used to be exactly one backend per app.
  SNAP_HEALTH[$1]=$4
  _snapshot_states
  printf '%s' "${SNAP_STATE[$1]}"
}

test_state_machine() {
  assert_eq "$(_state_of be-both open   $$      UP)"   up       "port open + healthy"
  assert_eq "$(_state_of be-both open   $$      DOWN)" starting "port open, health not ready yet"
  assert_eq "$(_state_of be-both closed $$      UP)"   starting "alive but not listening yet"
  assert_eq "$(_state_of be-both closed 999999  UP)"   crashed  "pidfile recorded, process gone"
  assert_eq "$(_state_of be-both closed ''      UP)"   down     "never started"
  # A health path is a per-COMPONENT question now, not a backend one: a worker
  # with an actuator asks it and a frontend without one does not. _health_poll
  # records UP for anything with no path configured, which is what makes an
  # open port enough on its own.
  assert_eq "$(_state_of fe-both open   $$      UP)"   up       "no health path means port-open is up"
  assert_eq "$(_state_of fe-both open   $$      DOWN)" starting "and any role with one is believed"
}

test_a_port_held_by_something_else_is_not_reported_as_ours() {
  # This is how a project appears to be running when it is not: pitcrew decides
  # "up" from the port, so two projects that share one (8080 and 3000 are not
  # rare) each see the other's service and count it in their own summary.
  assert_eq "$(_state_of be-both open 999999 UP)" external "port open, our pid dead"
  assert_eq "$(_state_of be-both open ''     UP)" external "port open, never started by us"
  assert_eq "$(_state_of be-both open $$     UP)" up       "port open and it IS ours"
}

test_unconfigured_role_is_n_a_not_down() {
  SNAP_STATE=()
  # beonly has no frontend at all — it must not be counted as something that
  # is down and could be started
  assert_eq "$(comp_state fe-beonly)" "n/a" "absent role"
}

test_elapsed_time_parses_the_way_ps_prints_it() {
  # The macOS path. A Linux developer never runs it by accident, so it has to be
  # pinned here or it breaks on someone else's machine — ps prints elapsed as
  # [[dd-]hh:]mm:ss and every field is optional.
  # Sets _ETIME rather than printing: $(...) here would be a fork per component
  # per frame, on the one collector that can least afford it.
  _etime_secs 45;         assert_eq "$_ETIME" "45"     "seconds only"
  _etime_secs 01:30;      assert_eq "$_ETIME" "90"     "mm:ss"
  _etime_secs 2:03:04;    assert_eq "$_ETIME" "7384"   "hh:mm:ss"
  _etime_secs 3-04:05:06; assert_eq "$_ETIME" "273906" "dd-hh:mm:ss"
  # Leading zeros must not be read as octal — 08 and 09 are the classic break.
  _etime_secs 00:08:09;   assert_eq "$_ETIME" "489"    "leading zeros are decimal"
}

test_a_start_time_needs_a_boot_time_to_mean_anything() {
  # /proc/<pid>/stat counts from BOOT, so without btime the number is not an
  # epoch at all. Better to report nothing than a timestamp from 1970.
  [ -r /proc/stat ] || return 0
  assert_ne "$PITCREW_BTIME" "0" "btime was read at load"
  # assert_ok takes a COMMAND, not a value and a label — see harness.sh.
  assert_ok test "$PITCREW_BTIME" -gt 1000000000
}

# ── idleness that outlives the process that measured it ─────────────────────
#
# The interesting case is the one where pitcrew was NOT watching. Carrying a
# timestamp across that gap would be a guess; carrying it across only when the
# cumulative CPU counter proves nothing happened is a measurement. These pin
# that distinction, because getting it wrong puts a busy service on a list of
# things it is safe to stop.

# These stand on shared globals that the other tests in this file also read, so
# the fixture saves and the cleanup restores. Assertions record rather than
# abort, so a failing test still reaches its cleanup.
_idle_fixture() { # $1 = the record to write → a LOG_DIR containing it
  SAVED_LOG_DIR=$LOG_DIR
  SAVED_COMPS=("${PITCREW_COMPS[@]}")
  SAVED_PIDS=("${!SNAP_PID[@]}"); SAVED_PID_VALS=("${SNAP_PID[@]}")
  IDLE_DIR=$(mktemp -d)
  LOG_DIR=$IDLE_DIR
  printf '%s\n' "$1" > "$IDLE_DIR/.idle"
  SNAP_NOW_S=2000
  _IDLE_RESTORED=0
  SNAP_IDLE_SINCE=()
  SNAP_PID=([be-both]=4242)
  _JIFF_TREE_PREV=([be-both]=1000)
}

_idle_cleanup() {
  rm -rf "$IDLE_DIR"
  LOG_DIR=$SAVED_LOG_DIR
  PITCREW_COMPS=("${SAVED_COMPS[@]}")
  SNAP_PID=()
  local i
  for i in "${!SAVED_PIDS[@]}"; do SNAP_PID[${SAVED_PIDS[i]}]=${SAVED_PID_VALS[i]}; done
  SNAP_IDLE_SINCE=()
  _IDLE_RESTORED=0
}

test_an_idle_clock_is_carried_forward_when_the_counter_proves_it() {
  # 100 seconds passed unobserved; the CPU counter did not move. Nothing ran,
  # whether or not anyone was there to see it.
  _idle_fixture "be-both=$PITCREW_COLLECTOR 4242 1000 1500 1900"
  _idle_restore
  assert_eq "${SNAP_IDLE_SINCE[be-both]:-}" "1500" "the old timestamp survives"
  _idle_cleanup
}

test_an_idle_clock_is_dropped_when_the_counter_moved() {
  # Same gap, but the counter advanced by 100s of CPU over 100s of wall clock:
  # that service was pegged, and calling it idle would be a lie.
  _idle_fixture "be-both=$PITCREW_COLLECTOR 4242 1000 1500 1900"
  _JIFF_TREE_PREV=([be-both]=$(( 1000 + 100 * 100 )))
  _idle_restore
  assert_empty "${SNAP_IDLE_SINCE[be-both]:-}" "it worked while we were away"
  _idle_cleanup
}

test_a_little_counter_movement_is_still_idle() {
  # A JVM at rest still ticks over on GC and timers. A threshold of zero would
  # mean nothing is ever idle, which makes the whole feature useless.
  _idle_fixture "be-both=$PITCREW_COLLECTOR 4242 1000 1500 1900"
  _JIFF_TREE_PREV=([be-both]=$(( 1000 + 100 )))    # ~1% of one core over the gap
  _idle_restore
  assert_eq "${SNAP_IDLE_SINCE[be-both]:-}" "1500" "under the threshold is still quiet"
  _idle_cleanup
}

test_a_restarted_process_starts_its_idle_clock_again() {
  # The counter belongs to a PID. A new process with a new pid inherits none of
  # the old one's quietness, however identical the component name is.
  _idle_fixture "be-both=$PITCREW_COLLECTOR 9999 1000 1500 1900"
  _idle_restore
  assert_empty "${SNAP_IDLE_SINCE[be-both]:-}" "different pid, no history"
  _idle_cleanup
}

test_a_record_from_the_other_collector_is_discarded() {
  # /proc counts jiffies and `ps` counts centiseconds. Comparing one against
  # the other is comparing different units, so the record is refused rather
  # than converted on a guess.
  _idle_fixture "be-both=somethingelse 4242 1000 1500 1900"
  _idle_restore
  assert_empty "${SNAP_IDLE_SINCE[be-both]:-}" "different units, no history"
  _idle_cleanup
}

test_a_counter_that_went_backwards_is_discarded() {
  _idle_fixture "be-both=$PITCREW_COLLECTOR 4242 5000 1500 1900"
  _idle_restore      # current counter (1000) is BELOW the recorded 5000
  assert_empty "${SNAP_IDLE_SINCE[be-both]:-}" "a counter cannot decrease without a restart"
  _idle_cleanup
}

test_saving_never_overwrites_history_with_nothing() {
  # The first snapshot of every run happens before any component has an idle
  # clock. Writing then would destroy exactly what the next run wants to read.
  _idle_fixture "be-both=$PITCREW_COLLECTOR 4242 1000 1500 1900"
  SNAP_IDLE_SINCE=()
  PITCREW_COMPS=(be-both)
  idle_save_now
  assert_match "$(cat "$IDLE_DIR/.idle")" '1500' "the record is still there"
  SNAP_IDLE_SINCE=([be-both]=1900)
  idle_save_now
  assert_match "$(cat "$IDLE_DIR/.idle")" '1900' "and a real save does replace it"
  _idle_cleanup
}

# ── the children map the portable collector walks ───────────────────────────
#
# On Windows that map has TWO sources — the process table, and the POSIX tree
# MSYS publishes in its own /proc, which the Windows one cannot express (see
# pf_extra_kids). Neither the reading nor the merging can be exercised on a
# machine without /proc/<pid>/winpid, so the half that can be — what a link
# does to the map, and what the walk does with a bad one — is pinned here.

test_a_link_is_added_once_and_never_to_itself() {
  _PS_KIDS=([100]="101 ")
  _pf_kid_link 101 100                  # already known from the process table
  _pf_kid_link 102 100                  # only MSYS knows this one
  _pf_kid_link 100 100                  # a pid that is its own parent
  assert_eq "${_PS_KIDS[100]}" "101 102 " "the new child, and no duplicate"
  assert_empty "${_PS_KIDS[102]:-}" "and nothing invented for a leaf"
}

test_a_cycle_in_the_children_map_does_not_hang_the_frame() {
  # Two sources means a pid recycled between them can have A under B while B is
  # under A. Unguarded that is not a wrong number on screen, it is a dashboard
  # that never draws another frame — so the walk has to survive it rather than
  # trust the map it was handed.
  _PS_KIDS=([10]="11 " [11]="12 " [12]="10 ")
  _TREE=(); _walk_ps_tree 10
  assert_eq "${_TREE[*]}" "10 11 12" "every pid once, and the walk returns"
}

test_nothing_is_added_to_the_map_off_windows() {
  # pf_extra_kids is a hook, and a hook that quietly did something on Linux
  # would be a fork budget and a process tree nobody went looking for.
  # On Windows it is SUPPOSED to add links, and this box's own MSYS processes
  # are what it would add — so there the question is a different one.
  [ "$PITCREW_OS" = windows ] && return 0
  _PS_KIDS=([200]="201 ")
  pf_extra_kids
  assert_eq "${_PS_KIDS[200]}" "201 " "the map is exactly what ps said"
  assert_eq "${#_PS_KIDS[@]}" "1" "and no other parent gained one"
}

run_tests
