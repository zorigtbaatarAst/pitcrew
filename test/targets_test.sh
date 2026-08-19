#!/usr/bin/env bash
# Target resolution: the words a user types → the components acted on.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

resolved() { resolve_targets "$@" | tr '\n' ' '; }

test_all_lists_every_configured_role() {
  assert_eq "$(resolved all)" "be-both fe-both be-beonly fe-feonly " "all"
}

test_group_filters() {
  assert_eq "$(resolved backends)"  "be-both be-beonly "  "backends"
  assert_eq "$(resolved frontends)" "fe-both fe-feonly "  "frontends"
}

test_app_name_expands_to_its_roles() {
  assert_eq "$(resolved both)"   "be-both fe-both " "both roles"
  assert_eq "$(resolved beonly)" "be-beonly "       "backend-only app"
  assert_eq "$(resolved feonly)" "fe-feonly "       "frontend-only app"
}

test_explicit_component_passes_through() {
  assert_eq "$(resolved be-both)" "be-both " "explicit role"
}

test_duplicates_are_collapsed() {
  # asking for the app AND one of its roles must not act on it twice
  assert_eq "$(resolved both be-both)" "be-both fe-both " "dedup"
}

test_unknown_target_is_rejected() {
  assert_fails resolve_targets nosuchapp
}

test_deps_resolves_to_no_components_by_design() {
  # deps are containers, not components — nothing to emit here is correct
  assert_empty "$(resolved deps)" "deps yields no components"
}

test_stop_deps_is_not_silently_a_noop() {
  # `pitcrew stop deps` used to resolve to nothing and exit 0, so the command
  # looked like it worked while doing absolutely nothing. fixture-db is a
  # protected dep, so a cmd_stop that actually understood the word has to say
  # so — and it must NOT touch the components.
  local out; out=$(plain "$(cmd_stop deps 2>&1)")
  assert_match "$out" 'fixture-db is protected' "deps word must reach the dep loop"
  assert_not_match "$out" 'stopped be-' "bare deps must not stop components"
}

test_stop_with_no_target_still_means_everything() {
  local out; out=$(plain "$(cmd_stop 2>&1)")
  assert_not_match "$out" 'protected' "plain stop must not touch deps"
}

run_tests
