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
  # printf's %(...)T, not `date -d`: -d is a GNU extension and BSD date spells
  # it -r, so the fixture built an empty timestamp on macOS and the assertions
  # failed there while passing on Linux. bash 5 has this builtin, and "no GNU
  # coreutils" is a rule this project holds everywhere else.
  # UTC, and labelled as such (+000), so the expected elapsed time is the same
  # number in every timezone the suite might run in.
  local born; TZ=UTC printf -v born '%(%Y%m%d%H%M%S)T' "$1"
  printf 'Node,CreationDate,KernelModeTime,Name,ParentProcessId,ProcessId,UserModeTime,WorkingSetSize\r\n'
  printf 'DESKTOP,%s.123456+000,12000000,java.exe,4242,9100,138000000,2147483648\r\n' "$born"
  printf 'DESKTOP,%s.123456+000,500000,bash.exe,1,4242,1500000,10485760\r\n' "$born"
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

test_the_creation_date_offset_is_applied_not_assumed_to_cancel() {
  # The suffix is minutes east of UTC. A process created at 11:00 UTC+02:00 was
  # created at 09:00 UTC, and reading the digits without the offset would make
  # it look two hours younger than it is.
  local now=1787280000 utc plus2
  TZ=UTC printf -v utc '%(%Y%m%d%H%M%S)T' $(( now - 3600 ))
  local row='Node,CreationDate,KernelModeTime,Name,ParentProcessId,ProcessId,UserModeTime,WorkingSetSize\nD,%s.0%s,0,x.exe,1,2,0,1024\n'
  # shellcheck disable=SC2059  # the format string is built above, on purpose
  local at_utc; at_utc=$(printf "$row" "$utc" "+000" | _wmic_ps_parse "$now" | awk '{print $5}')
  _etime_secs "$at_utc"; local secs_utc=$_ETIME
  # the same wall-clock digits, but two hours east: an EARLIER instant
  local at_plus2; at_plus2=$(printf "$row" "$utc" "+120" | _wmic_ps_parse "$now" | awk '{print $5}')
  _etime_secs "$at_plus2"; local secs_plus2=$_ETIME
  assert_eq "$secs_utc" "3600" "at UTC, an hour old"
  assert_eq "$secs_plus2" "$(( 3600 + 7200 ))" "two hours east is two hours older in UTC terms"
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

test_the_parser_uses_no_gawk_extensions() {
  # It used mktime(), which is GNU-only — and BSD awk does not return zero for
  # an unknown function, it refuses to run the program, so the whole parser
  # produced nothing on macOS. --traditional turns every gawk extension off,
  # which is the closest thing to BSD awk available on a Linux runner.
  command -v gawk >/dev/null 2>&1 || return 0
  awk --traditional 'BEGIN{}' </dev/null 2>/dev/null || return 0

  local now=1787280000 strict plain
  plain=$(_wmic_fixture $(( now - 3725 )) | tr -d '\r' | _wmic_ps_parse "$now")
  awk() { command awk --traditional "$@"; }
  strict=$(_wmic_fixture $(( now - 3725 )) | tr -d '\r' | _wmic_ps_parse "$now")
  unset -f awk

  assert_eq "$strict" "$plain" "identical with every gawk extension disabled"
  assert_match "$strict" '9100 4242' "and it actually produced something"
}

# ── installing on Windows ───────────────────────────────────────────────────
#
# None of this can be RUN here, so these pin the two things that were wrong in
# a way no reading caught: where the installer looks for a python, and what
# `pitcrew-gui` on $PATH actually is. Both were "works on Linux, cannot work on
# Windows", and both showed up as an install that reported success and left
# nothing you could launch.

_ROOT="$PITCREW_DIR"

# pyfind.sh with a chosen uname, so the Windows list can be inspected from here.
_pyfind_as() { # $1 = uname -s output, $2 = expression to run
  bash -c "
    uname() { printf '%s\n' '$1'; }
    . '$_ROOT/gui/pyfind.sh'
    $2"
}

test_the_python_search_looks_where_msys2_actually_keeps_it() {
  # The GTK stack on Windows lives in a mingw PREFIX, and MSYS2's /usr/bin/python3
  # is a different interpreter that will never have gi no matter what you install.
  # Three scripts each carried their own copy of a Unix-only list, so setup.sh
  # skipped the desktop app, gui/install.sh refused to write the shortcut on the
  # grounds that it "would not run", and install-deps.sh reported MISSING
  # immediately after a successful pacman install.
  local out; out=$(_pyfind_as MINGW64_NT-10.0-22631 'pitcrew_python_candidates')
  assert_match "$out" '/ucrt64/bin/python3\.exe'  "the UCRT64 prefix"
  assert_match "$out" '/mingw64/bin/python3\.exe' "the MINGW64 one"
  assert_match "$out" '/c/msys64/'                 "and MSYS2 seen from Git Bash, where /ucrt64 is not mounted"
  assert_not_match "$out" '/opt/homebrew'          "no macOS paths on Windows"
}

test_the_shell_you_opened_beats_any_guess_at_where_msys2_is() {
  # $MINGW_PREFIX is set by the MSYS2 environment the user actually launched,
  # so it is the only thing that finds an MSYS2 installed anywhere but C:\msys64.
  local out; out=$(MINGW_PREFIX=/d/tools/msys/clang64 \
    _pyfind_as MSYS_NT-10.0-22631 'pitcrew_python_candidates | head -1')
  assert_eq "$out" "/d/tools/msys/clang64/bin/python3.exe" "the live prefix comes first"
}

test_every_platform_still_ends_with_something_on_path() {
  # A list of absolute paths is exactly how the interpreter search broke on
  # macOS the first time. Whatever the OS, the last entry has to be a bare name.
  local os
  for os in Linux Darwin MINGW64_NT-10.0-22631; do
    local last; last=$(_pyfind_as "$os" 'pitcrew_python_candidates | tail -1')
    assert_not_match "$last" '^/' "$os: the last resort is not an absolute path"
  done
}

test_only_one_shell_script_knows_where_a_python_might_be() {
  # It was copied into setup.sh, gui/install.sh, gui/install-deps.sh and the
  # GUI test file, and every copy was wrong in the same way. The bug is the
  # copying; this is what stops it coming back.
  #
  # pitcrewgui/platform.py keeps its own list on purpose: it is the RUNTIME
  # seam, in a language that cannot source a bash file, and it answers a
  # different question — which interpreter to re-exec into, not which one to
  # report on. gui_test.sh pins that the two agree about Windows.
  local strays f
  strays=""
  for f in "$_ROOT/setup.sh" "$_ROOT"/gui/*.sh "$_ROOT"/test/*.sh; do
    case "$f" in *pyfind.sh|*windows_test.sh) continue ;; esac
    grep -q '/opt/homebrew/bin/python3' "$f" 2>/dev/null && strays="$strays $f"
  done
  assert_empty "${strays# }" "shell scripts carrying their own python search"
}

test_windows_gets_a_shim_rather_than_a_symlink_for_the_gui_too() {
  # `ln -s` under MSYS writes a COPY unless Developer Mode is on, and a copy of
  # pitcrew-gui cannot find the pitcrewgui/ package it resolves from its own
  # realpath — so `pitcrew-gui` died with ModuleNotFoundError. install.sh had
  # always written a shim for the CLI; gui/install.sh had not.
  local body; body=$(cat "$_ROOT/gui/install.sh")
  assert_match "$body" 'PLATFORM. = windows' "the GUI install branches on Windows before linking"
  assert_match "$body" 'exec .%s/pitcrew-gui' "and writes a shim there"
}

test_the_windows_shortcut_targets_a_real_interpreter() {
  # `target` used to come from a probe that could answer with the bare word
  # "python3", and a .lnk whose TargetPath is "python3" is a shortcut to
  # nothing. pyfind.sh resolves to an absolute path for exactly this reason.
  local body; body=$(cat "$_ROOT/gui/pyfind.sh")
  assert_match "$body" 'command -v' "the candidate is resolved, not used as typed"
  assert_match "$(cat "$_ROOT/gui/install.sh")" 'pythonw\.exe' \
    "and pythonw is preferred, so no console sits behind the app"
}

test_the_windows_install_asks_windows_where_its_own_folders_are() {
  # $APPDATA is a WINDOWS path with backslashes, so `[ -d "$APPDATA/Microsoft/..." ]`
  # tests a filename that cannot exist — the Start Menu was never found and the
  # install gave up. OneDrive also relocates the Desktop on a great many
  # machines. WScript.Shell.SpecialFolders is right on all of them.
  local body code
  body=$(cat "$_ROOT/gui/install.sh")
  assert_match "$body" 'SpecialFolders'        "the folders come from Windows"
  assert_match "$body" '"Programs", "Desktop"' "Start Menu AND Desktop"
  # Comments may still explain why; code may not do it.
  code=$(grep -v '^ *#' "$_ROOT/gui/install.sh" | tr '\n' ' ')
  assert_not_match "$code" 'APPDATA' "no path assembled out of \$APPDATA"
}

run_tests
