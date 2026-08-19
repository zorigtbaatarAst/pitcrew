#!/usr/bin/env bash
# The frame renderer, across terminal sizes.
#
# Both bugs this file exists for were invisible in normal use and cost real
# debugging time: a variable referenced only on the narrow-terminal path
# (unbound → the dashboard died at every width), and an `exec` redirection that
# silently sent the whole process's stderr to /dev/null, which is what made the
# first one so hard to see.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

LOG_DIR=$(mktemp -d)
PIDS=()
for c in "${PITCREW_COMPS[@]}"; do
  printf 'boot\nERROR seeded\n' > "$LOG_DIR/$c.log"
  sleep 300 & PIDS+=($!)
  echo $! > "$LOG_DIR/$c.pid"
done

_render_at() { # $1 cols, $2 lines → FRAME, stderr into RENDER_ERR
  local tmp; tmp=$(mktemp)
  COLUMNS=$1 LINES=$2 TERM_DIRTY=1
  { collect_frame; build_frame; } 2>"$tmp"
  RENDER_ERR=$(cat "$tmp"); rm -f "$tmp"
}

test_renders_at_every_terminal_size() {
  local w
  for w in 60 80 90 110 132 200 400; do
    _render_at "$w" 40
    assert_empty "$RENDER_ERR" "stderr at ${w} cols"
    [ "${#FRAME}" -gt 200 ] || _t_bad "frame at ${w} cols is only ${#FRAME} chars — did it bail out?"
  done
}

test_no_row_exceeds_the_terminal_width() {
  # the dashboard turns off auto-wrap, so an over-long row does not wrap — it
  # silently truncates and the repaint line count goes wrong
  local w line vis
  for w in 60 90 132; do
    _render_at "$w" 40
    while IFS= read -r line; do
      vis=$(plain "${line//$'\e[K'/}")
      [ "${#vis}" -le "$w" ] || _t_bad "a row at ${w} cols is ${#vis} chars wide"
    done <<< "$FRAME"
  done
}

test_the_empty_state_has_no_table_header_over_it() {
  # column headers above an empty table are pure noise, and they were the worst
  # thing about the first screen a new user sees
  local saved=$LOG_DIR
  LOG_DIR=$(mktemp -d)
  _render_at 150 40
  local body; body=$(plain "$FRAME")
  assert_match     "$body" 'nothing is running yet' "empty state shown"
  assert_not_match "$body" 'port   graph'           "no column header over it"
  rm -rf "$LOG_DIR"; LOG_DIR=$saved
}

test_the_empty_state_is_centred() {
  local saved=$LOG_DIR
  LOG_DIR=$(mktemp -d)
  _render_at 150 40
  local l lead
  while IFS= read -r l; do
    case "$l" in *"nothing is running yet"*) ;; *) continue ;; esac
    lead=$(plain "${l//$'\e[K'/}"); lead=${lead%%[! ]*}
    # 22 chars centred in 150 starts at 64
    [ "${#lead}" -ge 62 ] && [ "${#lead}" -le 66 ] || \
      _t_bad "empty-state line starts at column ${#lead}, expected ~64"
  done <<< "$FRAME"
  rm -rf "$LOG_DIR"; LOG_DIR=$saved
}

test_narrow_terminals_switch_to_one_component_per_row() {
  _render_at 80 40
  local narrow_body; narrow_body=$(plain "$FRAME")
  assert_match "$narrow_body" 'service' "narrow header names the component column"
  _render_at 160 40
  local wide_body; wide_body=$(plain "$FRAME")
  assert_match "$wide_body" 'backend' "wide header keeps the two-column split"
  assert_match "$wide_body" 'frontend' "wide header keeps the two-column split"
}

test_rendering_never_redirects_the_shells_stderr() {
  # `exec {fd}<file 2>/dev/null` applies BOTH redirections to the shell and
  # keeps them, so one careless suppressor silences every later error message
  # in the whole process. That is exactly what happened.
  _render_at 132 40
  local probe; probe=$( { echo "still visible" >&2; } 2>&1 )
  assert_eq "$probe" "still visible" "stderr survives a rendered frame"
}

test_the_empty_state_replaces_a_screen_of_dots() {
  local saved=$LOG_DIR
  LOG_DIR=$(mktemp -d)            # no pidfiles → nothing is running
  _render_at 132 40
  assert_match "$(plain "$FRAME")" 'nothing is running yet' "empty state shown"
  assert_match "$(plain "$FRAME")" 'pitcrew start' "and it says what to do"
  rm -rf "$LOG_DIR"; LOG_DIR=$saved
}

trap 'err_close; for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$LOG_DIR"' EXIT
run_tests
