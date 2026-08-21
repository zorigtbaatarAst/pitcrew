#!/usr/bin/env bash
# The native Windows platform layer.
#
# There is no Windows in CI and there was none on the machine this was written
# on, so the integration is unverified by construction. What CAN be pinned is
# every place a native tool's output is turned into something pitcrew
# understands — and that is where a port like this actually breaks: a column in
# the wrong order, a unit off by 1024, a `\r` nobody stripped.
#
# So each parser is a pure filter over CAPTURED output, exactly the bargain
# lib/00-platform.sh already strikes with `_vm_stat_avail_kb` for macOS. The
# fixtures below are real formats; if Microsoft changes one, this fails here
# rather than on someone's laptop.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew

# wmic's CSV, as it comes off the wire: CRLF line endings, a header row, and a
# Node column nobody asked for.
_wmic_fixture() { # $1 = process creation epoch
  local born; born=$(date -d "@$1" +%Y%m%d%H%M%S 2>/dev/null) || born=20260820110000
  printf 'Node,CreationDate,KernelModeTime,Name,ParentProcessId,ProcessId,UserModeTime,WorkingSetSize\r\n'
  printf 'DESKTOP,%s.123456+060,12000000,java.exe,4242,9100,138000000,2147483648\r\n' "$born"
  printf 'DESKTOP,%s.123456+060,500000,bash.exe,1,4242,1500000,10485760\r\n' "$born"
}

_netstat_fixture() {
  cat <<'NET'

Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:8080           0.0.0.0:0              LISTENING       9100
  TCP    127.0.0.1:3000         0.0.0.0:0              LISTENING       7300
  TCP    192.168.1.9:139        0.0.0.0:0              LISTENING       4
  TCP    10.0.0.5:52344         52.1.2.3:443           ESTABLISHED     880
  TCP    [::]:8080              [::]:0                 LISTENING       9100
  UDP    0.0.0.0:5353           *:*                                    1200
NET
}

# ── the process table ───────────────────────────────────────────────────────

test_wmic_becomes_exactly_the_columns_the_collector_parses() {
  # The portable collector asks ps for `pid ppid rss time etime comm` and this
  # has to be indistinguishable from that. Nothing downstream is allowed to
  # know which OS filled it in.
  local now=1787280000
  local out; out=$(_wmic_fixture $((now - 3725)) | tr -d '\r' | _wmic_ps_parse "$now")
  local java; java=$(printf '%s' "$out" | sed -n 1p)
  set -- $java
  assert_eq "$1" "9100"       "pid"
  assert_eq "$2" "4242"       "ppid — without it there is no process tree"
  assert_eq "$3" "2097152"    "rss in KiB, from WorkingSetSize in bytes"
  assert_eq "$6" "java.exe"   "comm"
  assert_eq "$(printf '%s\n' "$out" | grep -c .)" "2" "the header row is not a process"
}

test_wmi_cpu_ticks_survive_the_round_trip() {
  # WMI counts CPU in 100-NANOSECOND units. The collector reads centiseconds
  # out of a "[[dd-]hh:]mm:ss.cc" string. Getting this wrong by a factor of
  # 10^5 would show every service pegged, or every service idle.
  local now=1787280000
  local field; field=$(_wmic_fixture $((now - 3725)) | tr -d '\r' | _wmic_ps_parse "$now" \
    | sed -n 1p | awk '{print $4}')
  _cputime_cs "$field"
  # 12000000 kernel + 138000000 user = 150000000 ticks = 15.0 seconds
  assert_eq "$_CS" "1500" "15 seconds of CPU, in centiseconds"
}

test_elapsed_time_comes_out_of_the_wmi_creation_date() {
  # It is local time with a UTC offset appended. mktime reads local time too,
  # so the offset cancels — which is why it is not parsed.
  local now=1787280000
  local field; field=$(_wmic_fixture $((now - 3725)) | tr -d '\r' | _wmic_ps_parse "$now" \
    | sed -n 1p | awk '{print $5}')
  _etime_secs "$field"
  assert_eq "$_ETIME" "3725" "up 1h02m05s"
}

test_a_process_with_no_readable_creation_date_still_reports() {
  # A protected system process answers some WMI fields and not others. Losing
  # its uptime is fine; losing the row would lose a whole subtree.
  local out; out=$(printf 'Node,CreationDate,KernelModeTime,Name,ParentProcessId,ProcessId,UserModeTime,WorkingSetSize\r\nD,,0,System,0,4,0,4096\r\n' \
    | tr -d '\r' | _wmic_ps_parse 1787280000)
  set -- $out
  assert_eq "$1" "4"         "the row survives"
  assert_eq "$5" "00:00:00"  "with an elapsed time of zero rather than a broken field"
}

test_short_or_malformed_rows_are_skipped_not_half_parsed() {
  local out; out=$(printf 'Node,CreationDate\r\ngarbage\r\n' | tr -d '\r' | _wmic_ps_parse 1787280000)
  assert_empty "$out" "nothing recognisable, nothing emitted"
}

# ── ports ───────────────────────────────────────────────────────────────────

test_netstat_yields_only_listening_tcp_sockets() {
  local out; out=$(_netstat_fixture | _netstat_listening_parse | tr '\n' ' ')
  assert_match "$out" '0\.0\.0\.0:8080'   "a wildcard bind"
  assert_match "$out" '127\.0\.0\.1:3000' "a loopback bind"
  assert_match "$out" '\[::\]:8080'       "and the v6 one"
  assert_not_match "$out" '52344'         "an ESTABLISHED connection is not a listener"
  assert_not_match "$out" '5353'          "and neither is UDP"
}

test_the_addresses_netstat_prints_pass_the_collectors_loopback_filter() {
  # "up" has to mean the same thing on every platform: reachable as
  # 127.0.0.1. A bind to the LAN address alone does not serve localhost.
  assert_ok    _ps_addr_is_local "0.0.0.0:8080"
  assert_ok    _ps_addr_is_local "127.0.0.1:3000"
  assert_ok    _ps_addr_is_local "[::]:8080"
  assert_fails _ps_addr_is_local "192.168.1.9:139"
}

test_port_to_pid_matches_the_port_not_a_substring_of_it() {
  # ":80" must not answer for ":8080", which is what a grep would do.
  assert_eq "$(_netstat_fixture | _netstat_port_pid_parse 8080)" "9100" "the owning pid"
  assert_eq "$(_netstat_fixture | _netstat_port_pid_parse 3000)" "7300" "and for another"
  assert_empty "$(_netstat_fixture | _netstat_port_pid_parse 80)" "no listener on 80"
  assert_empty "$(_netstat_fixture | _netstat_port_pid_parse 9999)" "nor on 9999"
}

# ── pids ────────────────────────────────────────────────────────────────────

test_a_pid_is_a_pid_everywhere_but_windows() {
  # The translation exists at exactly one boundary. Anywhere else it must be
  # the identity, or the collector would be looking up the wrong process.
  pf_pid_native 1234
  assert_eq "$NATIVE_PID" "1234" "unchanged off Windows"
}

test_the_windows_translation_falls_back_to_the_pid_it_was_given() {
  # /proc/<pid>/winpid is an MSYS thing. Where it cannot be read the answer has
  # to be the input — degraded, but never a lookup against a pid that belongs
  # to some unrelated process.
  pf_winpid 999999
  assert_eq "$WINPID" "999999" "unmappable pid passes through"
}

# ── honesty ─────────────────────────────────────────────────────────────────

test_windows_never_claims_to_enforce_a_ram_cap() {
  # Job Objects exist; nothing on the command line puts a process in one. The
  # meters look identical whether a cap bites or not, so this must not drift.
  ( PITCREW_OS=windows
    assert_fails _caps_enforced )
}

run_tests
