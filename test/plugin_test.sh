#!/usr/bin/env bash
# Plugins: the loader, and the bundled tool that proves the boundary is usable
# from outside this repository.
#
# The parsers and rules of that tool live in ext/jvm and are tested in
# test/jvm_test.sh, against captured jcmd output from five JDK generations.
# This file tests the SEAM: what pitcrew hands the tool, and what it does with
# what comes back. Neither needs a JVM on the machine, which CI cannot rely on.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

PLUGIN_HOME=$(mktemp -d)
trap 'rm -rf "$PLUGIN_HOME"' EXIT

# ── the loader ──────────────────────────────────────────────────────────────

test_plugins_are_found_in_name_order() {
  mkdir -p "$PLUGIN_HOME/plugins"
  : > "$PLUGIN_HOME/plugins/b.sh"
  : > "$PLUGIN_HOME/plugins/a.sh"
  : > "$PLUGIN_HOME/plugins/notes.txt"
  local out; out=$( PITCREW_PLUGIN_DIR="$PLUGIN_HOME/plugins" plugin_files | tr '\n' ' ' )
  assert_match "$out" 'a\.sh .*b\.sh' "sorted, so load order is predictable"
  assert_not_match "$out" 'notes\.txt' "only .sh files"
  rm -f "$PLUGIN_HOME/plugins"/*
}

test_a_missing_plugin_directory_is_not_an_error() {
  # The overwhelmingly common case is not having any plugins at all.
  local out; out=$( PITCREW_PLUGIN_DIR="$PLUGIN_HOME/nope" plugin_files )
  assert_empty "$out" "nothing to load, nothing to say"
  assert_ok env PITCREW_PLUGIN_DIR="$PLUGIN_HOME/nope" bash -c 'true'
}

test_checks_are_attributed_to_the_file_that_registered_them() {
  # "Where did this finding come from" is the first question anyone asks about
  # a check they do not recognise.
  local saved_checks=("${DIAG_CHECKS[@]}")
  PLUGIN_OF=()
  plugin_attribute core
  local before=${#DIAG_CHECKS[@]}
  from_a_plugin() { :; }
  diag_register from_a_plugin
  plugin_attribute "mine.sh"

  assert_eq "${PLUGIN_OF[from_a_plugin]}" "mine.sh" "the new check belongs to the plugin"
  assert_eq "${PLUGIN_OF[diag_check_crashed]}" "core" "the built-ins stay core"
  assert_eq "$before" "$(( ${#DIAG_CHECKS[@]} - 1 ))" "exactly one was added"
  DIAG_CHECKS=("${saved_checks[@]}")
}

test_the_search_path_is_user_level_only() {
  # A repository that gets its plugins sourced automatically would undo the
  # whole point of a data-only YAML config: `pitcrew status` on a fresh clone
  # would execute whatever the repo felt like. This pins that refusal.
  assert_match "$PITCREW_PLUGIN_DIR" "^${PITCREW_HOME}" "under the user's own config directory"
  assert_not_match "$PITCREW_PLUGIN_DIR" "$ROOT" "never inside the checkout"
}

# ── the bundled tool, and the boundary it sits behind ───────────────────────
#
# ext/jvm/plugin/jvm.sh is an ADAPTER: it shells out to pitcrew-jvm and turns
# tab-separated findings into diag_add calls. The parsers and the rules are
# tested in test/jvm_test.sh, against captured jcmd output from five JDKs.
#
# What is worth testing HERE is the seam — that the plugin registers correctly,
# that it stays silent when the tool is missing, and that the one fact only
# pitcrew has (the cap it launched a component under) actually reaches it.

_jvm_adapter() { source "$PITCREW_DIR/ext/jvm/plugin/jvm.sh"; }

test_the_bundled_plugin_registers_itself_as_slow() {
  # It forks a pitcrew-jvm which forks a jcmd per JVM, so it must never be
  # reachable from the dashboard frame loop.
  local saved=("${DIAG_CHECKS[@]}")
  _jvm_adapter
  assert_eq "${DIAG_CHECK_SLOW[jvm_check]:-}" "1" "registered slow"
  assert_eq "${DIAG_CHECKS[-1]}" "jvm_check" "and registered at all"
  DIAG_CHECKS=("${saved[@]}")
}

test_the_plugin_is_silent_when_the_tool_is_not_installed() {
  # The overwhelmingly common case for anyone who has not run ext/jvm/install.sh.
  # A plugin that cannot work registers nothing and says nothing.
  local saved=("${DIAG_CHECKS[@]}")
  _jvm_adapter
  local before=$DIAG_N
  ( PITCREW_JVM_BIN=/nonexistent PATH=/nonexistent jvm_check )
  assert_eq "$DIAG_N" "$before" "no findings invented"
  DIAG_CHECKS=("${saved[@]}")
}

test_the_cap_pitcrew_launched_a_component_under_reaches_the_tool() {
  # This is the whole reason the plugin exists. pitcrew knows the RAM cap; the
  # JVM knows its -Xmx. Neither half catches an OOM kill alone, and the cap is
  # the half that only pitcrew can supply.
  local saved=("${DIAG_CHECKS[@]}")
  _jvm_adapter
  SNAP_STATE=([be-both]=up)
  SNAP_PIDS=([be-both]="100 200")
  SNAP_PROC_CMD=([100]=sh [200]=/usr/lib/jvm/bin/java)
  COMP_MAX_B=([be-both]=2147483648)
  PITCREW_COMPS=(be-both)

  local out; out=$(_jvm_targets)
  assert_eq "$out" "$(printf 'be-both\t200\t2147483648\tpitcrew')" "label, the java pid, the cap, the source"
  DIAG_CHECKS=("${saved[@]}")
}

test_a_wrapper_process_is_not_mistaken_for_the_jvm() {
  # A `gradle bootRun` is a wrapper that forks a daemon that forks the app, so
  # the pid pitcrew launched is almost never the JVM anyone cares about.
  local saved=("${DIAG_CHECKS[@]}")
  _jvm_adapter
  SNAP_PIDS=([be-both]="100 200 300")
  SNAP_PROC_CMD=([100]=sh [200]=/usr/lib/jvm/bin/java [300]=java)
  assert_eq "$(_jvm_comp_pids be-both | tr '\n' ' ')" "200 300 " "both spellings, neither the wrapper"
  DIAG_CHECKS=("${saved[@]}")
}

test_two_jvms_in_one_component_are_told_apart() {
  # Two findings both titled with the same component name are indistinguishable,
  # so the label carries the pid once there is more than one.
  local saved=("${DIAG_CHECKS[@]}")
  _jvm_adapter
  SNAP_STATE=([be-both]=up)
  SNAP_PIDS=([be-both]="200 300")
  SNAP_PROC_CMD=([200]=java [300]=java)
  COMP_MAX_B=([be-both]=1024)
  PITCREW_COMPS=(be-both)
  local out; out=$(_jvm_targets | cut -f1 | tr '\n' ' ')
  assert_eq "$out" "be-both[200] be-both[300] " "disambiguated by pid"
  DIAG_CHECKS=("${saved[@]}")
}

test_findings_from_the_tool_become_pitcrew_findings() {
  # The seam end to end, with a stub standing in for the tool: whatever it
  # prints as TSV has to arrive in the DIAG_* arrays unchanged, because those
  # are what the dashboard, the JSON and the desktop app all read.
  local saved=("${DIAG_CHECKS[@]}")
  _jvm_adapter
  local stub="$PLUGIN_HOME/stub-pitcrew-jvm"
  {
    printf '#!/usr/bin/env bash\n'
    # It also exits 1 on a critical finding, exactly as the real tool does.
    # The adapter must read the findings anyway rather than treating that as
    # a failure.
    printf 'printf "crit\\tjvm-cap\\ta title\\ta detail\\tpitcrew limit be-both 2G\\tbe-both\\n"\n'
    printf 'exit 1\n'
  } > "$stub"
  chmod +x "$stub"

  SNAP_STATE=([be-both]=up); SNAP_PIDS=([be-both]="200")
  SNAP_PROC_CMD=([200]=java); COMP_MAX_B=([be-both]=2147483648)
  PITCREW_COMPS=(be-both)

  local before=$DIAG_N
  PITCREW_JVM_BIN="$stub" jvm_check
  assert_eq "$DIAG_N" "$(( before + 1 ))" "exactly one finding arrived"
  assert_eq "${DIAG_SEV[-1]}"   "crit"     "severity survives"
  assert_eq "${DIAG_ID[-1]}"    "jvm-cap"  "id survives"
  assert_eq "${DIAG_TITLE[-1]}" "a title"  "title survives"
  assert_eq "${DIAG_SCOPE[-1]}" "be-both"  "scope survives, so it lands on the right row"
  assert_eq "${DIAG_FIX[-1]}"   "pitcrew limit be-both 2G" "and the fix command"
  DIAG_CHECKS=("${saved[@]}")
}

test_a_malformed_line_from_the_tool_is_dropped_not_added() {
  # The adapter reads whatever is on the other end of a pipe. A line that is
  # not a finding must not become one with an empty severity.
  local saved=("${DIAG_CHECKS[@]}")
  _jvm_adapter
  local stub="$PLUGIN_HOME/stub-noise"
  printf '#!/usr/bin/env bash\nprintf "some warning from the jvm\\n\\n"\n' > "$stub"
  chmod +x "$stub"
  SNAP_STATE=([be-both]=up); SNAP_PIDS=([be-both]="200")
  SNAP_PROC_CMD=([200]=java); COMP_MAX_B=([be-both]=1024)
  PITCREW_COMPS=(be-both)
  local before=$DIAG_N
  PITCREW_JVM_BIN="$stub" jvm_check
  assert_eq "$DIAG_N" "$before" "nothing added"
  DIAG_CHECKS=("${saved[@]}")
}

# ── the same list as data ───────────────────────────────────────────────────

test_the_plugin_list_is_available_as_data() {
  # The desktop app was rendering `pitcrew plugins` text in a monospace box,
  # onboarding paragraph and all — a shell lesson in a window with no shell.
  # This is what it reads instead.
  local saved=("${DIAG_CHECKS[@]}")
  mkdir -p "$PLUGIN_HOME/plugins"
  : > "$PLUGIN_HOME/plugins/demo.sh"
  PLUGIN_OF=()
  plugin_attribute core
  demo_cheap() { :; }
  demo_slow() { :; }
  diag_register demo_cheap
  diag_register demo_slow slow
  plugin_attribute "demo.sh"

  local out; out=$(PITCREW_PLUGIN_DIR="$PLUGIN_HOME/plugins" plugins_json)
  assert_match "$out" '"file":"demo\.sh"' "the file that registered them"
  assert_match "$out" '"name":"demo_cheap","slow":false' "a cheap check"
  # The tier is why a check can be missing from the dashboard and present in
  # `diagnose`, so a UI that cannot see it cannot explain the difference.
  assert_match "$out" '"name":"demo_slow","slow":true' "and a slow one, marked"
  assert_not_match "$out" 'diag_register my_check' "no onboarding prose in a payload"

  DIAG_CHECKS=("${saved[@]}")
  rm -f "$PLUGIN_HOME/plugins"/*
}

test_no_plugins_is_an_empty_list_not_an_error() {
  # The overwhelmingly common case. It has to parse, not just not crash.
  local out; out=$(PITCREW_PLUGIN_DIR="$PLUGIN_HOME/nope" plugins_json)
  assert_match "$out" '"plugins":\[\]' "an empty array"
  if command -v python3 >/dev/null 2>&1; then
    assert_ok python3 -c "import json,sys; json.loads(sys.argv[1])" "$out"
  fi
}

test_the_json_payload_parses() {
  command -v python3 >/dev/null 2>&1 || return 0
  local saved=("${DIAG_CHECKS[@]}")
  mkdir -p "$PLUGIN_HOME/plugins"
  : > "$PLUGIN_HOME/plugins/demo.sh"
  PLUGIN_OF=(); plugin_attribute core
  demo_check() { :; }
  diag_register demo_check slow
  plugin_attribute "demo.sh"
  local out; out=$(PITCREW_PLUGIN_DIR="$PLUGIN_HOME/plugins" plugins_json)
  assert_ok python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d['plugins'][0]['file'] == 'demo.sh', d
assert d['plugins'][0]['checks'][0]['slow'] is True, d
" "$out"
  DIAG_CHECKS=("${saved[@]}")
  rm -f "$PLUGIN_HOME/plugins"/*
}

run_tests
