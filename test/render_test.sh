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

# Kept so a test can stand in for the terminal and then hand the real one
# back, without re-sourcing the library over the running suite's state.
REAL_TTY_SIZE=$(declare -f _tty_size)

_render_at() { # $1 cols, $2 lines → FRAME, stderr into RENDER_ERR
  local tmp; tmp=$(mktemp)
  # PITCREW_COLS/LINES, not COLUMNS/LINES: the renderer deliberately treats the
  # shell's own COLUMNS as untrustworthy (bash never updates it after a
  # resize), so pinning a size for a test is what the pitcrew-owned pair is for
  PITCREW_COLS=$1 PITCREW_LINES=$2 TERM_DIRTY=1
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

# ── the viewport ───────────────────────────────────────────────────────────
# The frame is a function of the terminal size, so a wrong size is not a
# cosmetic problem: every row is built to a width that does not exist, and the
# terminal (auto-wrap is off) silently guillotines the difference.

test_a_stale_COLUMNS_never_beats_the_real_terminal() {
  # THE resize bug. bash sets COLUMNS for itself and never updates it, so
  # after a window resize it holds the OLD width — and the dashboard used to
  # prefer it over asking the terminal. A 150-column frame went on being
  # painted into an 84-column window: "frontend" showed as "f", the second
  # column was cut mid-cell, and the key hints stopped at whatever cap
  # straddled the edge.
  local saved_c=${COLUMNS:-} saved_l=${LINES:-}
  _tty_size() { TTY_W=84; TTY_H=27; }        # a terminal, which CI does not have
  COLUMNS=150 LINES=30
  PITCREW_COLS="" PITCREW_LINES="" TERM_DIRTY=1
  term_size
  assert_eq "$TERM_W" 84 "the terminal wins over a stale COLUMNS"
  assert_eq "$TERM_H" 27 "in both directions"
  eval "$REAL_TTY_SIZE"                      # put the real one back
  COLUMNS=$saved_c LINES=$saved_l
}

test_the_environment_is_the_fallback_when_there_is_no_terminal() {
  # a piped run, a recorded session, CI. `tput` does not fail without a tty,
  # it cheerfully answers 80 — which is why it may only be asked when one is
  # actually there.
  local saved_c=${COLUMNS:-} saved_l=${LINES:-}
  _tty_size() { TTY_W=""; TTY_H=""; }        # nothing to ask
  COLUMNS=137 LINES=41
  PITCREW_COLS="" PITCREW_LINES="" TERM_DIRTY=1
  term_size
  assert_eq "$TERM_W" 137 "COLUMNS is used when no terminal can be asked"
  assert_eq "$TERM_H" 41  "and LINES with it"
  eval "$REAL_TTY_SIZE"
  COLUMNS=$saved_c LINES=$saved_l
}

test_an_explicit_size_pins_the_frame() {
  PITCREW_COLS=99 PITCREW_LINES=33 TERM_DIRTY=1
  term_size
  assert_eq "$TERM_W" 99 "PITCREW_COLS pins the width"
  assert_eq "$TERM_H" 33 "PITCREW_LINES pins the height"
}

test_a_nonsense_size_never_reaches_the_layout() {
  # a tty being torn down really does report 0x0, and a zero width becomes a
  # negative column width and a frame full of printf errors
  PITCREW_COLS=0 PITCREW_LINES=0 TERM_DIRTY=1
  term_size
  [ "$TERM_W" -ge 20 ] || _t_bad "0 columns survived as $TERM_W"
  [ "$TERM_H" -ge 4 ]  || _t_bad "0 rows survived as $TERM_H"
}

# ── overflow: hidden ───────────────────────────────────────────────────────

test_an_overlong_row_is_cut_not_left_to_the_terminal() {
  # the guard under everything else: whatever the layout gets wrong, the frame
  # that reaches the terminal fits it
  local long
  printf -v long '%bkeep%b %s' "$RED" "$RESET" "$(printf 'x%.0s' {1..200})"
  fit_line "$long" 20
  local vis; vis=$(plain "${R//$'\e[K'/}")
  assert_eq "${#vis}" 20 "cut to the budget"
  assert_match "$vis" '^keep' "from the right end, not the left"
  assert_match "$R" $'\e\[0m' "and the open colour is closed"
}

test_clipping_counts_columns_not_bytes() {
  # colour is invisible, so it cannot cost columns — an escape-heavy row would
  # otherwise be cut to a fraction of the width it deserves
  local painted="" i
  for ((i = 0; i < 20; i++)); do painted+="${RED}a${RESET}"; done
  fit_line "$painted" 12
  local vis; vis=$(plain "${R//$'\e[K'/}")
  assert_eq "${#vis}" 12 "twenty colour changes still spend twelve columns"
}

test_a_row_that_fits_is_returned_untouched() {
  local row="${GREEN}ok${RESET}"
  fit_line "$row" 40
  assert_eq "$R" "$row" "no reassembly, no stray reset"
}

test_the_frame_is_clipped_even_when_the_layout_is_wrong() {
  # simulate the resize bug: lay the frame out for a wide terminal, then paint
  # it into a narrow one. Nothing may exceed the narrow width.
  _render_at 160 30
  local wide=$FRAME line vis
  fit_frame "$wide" 84 30
  while IFS= read -r line; do
    vis=$(plain "${line//$'\e[K'/}")
    [ "${#vis}" -le 84 ] || _t_bad "a mislaid row survived at ${#vis} columns"
  done <<< "$FIT"
}

# ── breakpoints ────────────────────────────────────────────────────────────

test_the_breakpoints_shed_columns_in_priority_order() {
  # narrower and narrower: the error count goes first, then CPU, then RAM —
  # and the name and the port, which are the irreducible content of the row,
  # never go at all
  local w
  for w in 200 160 120 90 60 46 38 30 24; do
    _render_at "$w" 30
    local body; body=$(plain "$FRAME")
    assert_match "$body" 'both'   "the app name survives at ${w} columns"
    assert_match "$body" ':19801' "and so does the port"
  done
  _render_at 200 30; assert_eq "$TIER" xl "200 columns is the widest tier"
  _render_at 120 30; assert_eq "$TIER" lg "120 columns keeps two cells"
  _render_at  90 30; assert_eq "$TIER" md "90 columns is one cell with a graph"
  _render_at  46 30; assert_eq "$TIER" sm "46 columns drops the graph"
  _render_at  30 30
  assert_eq "$TIER" xs "30 columns drops columns inside the cell"
  assert_eq "$CELL_ERR" 0 "the error count is the first to go"
}

test_a_wide_window_stops_the_table_growing() {
  # a max-width container: past a point, more terminal must not mean a wider
  # sparkline and a name column halfway across the screen
  _render_at 400 30
  [ "$GRAPH_W" -le "$CELL_MAX_GRAPH_W" ] || _t_bad "graph grew to $GRAPH_W"
  [ "$PREFIX_W" -le "$ROW_PREFIX_MAX_W" ] || _t_bad "name column grew to $PREFIX_W"
}

test_the_role_survives_a_squeezed_name_column() {
  # "backoffice be" cut to 11 columns used to become "backoffice " — the name
  # survived whole and the role, which is what tells the two rows apart, fell
  # off the end
  _row_label "backoffice" "be" 11
  assert_match "$R" 'be$'      "the role is kept"
  assert_match "$R" '^backoff' "and the name is elided instead"
  assert_eq "${#R}" 11 "the column is exactly as wide as it was asked for"
}

# ── the footer sticks to the bottom ────────────────────────────────────────

test_the_key_hints_are_on_the_last_row() {
  # six services in a thirty-row window used to leave the footer floating in
  # the middle of the screen with a third of the terminal blank under it.
  #
  # Both widths matter: in the narrow layout one app is TWO rows, and the row
  # budget used to be checked only once per app — so a window with one row
  # left drew the second component anyway and pushed the hints off the bottom.
  local h w last
  for w in 40 90 160; do
    for h in 40 30 24 18 14 12 10 8 6 5; do
      _render_at "$w" "$h"
      _frame_rows
      assert_eq "$ROWS" "$h" "the frame fills a ${w}x${h} window"
      last=$(plain "$FRAME" | tail -n 1)
      assert_match "$last" 'select' "the key hints are the last row at ${w}x${h}"
    done
  done
}

trap 'err_close; for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$LOG_DIR"' EXIT
test_the_process_tree_renders_in_both_layouts() {
  # It used to be drawn only after the WIDE branch, so under
  # PITCREW_NARROW_AT columns Enter toggled a tree that was never painted —
  # a key that silently did nothing on the terminal width most people use.
  EXPANDED[be-both]=1
  local w body
  for w in 160 90; do
    _render_at "$w" 30
    body=$(plain "$FRAME")
    assert_match "$body" '[├└] [0-9]+ ' "the tree is drawn at ${w} columns"
  done
  unset "EXPANDED[be-both]"
  _render_at 160 30
  body=$(plain "$FRAME")
  assert_not_match "$body" '[├└] [0-9]+ ' "and folds away again"
}

# ── zen mode ────────────────────────────────────────────────────────────────
# Zen answers one question — "is there anything I need to do?" — so the test
# for it is about what DISAPPEARS. Each of these plants a state and re-renders
# rather than re-collecting, because collect_frame would overwrite it.

_all_up() { local c; for c in "${PITCREW_COMPS[@]}"; do SNAP_STATE[$c]=up; done; }

test_zen_hides_what_is_fine_and_keeps_what_is_not() {
  _render_at 150 40
  _all_up; SNAP_STATE[be-beonly]=crashed
  ZEN=1; build_frame
  local body; body=$(plain "$FRAME")
  assert_match     "$body" 'beonly' "the crashed app stays"
  assert_not_match "$body" 'feonly' "a healthy one does not"
  assert_match     "$body" 'zen'    "and the title says which mode you are in"
  ZEN=0
}

test_zen_keeps_what_you_marked_even_when_it_is_healthy() {
  # the focus half of the same switch: mark the app you are working on, press
  # z, and you get that app plus anything that breaks — nothing else
  _render_at 150 40
  _all_up
  MARKED[be-feonly]=1
  ZEN=1; build_frame
  local body; body=$(plain "$FRAME")
  assert_match     "$body" 'feonly' "the marked app is what you are focused on"
  assert_not_match "$body" 'beonly' "the rest is still gone"
  MARKED=(); ZEN=0
}

test_zen_with_nothing_wrong_says_so_rather_than_going_blank() {
  _render_at 150 40
  _all_up
  ZEN=1; build_frame
  assert_match "$(plain "$FRAME")" 'nothing needs you' "an empty zen screen is the answer, not a bug"
  ZEN=0
}

test_zen_sheds_chrome_but_never_the_way_out() {
  _render_at 150 40
  _all_up; SNAP_STATE[be-beonly]=crashed
  ZEN=1; build_frame
  local body; body=$(plain "$FRAME")
  assert_not_match "$body" 'CPU'              "the gauges are not what you came for"
  assert_not_match "$body" '● up  ◐ starting' "nor the legend"
  assert_match     "$body" 'q  quit'          "but the way out is always readable"
  assert_match     "$body" 'leave zen'        "and so is the way back"
  ZEN=0
}

test_zen_still_fits_the_terminal_in_both_directions() {
  # foot= changes in zen, and every past row-accounting slip scrolled the alt
  # screen a row at a time until the display never recovered
  local h w
  _render_at 160 40
  _all_up; SNAP_STATE[be-beonly]=crashed
  ZEN=1
  for h in 6 8 10 14 24 40; do
    PITCREW_COLS=160 PITCREW_LINES=$h TERM_DIRTY=1; build_frame
    _frame_rows
    assert_eq "$ROWS" "$h" "zen at 160x${h} occupies exactly ${h} rows"
  done
  local line vis
  for w in 40 80 110 160; do
    PITCREW_COLS=$w PITCREW_LINES=24 TERM_DIRTY=1; build_frame
    while IFS= read -r line; do
      vis=$(plain "${line//$'\e[K'/}")
      [ "${#vis}" -le "$w" ] || _t_bad "zen at ${w} cols drew a ${#vis}-char row"
    done <<< "$FRAME"
  done
  ZEN=0
}

run_tests
