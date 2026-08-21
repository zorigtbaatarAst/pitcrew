#!/usr/bin/env bash
# Diagnostics: the check registry that is pitcrew's first plugin boundary, the
# core checks that use it, and the verdict everything downstream reads.
#
# The point of these is not that a particular sentence is printed — it is that
# a check is a plain function anyone can register, that a finding survives
# intact all the way to the JSON, and that the verdict is the worst thing
# happening rather than an average of the news.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

# A check reads the snapshot, so the tests fabricate one rather than starting
# real services: every branch is reachable, and none of it depends on what
# happens to be running on the machine running the suite.
_fake_snapshot() {
  SNAP_STATE=(); SNAP_RSS=(); SNAP_CPU=(); SNAP_PID=(); SNAP_SINCE=()
  SNAP_EXIT=(); SNAP_EXIT_AT=(); SNAP_IDLE=(); SNAP_DEP=(); ERR_COUNT=()
  SNAP_NOW_S=1000000
  SNAP_CPU_OK=1
  SYS_MEM_TOTAL_KB=$(( 16 * 1024 * 1024 ))
  SYS_MEM_USED_KB=$(( 4 * 1024 * 1024 ))
  SYS_SWAP_TOTAL_KB=$(( 2 * 1024 * 1024 ))
  SYS_SWAP_USED_KB=0
  SYS_CPU_PCT=10
  local c
  for c in "${PITCREW_COMPS[@]}"; do SNAP_STATE[$c]=down; done
  for c in "${PITCREW_DEPS[@]}"; do SNAP_DEP[$c]=up; done
}

_findings() { # → the titles of every finding, one per line
  local i
  for i in "${!DIAG_TITLE[@]}"; do printf '%s\n' "${DIAG_TITLE[i]}"; done
}

_details() { # → the evidence line of every finding
  local i
  for i in "${!DIAG_DETAIL[@]}"; do printf '%s\n' "${DIAG_DETAIL[i]}"; done
}

_ids() { printf '%s\n' "${DIAG_ID[@]:-}" | tr '\n' ' '; }

# ── the extension point ─────────────────────────────────────────────────────

test_a_check_is_just_a_registered_function() {
  # This is the whole plugin contract. If registering a function and having it
  # contribute a finding ever stops working, the boundary is gone.
  _fake_snapshot
  my_check() { diag_add warn my-id "a thing" "because reasons" "do-something" "somewhere"; }
  local saved=("${DIAG_CHECKS[@]}")
  DIAG_CHECKS=(my_check)
  diag_run
  DIAG_CHECKS=("${saved[@]}")

  assert_eq "$DIAG_N" 1 "the finding was collected"
  assert_eq "${DIAG_TITLE[0]}" "a thing" "title"
  assert_eq "${DIAG_DETAIL[0]}" "because reasons" "detail"
  assert_eq "${DIAG_FIX[0]}" "do-something" "the suggested command"
  assert_eq "${DIAG_SCOPE[0]}" "somewhere" "what it is about"
  assert_eq "$DIAG_VERDICT" "warn" "and it sets the verdict"
}

test_a_check_that_does_not_exist_does_not_break_the_run() {
  # A plugin can be unregistered, renamed or half-loaded. That must degrade to
  # "one fewer check", never to a dashboard that stops repainting.
  _fake_snapshot
  local saved=("${DIAG_CHECKS[@]}")
  DIAG_CHECKS=(no_such_check_anywhere)
  assert_ok diag_run
  DIAG_CHECKS=("${saved[@]}")
}

test_the_verdict_is_the_worst_thing_happening() {
  _fake_snapshot
  local saved=("${DIAG_CHECKS[@]}")
  noise() { diag_add info a "note" "" ; diag_add warn b "warning" ""; }
  DIAG_CHECKS=(noise); diag_run
  assert_eq "$DIAG_VERDICT" "warn" "a warning outranks a note"
  assert_eq "$DIAG_HEADLINE" "warning" "and the headline is the worst one"

  fire() { diag_add info a "note" ""; diag_add crit b "on fire" ""; diag_add warn c "warning" ""; }
  DIAG_CHECKS=(fire); diag_run
  assert_eq "$DIAG_VERDICT" "crit" "a critical outranks both"
  assert_eq "$DIAG_HEADLINE" "on fire" "even when it is not first"
  DIAG_CHECKS=("${saved[@]}")
}

test_nothing_wrong_still_says_something() {
  # A status line that goes blank when all is well makes you check whether the
  # tool is working.
  _fake_snapshot
  local c
  for c in "${PITCREW_COMPS[@]}"; do SNAP_STATE[$c]=up; done
  diag_run
  assert_eq "$DIAG_VERDICT" "ok" "no findings"
  assert_match "$DIAG_HEADLINE" 'healthy' "and it says so"
}

# ── the core checks ─────────────────────────────────────────────────────────

test_a_crash_is_critical_and_carries_its_exit_code() {
  _fake_snapshot
  SNAP_STATE[be-both]=crashed
  SNAP_EXIT[be-both]=3
  SNAP_EXIT_AT[be-both]=$(( SNAP_NOW_S - 120 ))
  diag_run
  assert_eq "$DIAG_VERDICT" "crit" "a crash is always critical"
  assert_match "$(_findings)" 'be-both crashed' "names the component"
  local i detail=""
  for i in "${!DIAG_ID[@]}"; do [ "${DIAG_ID[i]}" = crashed ] && detail=${DIAG_DETAIL[i]}; done
  assert_match "$detail" 'exited 3' "says how it ended"
  assert_match "$detail" '2m ago'   "and when"
}

test_a_service_stuck_starting_is_distinguished_from_one_still_booting() {
  _fake_snapshot
  PITCREW_WAIT_SECS=60
  SNAP_STATE[be-both]=starting
  SNAP_SINCE[be-both]=$(( SNAP_NOW_S - 30 ))
  diag_run
  assert_not_match "$(_ids)" 'stuck' "still inside its boot timeout — not news"

  SNAP_SINCE[be-both]=$(( SNAP_NOW_S - 600 ))
  diag_run
  assert_match "$(_ids)" 'stuck' "ten minutes in, it is not booting any more"
  assert_match "$(_details)" 'health endpoint' "and says which signal is missing"
}

test_memory_pressure_names_who_is_holding_the_memory() {
  # "RAM 96%" is a fact. Which four processes account for it is the answer.
  _fake_snapshot
  SYS_MEM_USED_KB=$(( 15 * 1024 * 1024 ))
  SNAP_STATE[be-both]=up;  SNAP_RSS[be-both]=$(( 3 * 1024 ** 3 ))
  SNAP_STATE[fe-both]=up;  SNAP_RSS[fe-both]=$(( 1024 ** 3 ))
  diag_run
  local i detail=""
  for i in "${!DIAG_ID[@]}"; do [ "${DIAG_ID[i]}" = memory ] && detail=${DIAG_DETAIL[i]}; done
  assert_match "$detail" 'be-both' "the largest consumer is named"
  assert_match "$detail" 'fe-both' "and the next one"
  assert_match "$detail" 'be-both 3.0G, fe-both 1.0G' "largest first, with figures"
}

test_swap_in_use_is_critical_even_when_ram_looks_fine() {
  # The number that actually predicts a stuttering laptop. RAM at 60% with a
  # gigabyte swapped is a worse place to be than RAM at 90% with none.
  _fake_snapshot
  SYS_MEM_USED_KB=$(( 9 * 1024 * 1024 ))          # 56%, nowhere near the warn threshold
  SYS_SWAP_USED_KB=$(( 1024 * 1024 ))
  diag_run
  assert_eq "$DIAG_VERDICT" "crit" "swapping is critical"
  assert_match "$DIAG_HEADLINE" 'swap' "and says so by name"
}

test_caps_that_cannot_bite_are_reported() {
  _fake_snapshot
  SYS_MEM_TOTAL_KB=$(( 1024 * 1024 ))             # a 1G machine against the fixture's 2G+4G caps
  diag_run
  assert_match "$(_ids)" 'caps-overcommit' "the caps exceed the machine"
}

test_a_component_close_to_its_own_cap_is_reported() {
  _fake_snapshot
  SNAP_STATE[be-both]=up
  SNAP_RSS[be-both]=$(( COMP_MAX_B[be-both] * 95 / 100 ))
  diag_run
  assert_match "$(_ids)" 'cap-near' "95% of the cap that will kill it"
}

test_a_dependency_that_is_down_is_reported() {
  _fake_snapshot
  SNAP_DEP[fixture-db]=down
  diag_run
  assert_match "$(_findings)" 'fixture-db is not running' "named"
}

test_errors_are_only_news_for_something_that_looks_healthy() {
  _fake_snapshot
  SNAP_STATE[be-both]=up
  ERR_COUNT[be-both]=7
  diag_run
  assert_match "$(_ids)" 'log-errors' "up and logging exceptions is the quiet failure"

  _fake_snapshot
  SNAP_STATE[be-both]=crashed
  ERR_COUNT[be-both]=7
  diag_run
  assert_not_match "$(_ids)" 'log-errors' "on a crashed service the crash is the story"
}

# ── recovery candidates ─────────────────────────────────────────────────────

test_idle_candidates_need_both_quiet_and_age() {
  _fake_snapshot
  SYS_MEM_USED_KB=$(( 15 * 1024 * 1024 ))         # under pressure, or idleness is not news
  PITCREW_IDLE_MIN=600
  SNAP_STATE[be-both]=up; SNAP_RSS[be-both]=$(( 1024 ** 3 ))
  SNAP_IDLE[be-both]=900; SNAP_SINCE[be-both]=$(( SNAP_NOW_S - 30 ))
  diag_run
  assert_empty "${DIAG_IDLE_COMPS[*]}" "quiet, but only just started"

  SNAP_SINCE[be-both]=$(( SNAP_NOW_S - 3600 ))
  diag_run
  assert_eq "${DIAG_IDLE_COMPS[*]}" "be-both" "quiet and up an hour"
  assert_eq "$DIAG_IDLE_BYTES" "$(( 1024 ** 3 ))" "and how much it would return"
  assert_match "${DIAG_IDLE_WHY[be-both]}" 'quiet 15m' "the evidence travels with it"
  assert_match "${DIAG_IDLE_WHY[be-both]}" 'up 1h'     "both halves of it"
}

test_idle_services_are_not_raised_when_there_is_room() {
  # A service you are not using right now is not a problem. It only becomes one
  # when something else needs the memory.
  _fake_snapshot
  PITCREW_IDLE_MIN=600
  SNAP_STATE[be-both]=up; SNAP_RSS[be-both]=$(( 1024 ** 3 ))
  SNAP_IDLE[be-both]=900; SNAP_SINCE[be-both]=$(( SNAP_NOW_S - 3600 ))
  diag_run
  assert_not_match "$(_ids)" 'recoverable' "plenty of RAM free — nothing to say"
}

test_idleness_is_never_claimed_without_a_cpu_baseline() {
  # CPU% is a delta. One sample cannot support "this has been idle", and
  # guessing would put a real service on a list of things to stop.
  _fake_snapshot
  SYS_MEM_USED_KB=$(( 15 * 1024 * 1024 ))
  SNAP_CPU_OK=0
  SNAP_STATE[be-both]=up; SNAP_RSS[be-both]=$(( 1024 ** 3 ))
  SNAP_IDLE[be-both]=""; SNAP_SINCE[be-both]=$(( SNAP_NOW_S - 3600 ))
  diag_run
  assert_empty "${DIAG_IDLE_COMPS[*]}" "no baseline, no claim"
}

test_a_protected_component_is_never_proposed_but_is_still_named() {
  # Omitting it silently would read as a bug in the tool: the biggest idle
  # service is missing from the list and nothing says why.
  _fake_snapshot
  SYS_MEM_USED_KB=$(( 15 * 1024 * 1024 ))
  PITCREW_IDLE_MIN=600
  local c
  for c in be-both fe-both; do
    SNAP_STATE[$c]=up; SNAP_RSS[$c]=$(( 1024 ** 3 ))
    SNAP_IDLE[$c]=900; SNAP_SINCE[$c]=$(( SNAP_NOW_S - 3600 ))
  done
  PITCREW_PROTECTED=([be-both]=1)
  diag_run
  PITCREW_PROTECTED=()

  assert_eq "${DIAG_IDLE_COMPS[*]}" "fe-both" "the protected one is not a candidate"
  assert_eq "${DIAG_PROTECTED[*]}"  "be-both" "but it is reported"
  assert_eq "$DIAG_IDLE_BYTES" "$(( 1024 ** 3 ))" "and its bytes are not counted as recoverable"
  local i fix=""
  for i in "${!DIAG_ID[@]}"; do [ "${DIAG_ID[i]}" = recoverable ] && fix=${DIAG_FIX[i]}; done
  assert_not_match "$fix" 'be-both' "and it can never reach the suggested command"
}

# ── the two tiers ───────────────────────────────────────────────────────────

test_a_slow_check_is_skipped_by_the_frame_loop() {
  # This is what keeps "no forks in the frame loop" structural rather than a
  # rule a plugin author has to have read.
  _fake_snapshot
  local saved=("${DIAG_CHECKS[@]}")
  fastc() { diag_add info fast "fast" ""; }
  slowc() { diag_add info slow "slow" ""; }
  DIAG_CHECKS=(); DIAG_CHECK_SLOW=()
  diag_register fastc
  diag_register slowc slow

  diag_run
  assert_eq "$(_ids)" "fast " "the per-frame run skips it"
  assert_eq "$DIAG_DEEP" "0" "and says the run was shallow"

  diag_run --full
  assert_eq "$(_ids)" "fast slow " "the explicit run includes it"
  assert_eq "$DIAG_DEEP" "1" "and says so"

  DIAG_CHECKS=("${saved[@]}")
  unset "DIAG_CHECK_SLOW[fastc]" "DIAG_CHECK_SLOW[slowc]"
}

test_the_json_says_which_tier_it_came_from() {
  command -v python3 >/dev/null 2>&1 || return 0
  _fake_snapshot
  diag_run
  local shallow; shallow=$(diag_json_health | python3 -c 'import json,sys; print(json.load(sys.stdin)["deep"])')
  diag_run --full
  local deep; deep=$(diag_json_health | python3 -c 'import json,sys; print(json.load(sys.stdin)["deep"])')
  assert_eq "$shallow" "False" "a consumer can tell it has only seen the cheap checks"
  assert_eq "$deep" "True" "and when it has seen everything"
}

# ── the wire format ─────────────────────────────────────────────────────────

test_findings_survive_intact_into_the_json() {
  command -v python3 >/dev/null 2>&1 || return 0
  _fake_snapshot
  SNAP_STATE[be-both]=crashed; SNAP_EXIT[be-both]=1; SNAP_EXIT_AT[be-both]=$(( SNAP_NOW_S - 5 ))
  diag_run
  local out; out=$(diag_json_health)
  printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
    || { _t_bad "health object is not valid JSON"; return; }
  local got; got=$(printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["verdict"], d["counts"]["crit"])
print(d["findings"][0]["id"], d["findings"][0]["scope"])')
  assert_eq "$(printf '%s' "$got" | sed -n 1p)" "crit 1" "verdict and counts"
  assert_eq "$(printf '%s' "$got" | sed -n 2p)" "crashed be-both" "the finding, with what it is about"
}

test_a_finding_with_quotes_in_it_does_not_break_the_json() {
  command -v python3 >/dev/null 2>&1 || return 0
  _fake_snapshot
  local saved=("${DIAG_CHECKS[@]}")
  quoted() { diag_add warn q 'a "quoted" title' 'back\slash' "" ""; }
  DIAG_CHECKS=(quoted); diag_run
  DIAG_CHECKS=("${saved[@]}")
  local got; got=$(diag_json_health | python3 -c '
import json, sys
print(json.load(sys.stdin)["findings"][0]["title"])' 2>/dev/null)
  assert_eq "$got" 'a "quoted" title' "escaped, not mangled"
}

# ── the panel ───────────────────────────────────────────────────────────────

test_the_diagnostics_panel_renders_every_section() {
  # A smoke test over the real panel. Its branches (no findings, findings,
  # recovery candidates, swap in use) are otherwise only reachable by opening
  # the dashboard on a machine that happens to be in that state.
  _fake_snapshot
  SYS_MEM_USED_KB=$(( 15 * 1024 * 1024 ))
  SYS_SWAP_USED_KB=$(( 512 * 1024 ))
  PITCREW_IDLE_MIN=600
  SNAP_STATE[be-both]=crashed; SNAP_EXIT[be-both]=2; SNAP_EXIT_AT[be-both]=$(( SNAP_NOW_S - 60 ))
  SNAP_STATE[fe-both]=up; SNAP_RSS[fe-both]=$(( 2 * 1024 ** 3 ))
  SNAP_IDLE[fe-both]=1800; SNAP_SINCE[fe-both]=$(( SNAP_NOW_S - 7200 ))
  diag_run

  # drive one repaint, then quit: read_key is the loop's only exit
  export PITCREW_COLS=90 PITCREW_LINES=28
  TERM_DIRTY=1
  read_key() { KEY=q; return 0; }
  local out; out=$(plain "$(diag_view)")
  unset -f read_key

  assert_match "$out" 'be-both crashed'  "the critical finding"
  assert_match "$out" 'RAM'              "the machine meters"
  assert_match "$out" 'SWP'              "swap, because it is in use"
  assert_match "$out" 'recoverable'      "the review section"
  assert_match "$out" 'fe-both'          "naming every candidate"
  assert_match "$out" 'quiet 30m'        "with the evidence for calling it idle"
  assert_match "$out" 'stop the 1 idle'  "and only then an action"
}

test_the_panel_says_so_when_there_is_nothing_to_say() {
  _fake_snapshot
  local c
  for c in "${PITCREW_COMPS[@]}"; do SNAP_STATE[$c]=up; done
  diag_run
  export PITCREW_COLS=90 PITCREW_LINES=28
  TERM_DIRTY=1
  read_key() { KEY=q; return 0; }
  local out; out=$(plain "$(diag_view)")
  unset -f read_key
  assert_match "$out" 'nothing needs your attention' "an empty panel is not a blank one"
  assert_not_match "$out" 'recoverable' "and no review section with nothing in it"
}

test_the_watch_stream_validates_its_interval() {
  # The same contract `json --watch` has: a bad interval is refused up front,
  # not turned into a busy loop nobody notices until the fan comes on.
  assert_fails diag_watch --interval 0
  assert_fails diag_watch --interval abc
  assert_fails diag_watch --interval
  assert_fails diag_watch --nonsense
}

run_tests
