#!/usr/bin/env bash
# How the numbers are drawn, and choosing it.
#
# The bug this file mostly exists for was visible in a screenshot and invisible
# in the code: a service holding its RAM steady put every sample at the window
# maximum, so every cell drew full height in the hottest colour and the graph
# became a solid red lump. It was not "wrong" by any assertion that existed —
# it just stopped carrying information the moment a service was busy.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

PREF=$(mktemp -u)                      # a path, not a file: nothing saved yet
PITCREW_RENDER_FILE=$PREF

_series() { # $1 first value, $2 step, $3 count → SERIES
  local v=$1 step=$2 n=$3 i
  SERIES=""
  for ((i = 0; i < n; i++)); do SERIES+="$(( v + i * step )) "; done
}

_cells() { # $1 rendered spark → CELLS, the glyphs with no colour
  CELLS=$(plain "$1")
}

# The glyph assertions below are about block characters, so the style has to
# be pinned — the preference tests in this same file change it.
_blocks() { PITCREW_GRAPH=block; }

# ── the red lump ───────────────────────────────────────────────────────────

test_a_steady_service_does_not_saturate_the_graph() {
  _blocks
  _series 1060003840 0 40                       # rock steady at ~1011M
  spark "$SERIES" 24 67108864 "$C_OK" range
  _cells "$R"
  assert_not_match "$CELLS" '████' "a flat series must not draw as a solid block"
  # and it is drawn as ONE height, because nothing happened
  local uniq; uniq=$(printf '%s' "$CELLS" | fold -w1 | sort -u | tr -d '\n')
  assert_eq "${#uniq}" 1 "a flat series is a flat line, not a texture"
}

test_the_same_series_on_the_old_absolute_scale_still_saturates() {
  _blocks
  # the contrast, asserted: this is what `scale cap` means and why it is not
  # the default any more
  _series 1060003840 0 40
  spark "$SERIES" 24 67108864 "" abs
  _cells "$R"
  assert_match "$CELLS" '████' "absolute scaling puts a steady service at the top"
}

test_a_leak_still_climbs() {
  _blocks
  # the whole point of keeping history — the fix must not flatten THIS
  _series 600000000 12000000 40
  spark "$SERIES" 24 67108864 "$C_OK" range
  _cells "$R"
  assert_match "${CELLS:0:1}" '[▁▂]' "it starts low"
  assert_eq "${CELLS: -1}" '█' "and ends at the top"
}

test_sampling_noise_is_not_amplified_into_a_mountain() {
  _blocks
  # scaling to the window's own range, with no floor under the span, turns a
  # 300K wobble on a 1G service into a full-height sawtooth
  local i
  SERIES=""
  for ((i = 0; i < 40; i++)); do SERIES+="$(( 1060003840 + i % 5 * 100000 )) "; done
  spark "$SERIES" 24 67108864 "$C_OK" range
  _cells "$R"
  assert_not_match "$CELLS" '[▆▇█]' "a fraction of a percent must not reach the top"
}

test_a_stopped_service_leaves_a_gap_not_a_line() {
  _blocks
  _series 0 0 40
  spark "$SERIES" 12 67108864 "$C_OK" range
  _cells "$R"
  assert_eq "$CELLS" '▁▁▁▁▁▁▁▁▁▁▁▁' "zero samples are the empty baseline"
}

test_the_graph_takes_its_colour_from_the_cap_not_the_height() {
  _blocks
  # once height means "movement", height cannot also mean "close to the cap" —
  # so the colour carries it, and matches the RAM figure beside it
  _series 1060003840 0 40
  spark "$SERIES" 12 67108864 "$C_CRIT" range
  # a glob, not a regex: an SGR sequence is mostly regex metacharacters
  case "$R" in *"$C_CRIT"*) ;; *) _t_bad "the fixed colour is not in the graph" ;; esac
  # (no negative assertion on the ramp colours here: the hot end of the ramp
  # and the crit colour are the same red in most themes, by design)
  spark "$SERIES" 12 67108864 "" abs
  case "$R" in *"${GRAMP[3]}"*) ;; *) _t_bad "the cool-to-hot ramp is gone from the absolute scale" ;; esac
}

# ── the gauges ─────────────────────────────────────────────────────────────

test_a_gauge_bar_is_filled_in_proportion_to_the_number() {
  bar 25 20
  _cells "$R"
  local filled=${CELLS//[^█]/}
  assert_eq "${#filled}" 5 "25% of twenty cells"
  assert_eq "${#CELLS}" 20 "and the bar is exactly the width asked for"
  bar 0 20;   _cells "$R"; assert_not_match "$CELLS" '█' "0% is empty"
  bar 100 20; _cells "$R"; filled=${CELLS//[^█]/}
  assert_eq "${#filled}" 20 "100% is full"
}

test_the_frame_draws_the_gauges_as_bars_by_default() {
  PITCREW_COLS=140 PITCREW_LINES=40 TERM_DIRTY=1
  PITCREW_GAUGE=bar
  collect_frame; build_frame
  local body; body=$(plain "$FRAME")
  assert_match "$body" 'CPU [█░]' "the CPU gauge is a bar"
  assert_match "$body" 'RAM [█░]' "and so is the RAM gauge"
  PITCREW_GAUGE=graph
  collect_frame; build_frame
  body=$(plain "$FRAME")
  assert_match "$body" 'CPU [▁-█]' "the graph style still draws history"
  PITCREW_GAUGE=bar
}

# ── choosing it ────────────────────────────────────────────────────────────

test_every_setting_offers_only_values_it_understands() {
  local key val
  for key in "${RENDER_KEYS[@]}"; do
    render_values "$key"
    assert_ne "$R" "" "$key has values"
    for val in $R; do
      _render_valid "$key" "$val" || _t_bad "$key=$val is offered but not accepted"
      [ -n "$(render_describe "$key" "$val")" ] || _t_bad "$key=$val has no description"
    done
  done
}

test_a_choice_is_remembered_and_applied() {
  local was=$PITCREW_GRAPH
  rm -f "$PREF"
  render_save graph braille
  render_set  graph braille
  assert_eq "$PITCREW_GRAPH" braille "applied to the running process"
  assert_match "$(cat "$PREF")" 'graph=braille' "and written down"
  # the other settings survive a write of one of them
  assert_match "$(cat "$PREF")" 'scale=' "scale is still in the file"
  assert_match "$(cat "$PREF")" 'gauge=' "gauge too"
  render_set graph "$was"
  rm -f "$PREF"
}

test_a_saved_choice_is_read_back() {
  printf 'graph=bar\nscale=cap\ngauge=graph\n' > "$PREF"
  PITCREW_GRAPH="" PITCREW_GRAPH_SCALE="" PITCREW_GAUGE=""
  PITCREW_GRAPH_ENV="" PITCREW_GRAPH_SCALE_ENV="" PITCREW_GAUGE_ENV=""
  render_resolve
  assert_eq "$PITCREW_GRAPH" bar        "graph came back"
  assert_eq "$PITCREW_GRAPH_SCALE" cap  "scale came back"
  assert_eq "$PITCREW_GAUGE" graph      "gauge came back"
  rm -f "$PREF"
}

test_the_environment_beats_the_saved_choice() {
  printf 'graph=bar\n' > "$PREF"
  PITCREW_GRAPH="" PITCREW_GRAPH_ENV=braille
  render_resolve
  assert_eq "$PITCREW_GRAPH" braille "a one-off run overrides the preference"
  PITCREW_GRAPH_ENV=""
  rm -f "$PREF"
}

test_a_hand_edited_preference_falls_back_to_the_default() {
  # the file is only ever written by us, so a value that is not in the list
  # means someone edited it — draw with something that exists rather than
  # asking the renderer to interpret it
  printf 'graph=rainbow\nscale=sideways\ngauge=hologram\n' > "$PREF"
  PITCREW_GRAPH="" PITCREW_GRAPH_SCALE="" PITCREW_GAUGE=""
  PITCREW_GRAPH_ENV="" PITCREW_GRAPH_SCALE_ENV="" PITCREW_GAUGE_ENV=""
  render_resolve
  assert_eq "$PITCREW_GRAPH" block "graph fell back"
  assert_eq "$PITCREW_GRAPH_SCALE" range "scale fell back"
  assert_eq "$PITCREW_GAUGE" bar "gauge fell back"
  rm -f "$PREF"
}

test_an_invalid_choice_is_refused_not_written() {
  rm -f "$PREF"
  assert_fails render_save graph rainbow
  [ -e "$PREF" ] && _t_bad "a refused choice still wrote the preference file"
  return 0
}

test_every_offered_choice_has_a_swatch() {
  local key val out
  for key in "${RENDER_KEYS[@]}"; do
    render_values "$key"
    for val in $R; do
      out=$(render_swatch "$key=$val")
      assert_match "$out" "$val" "the swatch for $key=$val names it"
      [ ${#out} -gt 20 ] || _t_bad "the swatch for $key=$val drew nothing"
    done
  done
}

test_the_picker_marks_what_is_in_effect() {
  PITCREW_GRAPH=block PITCREW_GRAPH_SCALE=range PITCREW_GAUGE=bar
  local lines; lines=$(render_choices)
  assert_match "$(plain "$(printf '%s' "$lines" | grep '^graph=block')")" '●' "the current value is marked"
  assert_match "$(plain "$(printf '%s' "$lines" | grep '^graph=bar')")"  '○' "the others are not"
  # same contract as the action menu: the key is field one, the label never shows it
  local first; first=$(printf '%s' "$lines" | head -1)
  assert_match "$first" $'^graph=block\t' "key is the first tab-separated field"
}

trap 'rm -f "$PREF"' EXIT
run_tests
