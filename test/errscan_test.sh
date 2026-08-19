#!/usr/bin/env bash
# The error radar. It holds a live fd per log and reads only new bytes, which
# means it has two failure modes a naive `tail | grep` never had: a line torn
# across two frames, and a log truncated under it by a restart.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

LOG_DIR=$(mktemp -d)
PITCREW_COMPS=(be-both)
LOG="$LOG_DIR/be-both.log"
: > "$LOG"

_reset() {
  err_close; ERR_COUNT=(); ERR_LINES=(); ERR_PID=(); ERR_PARTIAL=(); ERR_FD=()
  rm -f "$LOG_DIR/.errmark"; : > "$LOG"; SNAP_PID[be-both]=111
}

test_counts_only_matching_lines() {
  _reset
  printf 'starting up\nERROR boom\nall fine\nERROR again\n' >> "$LOG"
  err_scan
  assert_eq "${ERR_COUNT[be-both]}" 2 "matched lines"
  assert_match "${ERR_LINES[be-both]}" 'ERROR boom' "keeps the line, not just a count"
}

test_is_incremental_across_frames() {
  _reset
  printf 'ERROR one\n' >> "$LOG"; err_scan
  assert_eq "${ERR_COUNT[be-both]}" 1 "first frame"
  printf 'quiet\n' >> "$LOG"; err_scan
  assert_eq "${ERR_COUNT[be-both]}" 1 "non-matching line does not increment"
  printf 'ERROR two\n' >> "$LOG"; err_scan
  assert_eq "${ERR_COUNT[be-both]}" 2 "second frame adds only the new one"
}

test_a_line_torn_across_frames_is_counted_once() {
  # the writer has not finished the line when the frame reads it; counting the
  # fragment now would both miscount and corrupt the stored text
  _reset
  printf 'ERR' >> "$LOG"; err_scan
  assert_eq "${ERR_COUNT[be-both]}" 0 "half a line is not a match yet"
  printf 'OR torn\n' >> "$LOG"; err_scan
  assert_eq "${ERR_COUNT[be-both]}" 1 "counted once, when complete"
  assert_match "${ERR_LINES[be-both]}" 'ERROR torn' "reassembled intact"
}

test_a_restart_resets_the_count_and_reopens_the_log() {
  # launch_process truncates the log on restart; a changed pid is the fork-free
  # signal for that. Without it the fd sits past EOF forever and the radar goes
  # permanently blind.
  _reset
  printf 'ERROR old\n' >> "$LOG"; err_scan
  assert_eq "${ERR_COUNT[be-both]}" 1 "before restart"
  : > "$LOG"; SNAP_PID[be-both]=222              # restarted
  printf 'ERROR fresh\n' >> "$LOG"; err_scan
  assert_eq "${ERR_COUNT[be-both]}" 1 "count restarts from the new run"
  assert_not_match "${ERR_LINES[be-both]}" 'old' "previous run's lines are dropped"
}

test_an_untouched_log_is_not_reopened() {
  # 12 idle logs cost ~7ms/frame if each is read anyway; the mtime marker is
  # what keeps an idle dashboard free
  _reset
  printf 'ERROR one\n' >> "$LOG"; err_scan
  local fd_before=${ERR_FD[be-both]}
  err_scan; err_scan
  assert_eq "${ERR_FD[be-both]}" "$fd_before" "fd is reused, not reopened"
  assert_eq "${ERR_COUNT[be-both]}" 1 "no double counting"
}

test_a_custom_pattern_is_honoured() {
  _reset
  PITCREW_ERROR_PATTERN='panic:|FATAL'
  printf 'ERROR ignored by this pattern\npanic: real\n' >> "$LOG"; err_scan
  assert_eq "${ERR_COUNT[be-both]}" 1 "only the configured pattern counts"
  PITCREW_ERROR_PATTERN='ERROR|FATAL|Exception|UnhandledRejection'
}

test_a_project_that_was_never_started_scans_cleanly() {
  # a clean checkout has no .pitcrew/logs at all; `pitcrew status` must not
  # greet a new user with an error about a marker file
  local saved=$LOG_DIR
  LOG_DIR=$(mktemp -d)/never-created
  local out; out=$(err_scan 2>&1)
  assert_empty "$out" "no output for a missing log dir"
  LOG_DIR=$saved
}

trap 'err_close; rm -rf "$LOG_DIR"' EXIT
run_tests
