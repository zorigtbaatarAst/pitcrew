#!/usr/bin/env bash
# Theming: which setting wins, and what each colour depth emits.
#
# This file exists because the whole feature was quietly broken: colours are
# DERIVED at source time, before a project's config has been read, so
# PITCREW_THEME in pitcrew.config.sh — the place the README told people to put
# it — was ignored entirely. Nothing failed; you just silently got the default.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew

PREF=$(mktemp)
PITCREW_THEME_FILE=$PREF

_apply() { # $1 env, $2 config, $3 saved → the resulting "ok" colour
  PITCREW_THEME_ENV=$1
  PITCREW_THEME=$2
  if [ -n "$3" ]; then printf '%s\n' "$3" > "$PREF"; else : > "$PREF"; fi
  theme_load
  printf '%s' "$C_OK"
}

# distinct enough that a mix-up cannot pass by accident
GRUV=$'\e[38;2;184;187;38m'
TOKYO=$'\e[38;2;158;206;106m'
ROSE=$'\e[38;2;49;116;143m'
CATP=$'\e[38;2;166;227;161m'

test_ships_a_set_of_themes() {
  local list; list=$(theme_list | tr '\n' ' ')
  local t
  for t in default tokyonight rosepine gruvbox mono; do
    assert_match "$list" "$t" "theme $t is available"
  done
}

test_a_theme_actually_changes_the_palette() {
  assert_eq "$(_apply gruvbox '' '')"    "$GRUV"  "gruvbox"
  assert_eq "$(_apply tokyonight '' '')" "$TOKYO" "tokyonight"
}

test_precedence_env_beats_project_config() {
  # an env var is a deliberate one-off for this run; it must win
  assert_eq "$(_apply tokyonight gruvbox rosepine)" "$TOKYO" "env wins"
}

test_precedence_project_config_beats_the_saved_preference() {
  # a repo that pins a theme looks the same for everyone who opens it
  assert_eq "$(_apply '' gruvbox rosepine)" "$GRUV" "config beats saved"
}

test_precedence_saved_preference_beats_the_default() {
  # how you like your terminal, remembered across runs
  assert_eq "$(_apply '' '' rosepine)" "$ROSE" "saved beats built-in"
}

test_falls_back_to_the_built_in_palette() {
  assert_eq "$(_apply '' '' '')" "$CATP" "built-in default"
}

test_an_unknown_theme_is_rejected_not_ignored() {
  assert_fails cmd_theme definitely-not-a-theme
}

test_colour_depth_is_detected_and_overridable() {
  ( PITCREW_COLOR=truecolor; PITCREW_COLOR_ENV=truecolor; theme_load
    assert_match "$C_OK" '38;2;' "truecolor emits 24-bit" )
  ( PITCREW_COLOR=16; PITCREW_COLOR_ENV=16; theme_load
    assert_match "$C_OK" $'\033\\[32m' "16-colour falls back to ANSI"
    assert_not_match "$C_OK" '38;2;' "and emits no 24-bit codes" )
  ( PITCREW_COLOR=none; PITCREW_COLOR_ENV=none; theme_load
    assert_empty "$C_OK" "none emits nothing"
    assert_empty "$BOLD" "including attributes" )
}

test_no_color_is_honoured() {
  ( NO_COLOR=1; PITCREW_COLOR=""; PITCREW_COLOR_ENV=""; theme_load
    assert_empty "$C_CRIT" "NO_COLOR wins over any theme" )
}

test_one_theme_file_works_at_every_depth() {
  # a theme sets hex only, so it must survive being rendered as 16-colour
  ( PITCREW_COLOR=16; PITCREW_COLOR_ENV=16; PITCREW_THEME_ENV=gruvbox; theme_load
    assert_match "$C_OK" $'\033\\[32m' "gruvbox still resolves at 16 colours" )
}

# ── what the theme actually reaches ─────────────────────────────────────────
#
# The palette was wired correctly and the BARS still looked the same in every
# theme, which is the bug this section is about. Every theme's ok/warn/crit is
# some green, some amber and some red — that is what those roles mean — so a
# meter painted from them barely moved while the text around it changed
# completely. Bars are drawn from the theme's own graph ramp now, and these
# assert that they are: same shape, different ink, per theme.

_bar_ink() { # $1 theme, $2 pct → the escape the filled part is drawn in
  PITCREW_THEME_ENV=$1 theme_load
  bar "$2" 8
  # Everything up to the first cell, filled or empty. Trimming at █ alone
  # returns the WHOLE bar when nothing is filled, which is a test that passes
  # by comparing two different things.
  printf '%s' "${R%%[█░]*}"
}

test_a_bar_is_drawn_in_the_theme_that_is_loaded() {
  local a b c
  a=$(_bar_ink gruvbox 70); b=$(_bar_ink tokyonight 70); c=$(_bar_ink rosepine 70)
  assert_ne "$a" "$b" "gruvbox and tokyonight do not paint the same bar"
  assert_ne "$b" "$c" "tokyonight and rosepine do not paint the same bar"
  # The one that made this obvious: mono has no hues at all, so a bar drawn
  # from ok/warn/crit came out white at every level.
  PITCREW_THEME_ENV=mono theme_load
  assert_eq "$(_bar_ink mono 20)" $'\e[38;2;90;90;90m' "mono draws a low bar in its darkest grey"
  assert_eq "$(_bar_ink mono 95)" $'\e[38;2;232;232;232m' "and a full one in its lightest"
}

test_the_empty_part_of_a_bar_is_the_themes_baseline() {
  PITCREW_THEME_ENV=gruvbox theme_load
  bar 50 8
  # T_FAINT, the role for a baseline or a placeholder. It used to be DIM over
  # C_MUTED, which is the same near-black whatever the theme.
  assert_match "$R" '38;2;80;73;69' "the track is drawn in T_FAINT"
}

test_ramp_and_status_agree_about_level_and_differ_about_ink() {
  PITCREW_THEME_ENV=rosepine theme_load
  local p
  for p in 0 24; do ramp_color $p; assert_eq "$RCOL" "${GRAMP[0]}" "$p% is the bottom of the ramp"; done
  ramp_color 25; assert_eq "$RCOL" "${GRAMP[1]}" "25% steps up"
  ramp_color 60; assert_eq "$RCOL" "${GRAMP[2]}" "60% is where warn starts"
  ramp_color 85; assert_eq "$RCOL" "${GRAMP[3]}" "85% is the top"
  # Same question, same answer, different ink. The gap is at the BOTTOM of the
  # scale, and that is the point: a status triad has one colour for "fine", so
  # every reading under 60% came out the same green. The ramp has two, which is
  # the difference between a service that is idle and one that is working.
  pct_color 10; ramp_color 10
  assert_eq "$PCOL" "$C_OK"      "a figure at 10% is still the ok colour"
  assert_eq "$RCOL" "${GRAMP[0]}" "the bar beside it is the bottom of the ramp"
  assert_ne "$PCOL" "$RCOL"      "and those are not the same colour"
  # The top of the scale is where they agree, and they should: a palette whose
  # crit and whose hottest ramp step were different reds would be a palette
  # with two reds in it.
  pct_color 90; ramp_color 90
  assert_eq "$PCOL" "$C_CRIT" "a figure at 90% is crit"
}

test_the_picker_is_drawn_in_the_theme_too() {
  # fzf paints its own frame from a palette of its own and was never told about
  # ours, so the menu stayed fzf green whatever the dashboard looked like.
  PITCREW_THEME_ENV=gruvbox theme_load; fzf_colors; local gruv=$FZF_COLORS
  PITCREW_THEME_ENV=tokyonight theme_load; fzf_colors; local tokyo=$FZF_COLORS
  assert_match "$gruv"  'prompt:#83a598' "the prompt is the theme's accent"
  assert_match "$gruv"  'bg\+:#3c3836'   "the selected row is the theme's surface"
  assert_ne    "$gruv"  "$tokyo"         "and it changes with the theme"
  # A colour spec fzf cannot parse is a hard exit, not a dull menu — so the
  # lower depths get a name fzf has always understood rather than hex.
  ( PITCREW_COLOR=none; PITCREW_COLOR_ENV=none; theme_load; fzf_colors
    assert_eq "$FZF_COLORS" bw "NO_COLOR reaches the picker" )
  ( PITCREW_COLOR=16; PITCREW_COLOR_ENV=16; theme_load; fzf_colors
    assert_eq "$FZF_COLORS" 16 "and a 16-colour terminal is not handed 24-bit hex" )
}

test_icons_are_off_unless_asked_for() {
  ( PITCREW_ICONS=unicode; icons_load; assert_empty "$I_JAVA" "no glyphs by default" )
  ( PITCREW_ICONS=nerd;    icons_load
    assert_ne "$I_JAVA" "" "nerd mode has glyphs"
    app_icon_for "./gradlew :sales:backend:bootRun"; assert_eq "$ICON" "$I_JAVA" "gradle → java"
    app_icon_for "npm run dev";                      assert_eq "$ICON" "$I_NODE" "npm → node"
    app_icon_for "python3 -m http.server";           assert_eq "$ICON" "$I_PY"   "python → python"
    app_icon_for "some-unknown-binary";              assert_eq "$ICON" "$I_APP"  "unknown → generic" )
}

trap 'rm -f "$PREF"' EXIT
test_the_language_icon_is_guessed_from_the_start_command() {
  # `*bun*` (the Bun runtime) also matches "bundle", so with the node line
  # first every `bundle exec rails` app came out as a node app. shellcheck had
  # been reporting the shadowing for a while; `make lint` was red for unrelated
  # style noise, so nobody saw it.
  PITCREW_ICONS=1 icons_load
  app_icon_for "cd api && bundle exec rails s"; local ruby=$ICON
  app_icon_for "pnpm dev";                      local node=$ICON
  app_icon_for "npm run dev";                   local npm=$ICON
  app_icon_for "./gradlew bootRun";             local java=$ICON

  assert_eq "$ruby" "$I_RUBY" "bundler is ruby, not node"
  assert_eq "$node" "$I_NODE" "pnpm still resolves (it was a dead pattern)"
  assert_eq "$npm"  "$I_NODE" "and npm is unchanged"
  assert_eq "$java" "$I_JAVA" "gradle still wins over everything"
}

run_tests
