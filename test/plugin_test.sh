#!/usr/bin/env bash
# Plugins: the loader, and the JVM example that proves the boundary is usable
# from outside this repository.
#
# The JVM checks cannot be run here — there may be no JVM on the machine, and
# CI certainly cannot rely on one. What CAN be tested is the part that would
# actually break: the parsers. They take captured `jcmd` output on stdin, the
# same trick lib/00-platform.sh uses for `vm_stat`, so a change to them fails
# here rather than on someone's Spring stack at 9am.
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

# ── the JVM example ─────────────────────────────────────────────────────────

_jvm_plugin() { source "$PITCREW_DIR/examples/plugins/jvm.sh"; }

test_the_example_plugin_registers_itself_as_slow() {
  # It forks a jcmd per JVM, so it must never be reachable from the frame loop.
  local saved=("${DIAG_CHECKS[@]}")
  _jvm_plugin
  assert_eq "${DIAG_CHECK_SLOW[jvm_check]:-}" "1" "registered slow"
  local last=${DIAG_CHECKS[-1]}
  assert_eq "$last" "jvm_check" "and registered at all"
  DIAG_CHECKS=("${saved[@]}")
}

test_heap_info_is_parsed_for_every_collector_spelling() {
  _jvm_plugin
  # G1 — what a modern Spring Boot service actually reports
  local g1; g1=$(printf '%s\n' \
    '12345:' \
    ' garbage-first heap   total 2097152K, used 1887436K [0x00000000c0000000)' \
    '  region size 1024K, 512 young (524288K), 8 survivors (8192K)' \
    ' Metaspace       used 45678K, committed 46000K, reserved 1114112K' \
    '  class space    used 5000K, committed 5200K, reserved 1048576K' | _jvm_heap_parse)
  assert_eq "$g1" "1887436 46000" "G1: heap used and metaspace committed"

  # ParallelGC prints the generations separately; they have to add up.
  local par; par=$(printf '%s\n' \
    ' PSYoungGen      total 305664K, used 100000K [0x0000)' \
    ' ParOldGen       total 699392K, used 200000K [0x0000)' \
    ' Metaspace       used 30000K, committed 31000K, reserved 1114112K' | _jvm_heap_parse)
  assert_eq "$par" "300000 31000" "Parallel: the generations are summed"
}

test_unreadable_heap_info_yields_zero_not_a_guess() {
  # A JVM that is mid-GC, refusing attach, or simply not a JVM must produce no
  # finding at all. A check that guesses when it cannot measure is worse than
  # one that stays quiet — it competes for the one line someone will read.
  _jvm_plugin
  assert_eq "$(printf 'command not supported\n' | _jvm_heap_parse)" "0 0" "unparseable is zero"
  assert_eq "$(printf '' | _jvm_heap_parse)" "0 0" "so is empty"
}

test_the_max_heap_flag_is_found_among_the_others() {
  _jvm_plugin
  local flags='-XX:CICompilerCount=4 -XX:InitialHeapSize=268435456 -XX:MaxHeapSize=4294967296 -XX:+UseG1GC'
  assert_eq "$(printf '%s\n' "$flags" | _jvm_xmx_parse)" "4294967296" "MaxHeapSize"
  assert_empty "$(printf -- '-XX:+UseG1GC\n' | _jvm_xmx_parse)" "absent means absent, not zero-ish"
}

test_java_processes_are_found_anywhere_in_the_tree() {
  # A `gradle bootRun` is a wrapper that forks a daemon that forks the app. The
  # pid pitcrew launched is almost never the JVM anyone cares about.
  _jvm_plugin
  SNAP_PIDS=([be-both]="100 200 300")
  SNAP_PROC_CMD=([100]=sh [200]=/usr/lib/jvm/bin/java [300]=java)
  assert_eq "$(_jvm_pids be-both | tr '\n' ' ')" "200 300 " "both spellings, neither the wrapper"
}

run_tests
