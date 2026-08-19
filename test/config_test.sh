#!/usr/bin/env bash
# Config loading: the pitcrew_app shorthand, the derived model, and the
# non-fatal sanity checks that catch typos before they become confusing
# silence later.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"
config_validate 2>/dev/null

test_shorthand_populates_the_same_arrays_as_raw_assignment() {
  assert_eq "${PITCREW_BE_PORT[both]}"        "19801" "be port"
  assert_eq "${PITCREW_BE_HEALTH_PATH[both]}" "/health" "health path"
  assert_eq "${PITCREW_URL_PATH[both]}"       "/api"  "url path"
  assert_eq "${PITCREW_WATCH_DIR[be-both]}"   "src/be" "watch dir is keyed by component"
}

test_a_role_exists_only_when_it_has_a_command() {
  assert_ok   app_has_role both   be
  assert_ok   app_has_role both   fe
  assert_ok   app_has_role beonly be
  assert_fails app_has_role beonly fe
  assert_fails app_has_role feonly be
}

test_all_components_is_ordered_and_skips_absent_roles() {
  assert_eq "$(all_components | tr '\n' ' ')" "be-both fe-both be-beonly fe-feonly " "component order"
}

test_component_list_is_cached_for_the_frame_loop() {
  assert_eq "${PITCREW_COMPS[*]}" "be-both fe-both be-beonly fe-feonly" "PITCREW_COMPS"
}

test_ram_caps_are_pre_resolved_to_bytes() {
  # the dashboard divides by this once per component per frame; parsing "2G"
  # there would mean a fork
  assert_eq "${COMP_MAX_B[be-both]}" "$((2 * 1024 ** 3))" "backend cap"
  assert_eq "${COMP_MAX_B[fe-both]}" "$((4 * 1024 ** 3))" "frontend cap"
}

test_session_name_is_filesystem_safe() {
  assert_match "$SESSION" '^[a-z0-9_-]+$' "session slug"
}

# ── validation warns, never dies ────────────────────────────────────────────
_validate_output() { # $1 = extra config lines → the warnings they produce
  local dir; dir=$(mktemp -d)
  { cat "$PITCREW_DIR/test/fixture/pitcrew.config.sh"; printf '%s\n' "$1"; } > "$dir/pitcrew.config.sh"
  ( PITCREW_CFG="$dir/pitcrew.config.sh"
    config_defaults
    ROOT=$dir
    source "$PITCREW_CFG"
    config_finalize "$PITCREW_CFG"
    config_validate 2>&1 ) | sed -e $'s/\x1b\\[[0-9;]*m//g'
  rm -rf "$dir"
}

test_warns_about_an_app_name_typo_in_a_per_app_array() {
  assert_match "$(_validate_output 'PITCREW_BE_PORT[bothh]=9999')" \
    "'bothh' is set in a per-app array but isn't listed" "typo warning"
}

test_warns_about_a_port_used_twice() {
  assert_match "$(_validate_output 'PITCREW_BE_PORT[beonly]=19801')" \
    'port 19801 is used by both' "duplicate port warning"
}

test_warns_about_a_protected_dep_that_is_not_a_dep() {
  assert_match "$(_validate_output 'PITCREW_PROTECTED_DEPS+=(ghost)')" \
    "has 'ghost' which isn't in PITCREW_DEPS" "protected dep warning"
}

test_a_clean_config_produces_no_warnings() {
  assert_empty "$(_validate_output '')" "clean config"
}

run_tests
