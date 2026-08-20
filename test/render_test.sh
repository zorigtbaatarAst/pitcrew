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
  for w in 40 60 80 90 110 132 200 400; do
    _render_at "$w" 40
    assert_empty "$RENDER_ERR" "stderr at ${w} cols"
    [ "${#FRAME}" -gt 200 ] || _t_bad "frame at ${w} cols is only ${#FRAME} chars — did it bail out?"
  done
}

test_no_row_exceeds_the_terminal_width() {
  # the dashboard turns off auto-wrap, so an over-long row does not wrap — it
  # silently truncates and the repaint line count goes wrong
  local w line vis
  for w in 40 50 60 90 132; do
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

test_the_filter_narrows_the_list() {
  FILTER=beonly
  _render_at 150 40
  local body; body=$(plain "$FRAME")
  assert_match     "$body" 'beonly' "the matching app is shown"
  assert_not_match "$body" 'feonly' "a non-matching app is not"
  FILTER=nosuchthing
  _render_at 150 40
  assert_match "$(plain "$FRAME")" 'nothing matches' "and an empty result says so"
  FILTER=""
}

test_a_filter_beats_the_empty_state() {
  # once you are filtering you are choosing what to START — hiding the rows
  # behind "nothing is running yet" is exactly backwards
  local saved=$LOG_DIR
  LOG_DIR=$(mktemp -d)
  FILTER=both
  _render_at 150 40
  local body; body=$(plain "$FRAME")
  assert_match     "$body" 'both'                   "rows are shown"
  assert_not_match "$body" 'nothing is running yet' "empty state stands down"
  FILTER=""
  rm -rf "$LOG_DIR"; LOG_DIR=$saved
}

test_sorting_reorders_the_view() {
  # collect ONCE, then re-render: _render_at re-collects, which would overwrite
  # the RSS this test plants
  _render_at 150 40
  SORT=name; build_frame
  local by_name="${VIEW_APPS[*]}"
  SNAP_RSS[be-beonly]=999999999            # make one app the heaviest
  SORT=ram;  build_frame
  assert_eq "${VIEW_APPS[0]}" "beonly" "heaviest sorts first"
  SORT=name; build_frame
  assert_eq "${VIEW_APPS[*]}" "$by_name" "and name order is restored"
  SORT=name
}

test_marks_drive_what_the_action_keys_act_on() {
  SEL=0; MARKED=()
  _render_at 150 40
  target_set
  assert_eq "${#TARGETS[@]}" 1 "with nothing marked it is the selection"
  MARKED[be-both]=1; MARKED[be-beonly]=1
  target_set
  assert_eq "${#TARGETS[@]}" 2 "with marks it is the marked set"
  assert_match "${TARGETS[*]}" 'be-both'   "…"
  assert_match "${TARGETS[*]}" 'be-beonly' "…"
  MARKED=()
}

# ── the frame has to fit the window in BOTH directions ─────────────────────
# Auto-wrap is off and the frame is painted from the home position, so one row
# too many scrolls the alt screen and every repaint after it lands a row off.
# The display never recovers from that, and it is invisible in a big terminal.
_frame_rows() { # → ROWS, the screen rows $FRAME occupies
  local line; ROWS=0
  while IFS= read -r line; do ROWS=$((ROWS + 1)); done <<< "$FRAME"
}

test_the_frame_never_outgrows_the_terminal_height() {
  local h
  for h in 40 30 24 20 16 14 12 10 8 6 4; do
    _render_at 160 "$h"
    assert_empty "$RENDER_ERR" "stderr at ${h} rows"
    _frame_rows
    [ "$ROWS" -le "$h" ] || _t_bad "a ${h}-row terminal got a ${ROWS}-row frame"
  done
}

test_a_short_window_still_shows_services() {
  # a 14-row pane used to render the header, the gauges, the deps, the legend
  # and ZERO service rows — every row spent on chrome
  local h
  for h in 20 14 10; do
    _render_at 160 "$h"
    local rows; rows=$(plain "$FRAME" | grep -c '▐' || true)
    [ "$rows" -ge 1 ] || _t_bad "no service rows at ${h} rows — the chrome ate the screen"
  done
}

test_a_short_window_sheds_chrome_not_content() {
  _render_at 160 14
  local body; body=$(plain "$FRAME")
  assert_not_match "$body" '● up  ◐ starting' "the legend goes first"
  assert_match     "$body" 'CPU'              "but the gauges only fold, they do not vanish"
  _render_at 160 10
  body=$(plain "$FRAME")
  assert_not_match "$body" 'CPU'      "under a dozen rows even the gauges go"
  assert_match     "$body" 'q  quit'  "the key hints never do"
}

test_a_very_narrow_terminal_drops_the_graph_not_the_numbers() {
  # under ~50 columns the sparkline pushes the port and the RAM figure off the
  # right edge, where the terminal eats them without a trace. The graph is the
  # part you can do without.
  _render_at 45 40
  local body; body=$(plain "$FRAME")
  assert_match     "$body" ':19801'  "the port survives"
  assert_match     "$body" 'both'    "and so does the app name"
  assert_not_match "$body" 'graph'   "the graph column is gone, header and all"
}

test_deps_wrap_instead_of_running_off_the_edge() {
  local saved=("${PITCREW_DEPS[@]}") d
  PITCREW_DEPS=(mongo redis kafka postgres elasticsearch rabbitmq minio)
  for d in "${PITCREW_DEPS[@]}"; do SNAP_DEP[$d]=up; done
  _render_at 90 40
  local body; body=$(plain "$FRAME")
  assert_match "$body" 'minio' "the last dep is still on screen"
  local line vis
  while IFS= read -r line; do
    vis=$(plain "${line//$'\e[K'/}")
    [ "${#vis}" -le 90 ] || _t_bad "the deps line is ${#vis} chars in a 90-col terminal"
  done <<< "$FRAME"
  PITCREW_DEPS=("${saved[@]}")
}

test_the_selection_cannot_scroll_off_the_screen() {
  # the list used to simply stop at the bottom: ↓ moved a selection you could
  # no longer see, and `a`/`s` then acted on an invisible row
  SEL=3; ROW_OFF=0
  _render_at 160 6
  local body; body=$(plain "$FRAME")
  local selapp=${VIEW[3]#??-}
  assert_match "$body" "$selapp" "the selected app is on screen"
  assert_match "$body" 'above'   "and the frame says what it scrolled past"
  SEL=0; ROW_OFF=0
  _render_at 160 6
  assert_match "$(plain "$FRAME")" 'below' "scrolled back to the top, it says what is under it"
  SEL=0; ROW_OFF=0
}

trap 'err_close; for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$LOG_DIR"' EXIT
run_tests
