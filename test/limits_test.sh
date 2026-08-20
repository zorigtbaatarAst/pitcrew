#!/usr/bin/env bash
# Per-component RAM caps.
#
# Two numbers for a whole stack is the wrong shape once the stack is not
# uniform, so a cap resolves through three layers. What matters is that they
# resolve in the right ORDER, that everything downstream (the meters, the
# preflight, systemd) reads the SAME number, and that a bad value never reaches
# systemd's MemoryMax — where it fails at start time with an error nobody
# connects back to a typo.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

reset_limits() { COMP_MAX_OVERRIDE=(); rm -f "$LIMITS_FILE" 2>/dev/null; }

# NOT assert_ok: that runs its command in a subshell (see harness.sh), so the
# COMP_MAX_OVERRIDE this updates would be thrown away and every assertion after
# it would read the pre-save state.
save_limit() { limits_save "$@" || _t_bad "limits_save $* failed"; }

test_a_size_is_validated_before_it_can_reach_systemd() {
  local good bad
  for good in 512M 2G 8g 1500m 1073741824; do
    assert_ok limits_valid "$good"
  done
  for bad in "" 8gb eight 0G -2G "2 G" 2GB 0 G; do
    assert_fails limits_valid "$bad"
  done
}

test_the_role_default_applies_when_nothing_else_does() {
  reset_limits
  assert_eq "$(comp_max be-both)" "2G" "backends take PITCREW_BE_MAX"
  assert_eq "$(comp_max fe-both)" "4G" "frontends take PITCREW_FE_MAX"
  assert_eq "$(comp_max_source be-both)" "role" "and say where that came from"
}

test_a_per_app_cap_in_the_config_beats_the_role_default() {
  reset_limits
  PITCREW_BE_MAX_APP["beonly"]="512M"
  assert_eq "$(comp_max be-beonly)" "512M" "the app's own cap wins"
  assert_eq "$(comp_max_source be-beonly)" "app" "reported as coming from the config"
  assert_eq "$(comp_max be-both)"   "2G"   "and does not leak to other apps"
  unset 'PITCREW_BE_MAX_APP[beonly]'
}

test_a_machine_local_override_beats_both() {
  reset_limits
  PITCREW_BE_MAX_APP["both"]="512M"
  save_limit be-both 3G
  assert_eq "$(comp_max be-both)" "3G" "the override wins over the config"
  assert_eq "$(comp_max_source be-both)" "override" "and says so"
  unset 'PITCREW_BE_MAX_APP[both]'
  reset_limits
}

test_an_override_round_trips_through_the_file() {
  reset_limits
  save_limit be-both 3G
  save_limit fe-both 768M
  assert_eq "$(sort "$LIMITS_FILE" | tr '\n' ' ')" "be-both=3G fe-both=768M " "written as key=value"
  COMP_MAX_OVERRIDE=(); limits_load
  assert_eq "$(comp_max be-both)" "3G"   "and read back"
  assert_eq "$(comp_max fe-both)" "768M" "for every component set"
  reset_limits
}

test_clearing_one_override_leaves_the_others_alone() {
  reset_limits
  limits_save be-both 3G >/dev/null
  limits_save fe-both 768M >/dev/null
  save_limit be-both ""
  assert_eq "$(comp_max be-both)" "2G"   "cleared one goes back to its default"
  assert_eq "$(comp_max fe-both)" "768M" "the other is untouched"
  save_limit fe-both ""
  assert_fails test -e "$LIMITS_FILE" "the file is removed once nothing is set"
  reset_limits
}

test_a_hand_edited_limits_file_does_not_stop_the_tool() {
  # Same contract as render/gui settings: the file is ours, so an unusable value
  # means a hand edit or a newer version. Drop that line, keep the rest.
  reset_limits
  limits_file_for
  mkdir -p "$(dirname "$LIMITS_FILE")"
  printf 'be-both=nonsense\nfe-both=1G\n# a comment\n\n' > "$LIMITS_FILE"
  limits_load
  assert_eq "$(comp_max be-both)" "2G" "the bad line is ignored"
  assert_eq "$(comp_max fe-both)" "1G" "the good one still applies"
  reset_limits
}

test_everything_downstream_reads_the_same_number() {
  # COMP_MAX_B feeds the meters' cap scale, the RAM preflight and the doctor.
  # If it were still built from the role defaults, the GUI and the CLI would
  # show one cap while systemd enforced another.
  reset_limits
  limits_save be-both 3G >/dev/null
  config_finalize "$PITCREW_CFG"
  assert_eq "${COMP_MAX_B[be-both]}" "$((3 * 1024 ** 3))" "the byte table follows the override"
  reset_limits
  config_finalize "$PITCREW_CFG"
  assert_eq "${COMP_MAX_B[be-both]}" "$((2 * 1024 ** 3))" "and follows it back"
}

test_the_preflight_adds_up_the_real_caps() {
  reset_limits
  limits_save be-both 1G >/dev/null
  limits_save fe-both 1G >/dev/null
  config_finalize "$PITCREW_CFG"
  SYS_MEM_TOTAL_KB=$((4 * 1024 * 1024))          # a 4G machine
  ram_preflight be-both fe-both
  assert_empty "$RAM_WARN" "2G of caps fits in 4G"
  limits_save be-both 8G >/dev/null
  config_finalize "$PITCREW_CFG"
  SYS_MEM_TOTAL_KB=$((4 * 1024 * 1024))
  ram_preflight be-both fe-both
  assert_match "$RAM_WARN" 'OOM killer' "9G does not, and it says why"
  reset_limits
  config_finalize "$PITCREW_CFG"
}

test_limit_refuses_a_component_that_does_not_exist() {
  assert_fails cmd_limit be-nope 2G
  assert_fails cmd_limit be-both 8gb
  assert_fails cmd_limit be-both
}

trap 'rm -f "$LIMITS_FILE" 2>/dev/null' EXIT
run_tests
