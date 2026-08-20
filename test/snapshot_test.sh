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
  local app=${1#??-} role=${1:0:2} port
  if [ "$role" = be ]; then port=${PITCREW_BE_PORT[$app]:-}; else port=${PITCREW_FE_PORT[$app]:-}; fi
  [ "$2" = open ] && SNAP_PORT_OPEN[$port]=1
  SNAP_PID[$1]=$3
  SNAP_HEALTH[$app]=$4
  _snapshot_states
  printf '%s' "${SNAP_STATE[$1]}"
}

test_state_machine() {
  assert_eq "$(_state_of be-both open   $$      UP)"   up       "port open + healthy"
  assert_eq "$(_state_of be-both open   $$      DOWN)" starting "port open, health not ready yet"
  assert_eq "$(_state_of be-both closed $$      UP)"   starting "alive but not listening yet"
  assert_eq "$(_state_of be-both closed 999999  UP)"   crashed  "pidfile recorded, process gone"
  assert_eq "$(_state_of be-both closed ''      UP)"   down     "never started"
  # the frontend has no health path, so an open port alone is enough
  assert_eq "$(_state_of fe-both open   $$      DOWN)" up       "no health path means port-open is up"
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
  assert_eq "$(_etime_secs 45)"          "45"     "seconds only"
  assert_eq "$(_etime_secs 01:30)"       "90"     "mm:ss"
  assert_eq "$(_etime_secs 2:03:04)"     "7384"   "hh:mm:ss"
  assert_eq "$(_etime_secs 3-04:05:06)"  "273906" "dd-hh:mm:ss"
  # Leading zeros must not be read as octal — 08 and 09 are the classic break.
  assert_eq "$(_etime_secs 00:08:09)"    "489"    "leading zeros are decimal"
}

test_a_start_time_needs_a_boot_time_to_mean_anything() {
  # /proc/<pid>/stat counts from BOOT, so without btime the number is not an
  # epoch at all. Better to report nothing than a timestamp from 1970.
  [ -r /proc/stat ] || return 0
  assert_ne "$PITCREW_BTIME" "0" "btime was read at load"
  # assert_ok takes a COMMAND, not a value and a label — see harness.sh.
  assert_ok test "$PITCREW_BTIME" -gt 1000000000
}

run_tests
