#!/usr/bin/env bash
# The portable path — everything pitcrew does differently (or has to do
# without) when it is not on Linux.
#
# The macOS collector is the one part of this tool that its author cannot run
# every day, which is exactly why it needs tests that DO run every day. So the
# suite forces PITCREW_COLLECTOR=ps and drives the same code macOS drives:
# the ps sweep, the CPU-time parser, the loopback filter, the boot marker and
# the timeout fallback. What is genuinely OS-specific underneath (vm_stat,
# kern.boottime) is asserted on its contract — a total that is a number and a
# boot instant that is in the past — not on its text.
set -u

# Must be set BEFORE lib/00-platform.sh is sourced: the collector is chosen at
# load time, once, on purpose.
export PITCREW_FORCE_COLLECTOR=ps

source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

test_the_forced_collector_is_the_portable_one() {
  assert_eq "$PITCREW_COLLECTOR" "ps" "PITCREW_FORCE_COLLECTOR must select the ps collector"
}

test_os_is_recognised() {
  assert_match "$PITCREW_OS" '^(linux|macos|bsd|windows|other)$' "PITCREW_OS"
  assert_match "$PITCREW_NCPU" '^[0-9]+$' "core count"
  [ "$PITCREW_NCPU" -ge 1 ] || _t_bad "core count must be at least 1, got $PITCREW_NCPU"
}

# ── cumulative CPU time ─────────────────────────────────────────────────────
# The two platforms spell the same field differently, and getting this wrong
# does not throw — it just makes every CPU% plausible and wrong.
test_cpu_time_parses_both_platforms_spellings() {
  _cputime_cs "0:01.23";     assert_eq "$_CS" "123"      "macOS M:SS.cc"
  _cputime_cs "00:00:01";    assert_eq "$_CS" "100"      "Linux HH:MM:SS"
  _cputime_cs "1:00.00";     assert_eq "$_CS" "6000"     "one minute"
  _cputime_cs "01:00:00";    assert_eq "$_CS" "360000"   "one hour"
  _cputime_cs "2-03:00:00";  assert_eq "$_CS" "$(( (2*24+3) * 3600 * 100 ))" "days- prefix"
  _cputime_cs "0:00.09";     assert_eq "$_CS" "9"        "centiseconds are not dropped"
  # A leading zero must not be read as octal — 08 and 09 are the values that
  # turn an arithmetic expansion into a fatal error mid-frame.
  _cputime_cs "00:08:09";    assert_eq "$_CS" "$(( (8*60+9) * 100 ))" "08/09 are decimal, not octal"
}

test_unparseable_cpu_time_is_zero_not_an_error() {
  # ps output we did not anticipate must cost a zero in one cell, never take
  # down the frame loop it is called from.
  _cputime_cs "";        assert_eq "$_CS" "0" "empty"
  _cputime_cs "-";       assert_eq "$_CS" "0" "a dash"
  _cputime_cs "??:??";   assert_eq "$_CS" "0" "junk"
}

# ── which listening sockets count as "up" ───────────────────────────────────
test_only_loopback_reachable_binds_count() {
  # The /proc path counts only loopback-reachable binds, so the ps path has to
  # agree — otherwise "up" means one thing on Linux and another on macOS, and
  # a service bound to the LAN address alone reports as serving localhost.
  assert_ok _ps_addr_is_local '*:8080'
  assert_ok _ps_addr_is_local '0.0.0.0:8080'
  assert_ok _ps_addr_is_local '127.0.0.1:8080'
  assert_ok _ps_addr_is_local '[::]:8080'
  assert_ok _ps_addr_is_local '[::1]:8080'
  assert_fails _ps_addr_is_local '192.168.1.5:8080'
  assert_fails _ps_addr_is_local '10.0.0.2:8080'
}

# ── the ps sweep itself ─────────────────────────────────────────────────────
test_the_ps_collector_measures_a_real_process() {
  local d; d=$(mktemp -d)
  local saved=$LOG_DIR; LOG_DIR=$d
  sleep 30 & local p=$!
  echo "$p" > "$d/be-both.pid"

  snapshot
  assert_eq "${SNAP_PID[be-both]}" "$p"        "pidfile is read"
  assert_match "${SNAP_RSS[be-both]}" '^[0-9]+$' "RSS is a number"
  [ "${SNAP_RSS[be-both]}" -gt 0 ] || _t_bad "RSS of a live process must be > 0"
  assert_match "${SNAP_CPU[be-both]}" '^[0-9]+$' "CPU is a number"
  assert_eq "${SNAP_PROC_CMD[$p]}" "sleep"     "comm, basenamed (macOS reports a full path)"
  assert_eq "${SNAP_STATE[be-both]}" "starting" "alive, nothing listening yet"

  # Second frame: now there is a previous sample, so CPU% is a real delta over
  # the interval rather than the lifetime average `ps -o pcpu` would give.
  snapshot
  assert_match "${SNAP_CPU[be-both]}" '^[0-9]+$' "CPU after a second sample"
  [ "${SNAP_CPU[be-both]}" -le $((100 * PITCREW_NCPU)) ] \
    || _t_bad "a sleeping process cannot use ${SNAP_CPU[be-both]}% of $PITCREW_NCPU cores"

  kill "$p" 2>/dev/null
  LOG_DIR=$saved; rm -rf "$d"
}

test_the_ps_collector_walks_the_whole_process_tree() {
  # RAM has to be the tree's, not the wrapper's: launch_process wraps every
  # service in a bash that costs ~3MB, so measuring only the root pid would
  # report every JVM in the project as a rounding error.
  local d; d=$(mktemp -d)
  local saved=$LOG_DIR; LOG_DIR=$d
  bash -c 'sleep 30 & sleep 30' & local root=$!
  echo "$root" > "$d/be-both.pid"
  sleep 0.5

  snapshot
  local n; n=$(printf '%s\n' ${SNAP_PIDS[be-both]} | wc -l)
  [ "$n" -ge 2 ] || _t_bad "tree walk found $n pid(s) under a parent with children"
  case " ${SNAP_PIDS[be-both]} " in
    " $root "*) ;;
    *) _t_bad "the root pid must come first in the tree" ;;
  esac

  kill "$root" 2>/dev/null
  pkill -P "$root" 2>/dev/null
  LOG_DIR=$saved; rm -rf "$d"
}

test_a_dead_pid_yields_no_meters_rather_than_stale_ones() {
  local d; d=$(mktemp -d)
  local saved=$LOG_DIR; LOG_DIR=$d
  echo 999999 > "$d/be-both.pid"
  snapshot
  assert_empty "${SNAP_RSS[be-both]}" "no RSS for a process that is gone"
  assert_eq "${SNAP_STATE[be-both]}" "crashed" "pidfile recorded, process gone"
  LOG_DIR=$saved; rm -rf "$d"
}

# ── system gauges ───────────────────────────────────────────────────────────
test_system_memory_is_readable_on_this_platform() {
  # ram_preflight refuses to warn without this number, so a platform where it
  # comes back empty silently loses the "this stack does not fit" check.
  sys_gauges
  assert_match "${SYS_MEM_TOTAL_KB:-}" '^[0-9]+$' "total RAM"
  [ "${SYS_MEM_TOTAL_KB:-0}" -gt 0 ] || _t_bad "total RAM must be > 0"
  assert_match "${SYS_MEM_USED_KB:-}" '^[0-9]+$' "used RAM"
  [ "${SYS_MEM_USED_KB:-0}" -le "${SYS_MEM_TOTAL_KB:-0}" ] \
    || _t_bad "used RAM (${SYS_MEM_USED_KB}) exceeds total (${SYS_MEM_TOTAL_KB})"
}

test_system_cpu_gauge_stays_in_range() {
  snapshot; snapshot
  assert_match "${SYS_CPU_PCT:-}" '^[0-9]+$' "system CPU"
  [ "${SYS_CPU_PCT:-0}" -le 100 ] || _t_bad "system CPU gauge reads ${SYS_CPU_PCT}%"
}

# macOS's own memory numbers, checked against captured vm_stat output so the
# parser is covered on a Linux box too — it is the one piece of this file that
# cannot be exercised any other way off a Mac.
_VM_STAT_SAMPLE='Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                65536.
Pages active:                             524288.
Pages inactive:                           262144.
Pages speculative:                         32768.
Pages throttled:                               0.
Pages wired down:                         131072.
Pages purgeable:                           16384.
"Translation faults":                  987654321.
Pages copy-on-write:                     1234567.
Pages zero filled:                      12345678.
Pages reactivated:                        123456.
Pages purged:                              12345.
File-backed pages:                        131072.
Anonymous pages:                          655360.
Pages stored in compressor:                65536.
Pages occupied by compressor:              32768.
Pageins:                                 1234567.
Pageouts:                                   1234.
Swapins:                                       0.
Swapouts:                                      0.'

test_vm_stat_parses_real_macos_output() {
  local kb; kb=$(printf '%s\n' "$_VM_STAT_SAMPLE" | _vm_stat_avail_kb)
  # free + speculative + purgeable + file-backed = 245760 pages × 16KiB
  assert_eq "$kb" "$(( (65536 + 32768 + 16384 + 131072) * 16384 / 1024 ))" "available KiB"
}

test_vm_stat_without_file_backed_pages_still_parses() {
  # older macOS does not print that line at all — an absent count is zero, not
  # a parse failure that blanks the whole gauge
  local kb; kb=$(printf '%s\n' "$_VM_STAT_SAMPLE" | grep -v 'File-backed' | _vm_stat_avail_kb)
  assert_eq "$kb" "$(( (65536 + 32768 + 16384) * 16384 / 1024 ))" "available KiB without file-backed"
}

test_vm_stat_garbage_yields_nothing_rather_than_a_wrong_number() {
  local kb; kb=$(printf 'not vm_stat output\n' | _vm_stat_avail_kb)
  assert_empty "$kb" "no page size means no answer, not a zero that reads as 'full'"
}

# ── boot marker ─────────────────────────────────────────────────────────────
test_boot_marker_is_in_the_past() {
  # Everything about discarding pre-reboot pidfiles rests on this file's mtime.
  # A marker stamped in the FUTURE would discard every pidfile ever written and
  # report a perfectly healthy stack as down.
  [ -n "$PITCREW_BOOT_MARKER" ] || return 0        # platform has none — trusted, documented
  [ -e "$PITCREW_BOOT_MARKER" ] || { _t_bad "boot marker $PITCREW_BOOT_MARKER does not exist"; return 0; }
  local now; now=$(mktemp)
  [ "$PITCREW_BOOT_MARKER" -nt "$now" ] && _t_bad "boot marker is newer than now"
  rm -f "$now"
}

test_pidfile_written_after_boot_is_kept() {
  local d; d=$(mktemp -d)
  local saved=$LOG_DIR; LOG_DIR=$d
  echo 999999 > "$d/be-both.pid"                   # written just now, pid already dead
  _read_pidfile be-both
  assert_eq "$PIDF" "999999" "a pidfile from this boot is trusted even when the pid is gone"
  LOG_DIR=$saved; rm -rf "$d"
}

# ── timeout fallback ────────────────────────────────────────────────────────
# macOS ships no `timeout`. port_open is built on it, so without a working
# fallback every port check either hangs or reports closed.
_pf_timeout_fallback() { # the no-coreutils implementation, whatever this box has
  local secs=$1 rc=0 pid killer
  shift
  "$@" & pid=$!
  { sleep "$secs"; kill -TERM "$pid"; } 2>/dev/null & killer=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
  return $rc
}

test_timeout_fallback_returns_the_commands_own_status() {
  assert_ok    _pf_timeout_fallback 5 true
  assert_fails _pf_timeout_fallback 5 false
}

test_timeout_fallback_actually_kills_an_overrun() {
  local t0=$SECONDS
  _pf_timeout_fallback 1 sleep 20 && _t_bad "an overrun must not report success"
  [ $(( SECONDS - t0 )) -lt 10 ] || _t_bad "the deadline did not fire — took $(( SECONDS - t0 ))s"
}

test_pf_timeout_is_defined_whichever_binary_exists() {
  declare -F pf_timeout >/dev/null || _t_bad "pf_timeout is not defined"
  assert_ok    pf_timeout 5 true
  assert_fails pf_timeout 5 false
}

# ── slugs ───────────────────────────────────────────────────────────────────
test_slugs_collapse_runs_of_dashes() {
  # BSD sed does not understand \+ in a BRE, so this used to depend on which
  # sed was installed — and the slug is a file name AND a systemd unit name.
  assert_eq "$(project_slug 'My  Project')" "my-project" "spaces collapse to one dash"
  assert_eq "$(project_slug '--weird--name--')" "weird-name" "leading/trailing/inner runs"
  assert_eq "$(project_slug 'plain')" "plain" "an already-clean name is untouched"
}

run_tests
