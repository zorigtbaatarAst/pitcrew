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

# ── showing the cap in the terminal ─────────────────────────────────────────

test_the_ram_cell_is_a_render_setting_like_the_others() {
  assert_ok _render_valid ram value
  assert_ok _render_valid ram cap
  assert_fails _render_valid ram both
  assert_fails _render_valid ram ""
  # It has to appear in the generic machinery, or the CLI and the fzf picker
  # would never offer it — they are both built from RENDER_KEYS.
  assert_match "${RENDER_KEYS[*]}" 'ram' "listed as a render key"
  assert_ne "$(render_describe ram cap)" "" "and describes itself in the picker"
}

test_the_cap_is_only_printed_when_asked_for() {
  reset_limits
  save_limit be-both 4G
  cap_cache_set be-both
  SNAP_RSS[be-both]=$((1024 ** 3))          # 1.0G against a 4G cap

  PITCREW_RAM_CELL=value mem_meter be-both
  local plain_cell; plain_cell=$(plain "$R")
  assert_not_match "$plain_cell" '/' "the default cell is just the figure"

  PITCREW_RAM_CELL=cap mem_meter be-both
  local cap_cell; cap_cell=$(plain "$R")
  assert_match "$cap_cell" '1.0G/4G' "and names the cap when asked"
  unset 'SNAP_RSS[be-both]'
  reset_limits
}

test_a_stopped_component_shows_no_cap_to_be_measured_against() {
  # A dash is the honest cell for a service that is not running; "—/8G" would
  # imply a measurement that does not exist.
  reset_limits
  unset 'SNAP_RSS[be-both]'
  PITCREW_RAM_CELL=cap mem_meter be-both
  assert_not_match "$(plain "$R")" '/' "no reading, no cap"
}

test_the_cap_label_follows_the_override() {
  reset_limits
  cap_cache_set be-both
  assert_eq "${COMP_MAX_LABEL[be-both]}" "2G" "the role default, as a label"
  save_limit be-both 512M
  cap_cache_set be-both
  assert_eq "${COMP_MAX_LABEL[be-both]}" "512M" "and follows an override"
  assert_eq "${COMP_MAX_B[be-both]}" "$((512 * 1024 ** 2))" "with the bytes in step"
  reset_limits
}

test_the_menu_feeds_one_line_per_component_and_per_size() {
  reset_limits
  local lines; lines=$(limit_choices | wc -l)
  assert_eq "$lines" "${#PITCREW_COMPS[@]}" "a component picker entry each"
  assert_eq "$(limit_choices | head -1 | cut -f1)" "${PITCREW_COMPS[0]}" "keyed by component, tab-delimited"

  # "default" has to say what it falls back to, or clearing an override is a
  # guess about what you are going back to.
  assert_match "$(plain "$(limit_size_choices be-both | head -1)")" 'inherits 2G' "default names the inherited cap"
  save_limit be-both 1G
  assert_match "$(plain "$(limit_size_choices be-both)")" '●  1G' "the current override is marked"
  reset_limits
}

# ── staggered start ─────────────────────────────────────────────────────────

test_the_start_queue_waits_for_a_slot() {
  # Launching everything at once is a thundering herd. The queue holds at the
  # concurrency limit while components are still `starting`, and releases as
  # they come up.
  PITCREW_START_CONCURRENCY=2
  local -A SNAP_STATE=([a]=starting [b]=starting [c]=up)
  assert_eq "$(snapshot() { :; }; _booting_count a b c)" "2" "only the booting ones count"
  assert_eq "$(snapshot() { :; }; _booting_count c)"     "0" "an up component holds no slot"
}

test_the_queue_does_not_wait_below_the_limit() {
  # Fewer launched than the limit means there is nothing to wait for, and
  # _wait_for_slot must return immediately rather than snapshot in a loop.
  PITCREW_START_CONCURRENCY=3
  assert_ok _wait_for_slot a b
  assert_ok _wait_for_slot
}

test_concurrency_zero_restores_the_old_all_at_once_behaviour() {
  PITCREW_START_CONCURRENCY=0
  assert_ok _wait_for_slot a b c d e f
}

trap 'rm -f "$LIMITS_FILE" 2>/dev/null' EXIT
run_tests
