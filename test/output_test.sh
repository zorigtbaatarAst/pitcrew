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
  local keys; keys=$(printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(" ".join(sorted(d)))
c=d["components"][0]
print(" ".join(sorted(c)))
print(" ".join(sorted(d["summary"])))')
  assert_match "$keys" 'components'  "top level"
  assert_match "$keys" 'cpu errors'  "per component"
  assert_match "$keys" 'crashed down external' "summary counts every state"
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

trap 'err_close; rm -rf "$LOG_DIR"' EXIT
run_tests
