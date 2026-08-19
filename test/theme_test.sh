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
run_tests
