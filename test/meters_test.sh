#!/usr/bin/env bash
# Meters: byte formatting, graph levels, and the sparkline itself — the bits
# that are pure arithmetic and therefore cheap to pin down exactly.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

# visible width, ignoring SGR colour
vwidth() { local p; p=$(plain "$1"); echo "${#p}"; }

test_to_bytes_understands_the_config_suffixes() {
  assert_eq "$(to_bytes 8G)"   "$((8 * 1024 ** 3))"  "8G"
  assert_eq "$(to_bytes 512M)" "$((512 * 1024 ** 2))" "512M"
  assert_eq "$(to_bytes 1024)" "1024"                 "bare bytes"
}

test_human_formats_across_the_G_boundary() {
  human 0;                     assert_eq "$HUMAN" "0M"    "zero"
  human $((512 * 1024**2));    assert_eq "$HUMAN" "512M"  "512M"
  human $((1024 * 1024**2));   assert_eq "$HUMAN" "1.0G"  "exactly 1G"
  human $((1536 * 1024**2));   assert_eq "$HUMAN" "1.5G"  "1.5G"
  human $((1023 * 1024**2));   assert_eq "$HUMAN" "1023M" "just under 1G stays in M"
}

test_level_clamps_and_never_hides_a_live_service() {
  _level 0   100 7; assert_eq "$LVL" 0 "zero is zero"
  _level 100 100 7; assert_eq "$LVL" 7 "full scale"
  _level 200 100 7; assert_eq "$LVL" 7 "over scale is clamped"
  # a service using a sliver of its range must still draw something, or it
  # looks identical to one that is not running at all
  _level 1   100 7; assert_eq "$LVL" 1 "non-zero shows at least one pixel"
  _level 5   0   7; assert_eq "$LVL" 0 "zero max cannot divide"
}

test_pct_color_thresholds() {
  pct_color 0;  assert_eq "$PCOL" "$GREEN"  "idle"
  pct_color 59; assert_eq "$PCOL" "$GREEN"  "just under warn"
  pct_color 60; assert_eq "$PCOL" "$YELLOW" "warn"
  pct_color 84; assert_eq "$PCOL" "$YELLOW" "just under danger"
  pct_color 85; assert_eq "$PCOL" "$RED"    "danger"
}

test_spark_is_exactly_the_requested_width() {
  local h="1 2 3 4 5 6 7 8 9 10"
  PITCREW_GRAPH=block   spark "$h" 12 1; assert_eq "$(vwidth "$R")" 12 "block width"
  PITCREW_GRAPH=braille spark "$h" 12 1; assert_eq "$(vwidth "$R")" 12 "braille width"
  # and when history is shorter than the graph, it pads rather than shrinking
  PITCREW_GRAPH=block   spark "1 2" 20 1; assert_eq "$(vwidth "$R")" 20 "short history still fills"
  PITCREW_GRAPH=block   spark "" 20 1;    assert_eq "$(vwidth "$R")" 20 "empty history still fills"
}

test_spark_colours_each_cell_by_its_own_height() {
  # the ramp runs cool at the bottom to hot at the top, so a climb is legible
  # before you read a number. One hue for the whole series cannot show that.
  PITCREW_GRAPH=block
  spark "1 2 3 4 5 6 7 8" 8 1
  local hues; hues=$(printf '%s' "$R" | grep -oE '\[38;2;[0-9;]+m' | sort -u | wc -l)
  [ "$hues" -ge 3 ] || _t_bad "a rising series used only $hues colour(s); expected a gradient"
  # a flat series is one colour, because every cell is the same height
  spark "5 5 5 5 5 5 5 5" 8 1
  hues=$(printf '%s' "$R" | grep -oE '\[38;2;[0-9;]+m' | sort -u | wc -l)
  assert_eq "$hues" 1 "flat series is a single hue"
}

test_spark_marks_the_newest_sample() {
  PITCREW_GRAPH=block
  spark "1 2 3" 3 1
  assert_match "$R" $'\033\[1m' "newest sample is emboldened"
}

test_spark_run_in_is_a_baseline_not_blank_space() {
  # an empty gap reads as broken; a faint rule reads as an empty chart
  PITCREW_GRAPH=block
  spark "5" 6 1
  assert_match "$(plain "$R")" '^▁▁▁▁▁' "run-in drawn as a floor, not a mid-height rule"
}

test_spark_autoscales_so_shape_survives_the_absolute_value() {
  # the same shape at two wildly different magnitudes must render identically:
  # this is what stopped every service being a flat line against its RAM cap
  PITCREW_GRAPH=block
  spark "10 20 30 40 50 60 70 80" 8 1; local small; small=$(plain "$R")
  spark "1000000 2000000 3000000 4000000 5000000 6000000 7000000 8000000" 8 1
  assert_eq "$(plain "$R")" "$small" "shape is scale-independent"
  assert_match "$small" '[▁▂▃▄▅▆▇█]{8}' "renders block glyphs"
}

test_spark_floor_keeps_a_flat_series_flat() {
  # An idle service must not have its noise amplified to full height by the
  # auto-scale. It also must not vanish: a live-but-tiny value draws the
  # lowest NON-zero glyph, leaving the zero glyph to mean genuinely zero.
  # That distinction is what stops a running service being indistinguishable
  # from a stopped one in braille, where level 0 is a blank cell.
  PITCREW_GRAPH=block
  spark "1000 1000 1000 1000" 4 1000000000
  assert_eq "$(plain "$R")" "▂▂▂▂" "tiny-but-live is the lowest non-zero glyph"
  spark "0 0 0 0" 4 1000000000
  assert_eq "$(plain "$R")" "▁▁▁▁" "actual zero is the zero glyph"
  PITCREW_GRAPH=braille
  spark "0 0 0 0" 2 1000000000
  assert_eq "$(plain "$R")" "⠀⠀" "zero is a blank braille cell"
  spark "1000 1000 1000 1000" 2 1000000000
  assert_ne "$(plain "$R")" "⠀⠀" "a live service is never a blank braille cell"
}

test_braille_table_covers_every_dot_combination() {
  _braille_init
  assert_eq "${#BRAILLE[@]}" 256 "table size"
  assert_eq "${BRAILLE[0]}"  "⠀"  "blank cell"
  assert_eq "${BRAILLE[255]}" "⣿" "all dots"
}

test_history_ring_is_bounded() {
  local c=be-both i
  PITCREW_HISTORY=5
  HIST_MEM[$c]=""; HIST_CPU[$c]=""
  for ((i = 0; i < 20; i++)); do hist_push "$c" "$i" "$i"; done
  local -a s=(${HIST_MEM[$c]})
  assert_eq "${#s[@]}" 5 "ring length"
  assert_eq "${s[-1]}" 19 "newest sample kept"
  assert_eq "${s[0]}"  15 "oldest sample dropped"
}

test_ram_preflight_warns_when_caps_exceed_the_machine() {
  # A cap only protects you if it is smaller than the machine. Sixteen JVMs at
  # the 8G default commit 128G on a 31G box, at which point no cap ever fires
  # and the OOM killer picks the victim instead.
  SYS_MEM_TOTAL_KB=$(( 4 * 1024 * 1024 ))        # pretend 4G of RAM
  COMP_MAX_B[be-both]=$(( 1 * 1024 ** 3 ))
  COMP_MAX_B[fe-both]=$(( 1 * 1024 ** 3 ))
  ram_preflight be-both fe-both
  assert_empty "$RAM_WARN" "2G of caps on a 4G box is fine"
  COMP_MAX_B[be-both]=$(( 8 * 1024 ** 3 ))
  ram_preflight be-both fe-both
  assert_match "$RAM_WARN" 'OOM' "9G of caps on a 4G box is not"
  assert_match "$RAM_WARN" '9.0G' "says how much was committed"
  assert_match "$RAM_WARN" '4.0G' "and what the machine has"
}

run_tests
