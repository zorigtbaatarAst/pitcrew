#!/usr/bin/env bash
# Machine-readable output and the scripting entry points.
#
# These exist so pitcrew can be used by something other than a human watching
# it — a status line, a CI gate, a script that blocks until the stack is up.
# That makes the exit codes and the JSON shape a contract, not a convenience.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

LOG_DIR=$(mktemp -d)

test_json_is_valid_and_has_the_documented_shape() {
  command -v python3 >/dev/null 2>&1 || return 0
  local out; out=$(cmd_json)
  printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
    || { _t_bad "output is not valid JSON"; return; }

  # The EXACT key set, not a substring match. This object has consumers — the
  # desktop app, a status line, a CI gate — so a renamed or dropped field is a
  # breaking change and has to fail here rather than in someone's dashboard.
  # Adding a field is fine: add it to the list in the same commit, and bump
  # PITCREW_JSON_SCHEMA only when something is removed or changes meaning.
  local keys; keys=$(printf '%s' "$out" | python3 -c '
import json,sys
d = json.load(sys.stdin)
print(" ".join(sorted(d)))
print(" ".join(sorted(d["components"][0])))
print(" ".join(sorted(d["summary"])))
print(" ".join(sorted(d["machine"])))
print(" ".join(sorted(d["deps"][0])) if d["deps"] else "name state")
print(d["schema"])
print(" ".join(sorted(d["health"])))
print(" ".join(sorted(d["health"]["counts"])))
print(" ".join(sorted(d["health"]["recoverable"])))')

  assert_eq "$(printf '%s' "$keys" | sed -n 1p)" \
    "at collector components deps errorPattern health logDir machine profileDir project root schema shells summary" "top level"
  assert_eq "$(printf '%s' "$keys" | sed -n 2p)" \
    "app cpu errors exit health idle limit limitSource name pid port processes protected restarts role rss since state url" "per component"
  assert_eq "$(printf '%s' "$keys" | sed -n 3p)" \
    "crashed down external starting up" "summary counts every state"
  assert_eq "$(printf '%s' "$keys" | sed -n 4p)" \
    "cpuPercent memTotal memUsed swapTotal swapUsed" "machine gauges"
  assert_eq "$(printf '%s' "$keys" | sed -n 5p)" "name state" "per dependency"
  assert_eq "$(printf '%s' "$keys" | sed -n 6p)" "1" "schema version is declared"
  # The verdict travels with the facts. A GUI that had to work out "is anything
  # wrong" from the component list would be reimplementing lib/19-diag.sh.
  assert_eq "$(printf '%s' "$keys" | sed -n 7p)" \
    "counts deep findings headline recoverable verdict" "health object"
  assert_eq "$(printf '%s' "$keys" | sed -n 8p)" "crit info warn" "finding counts by severity"
  assert_eq "$(printf '%s' "$keys" | sed -n 9p)" "bytes components protected" \
    "what stopping the idle ones returns, and what will never be proposed"
}

test_json_reports_the_real_component_model() {
  command -v python3 >/dev/null 2>&1 || return 0
  local n; n=$(cmd_json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["components"]))')
  assert_eq "$n" "${#PITCREW_COMPS[@]}" "one entry per component"
  local port; port=$(cmd_json | python3 -c '
import json,sys
print([c["port"] for c in json.load(sys.stdin)["components"] if c["name"]=="be-both"][0])')
  assert_eq "$port" "19801" "ports come through as numbers, not strings"
}

test_json_escapes_what_it_must() {
  # a project name is user text and ends up in a JSON string
  local saved=$PITCREW_PROJECT_NAME
  PITCREW_PROJECT_NAME='say "hi" \ bye'
  command -v python3 >/dev/null 2>&1 && {
    local got; got=$(cmd_json | python3 -c 'import json,sys; print(json.load(sys.stdin)["project"])')
    assert_eq "$got" 'say "hi" \ bye' "quotes and backslashes survive a round trip"
  }
  PITCREW_PROJECT_NAME=$saved
}

test_unknown_numbers_are_null_not_zero() {
  # a component that is not running has no RSS; reporting 0 would be a lie a
  # status line would happily plot
  assert_eq "$(_json_num '')"     'null' "empty"
  assert_eq "$(_json_num 'abc')"  'null' "not a number"
  assert_eq "$(_json_num '0')"    '0'    "a real zero stays zero"
  assert_eq "$(_json_num '8080')" '8080' "a real number"
}

# ── wait: the exit codes are the contract ───────────────────────────────────
# Drive cmd_wait against a fixed world by replacing the one function that
# reads the real one.
_wait_with_states() { # $1 = state every component reports → cmd_wait's exit code
  ( snapshot_stub_state=$1
    snapshot() { local c; for c in "${PITCREW_COMPS[@]}"; do SNAP_STATE[$c]=$snapshot_stub_state; done; }
    cmd_wait --timeout 2 all >/dev/null 2>&1; echo $? )
}

test_wait_exit_codes() {
  assert_eq "$(_wait_with_states up)"       0 "everything up"
  assert_eq "$(_wait_with_states crashed)"  2 "something crashed"
  assert_eq "$(_wait_with_states starting)" 1 "still starting when the clock ran out"
  assert_eq "$(_wait_with_states down)"     1 "never came up"
}

test_wait_is_explicit_about_ports_it_does_not_own() {
  # accepting a port served by another project silently is exactly the failure
  # this codebase already had once
  local out; out=$(plain "$( ( snapshot_stub_state=external
    snapshot() { local c; for c in "${PITCREW_COMPS[@]}"; do SNAP_STATE[$c]=$snapshot_stub_state; done; }
    cmd_wait --timeout 2 all 2>&1 ) )")
  assert_match "$out" 'did not start' "says so rather than passing quietly"
  local rc; rc=$( ( snapshot_stub_state=external
    snapshot() { local c; for c in "${PITCREW_COMPS[@]}"; do SNAP_STATE[$c]=$snapshot_stub_state; done; }
    cmd_wait --timeout 2 --strict all >/dev/null 2>&1; echo $? ) )
  assert_eq "$rc" 1 "--strict refuses it outright"
}

# ── cpu% honesty and the NDJSON stream ──────────────────────────────────────
#
# CPU% is a delta between two samples. A one-shot `status --json` only ever
# takes one, so it has nothing to subtract and used to report 0 — a structural
# zero that a status line could not tell apart from an idle service.

test_json_cpu_helper_reports_unknown_rather_than_a_fake_zero() {
  local saved=${SNAP_CPU_OK:-0}
  SNAP_CPU_OK=0
  assert_eq "$(_json_cpu 42)" "null" "no baseline: null, never 0"
  SNAP_CPU_OK=1
  assert_eq "$(_json_cpu 42)" "42"   "with a baseline the reading passes through"
  assert_eq "$(_json_cpu '')"  "null" "a component with no process is still null"
  SNAP_CPU_OK=$saved
}

test_snapshot_marks_cpu_usable_only_after_a_second_sample() {
  SNAP_AT_US=0                       # as if this were a fresh one-shot process
  snapshot
  assert_eq "$SNAP_CPU_OK" 0 "first sample has no baseline to delta against"
  snapshot
  assert_eq "$SNAP_CPU_OK" 1 "second sample can"
}

test_json_watch_validates_its_interval_before_looping_forever() {
  assert_fails cmd_json_watch --interval 0
  assert_fails cmd_json_watch --interval abc
  assert_fails cmd_json_watch --interval
  assert_fails cmd_json_watch --nonsense
}

test_json_watch_emits_one_object_per_line() {
  command -v python3 >/dev/null 2>&1 || return 0
  # Two frames is enough to prove it is a stream of whole objects and not one
  # pretty-printed blob a line reader would choke on.
  local out; out=$( ( cmd_json_watch --interval 1 & sleep 2.5; kill %1 2>/dev/null ) 2>/dev/null | head -2 )
  local n; n=$(printf '%s\n' "$out" | python3 -c '
import json,sys
n=0
for line in sys.stdin:
    line=line.strip()
    if line:
        json.loads(line); n+=1
print(n)' 2>/dev/null)
  assert_eq "$n" 2 "each line parses on its own"
}

test_doctor_json_is_a_gate_not_a_reformat() {
  command -v python3 >/dev/null 2>&1 || return 0
  # Not a scrape of doctor's prose: that is arranged for a human reading it
  # once, and a changed glyph would break every consumer.
  local out; out=$(cmd_doctor_json 2>/dev/null || true)
  printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
    || { _t_bad "doctor --json is not valid JSON"; return; }
  local keys; keys=$(printf '%s' "$out" | python3 -c '
import json,sys
d = json.load(sys.stdin)
print(" ".join(sorted(d)))
print(" ".join(sorted(d["tools"])))')
  assert_eq "$(printf '%s' "$keys" | sed -n 1p)" \
    "bash capsEnforced capsFit capsWarning collector deps os portClashes schema tools version" \
    "the whole key set, pinned like status --json"
  assert_eq "$(printf '%s' "$keys" | sed -n 2p)" "docker fzf lsof" "tools it looks for"
}

test_doctor_json_fails_when_the_caps_do_not_fit() {
  # The point of --json is that CI can gate on it directly. A machine too small
  # for the configured caps has to be a non-zero exit, not a field nobody reads.
  # sys_gauges has to be stubbed, not the variable: cmd_doctor_json snapshots
  # first, and snapshot re-reads the real machine over anything set here.
  local rc
  rc=$( ( sys_gauges() { SYS_MEM_TOTAL_KB=$((1024 * 1024)); }   # a 1G machine
          cmd_doctor_json >/dev/null 2>&1; echo $? ) )
  assert_eq "$rc" "1" "a machine too small for the caps is a non-zero exit"
}

trap 'err_close; rm -rf "$LOG_DIR"' EXIT
run_tests
