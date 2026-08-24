#!/usr/bin/env bash
# Profiles: saved sets of TARGET WORDS, and what they mean today.
#
# `profile list` used to print the file back at you — the words you already
# typed — which answers none of the questions you open it to ask: how many
# components is that, how much of it is already running, what will it cost,
# and does it still work at all.
#
# That last one matters more than it sounds. A profile holds words, not
# components, on purpose: "sales" keeps covering sales when the app grows a
# worker. The cost is that a profile can rot — rename an app and the file still
# names the old one, and `pitcrew start @that` dies on an unknown target. So
# everything here reports what a profile resolves to NOW, missing words
# included.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
SELF="$PITCREW_DIR/bin/pitcrew"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

# The harness points PITCREW_HOME at a temp dir. PROFILE_DIR has to follow it —
# it did not, and a test run wrote saved profiles into the developer's real
# ~/.config/pitcrew for keeps.
_profile() { # $1 name, $2.. target words
  local name=$1; shift
  mkdir -p "$PROFILE_DIR"
  printf '%s\n' "$@" > "$PROFILE_DIR/$name"
}

_clear() { rm -rf "$PROFILE_DIR"; }

test_the_profile_directory_follows_pitcrew_home() {
  # Not $HOME. LIMITS_FILE two files over already honoured PITCREW_HOME and
  # this did not, so every profile test scribbled on the real config.
  assert_match "$PROFILE_DIR" "^$PITCREW_HOME/" "profiles live under PITCREW_HOME"
}

# ── what a profile resolves to ──────────────────────────────────────────────

test_a_word_is_resolved_the_way_a_target_is() {
  _clear
  _profile mixed both be-beonly frontends
  profile_resolve mixed
  assert_match "${PROFILE_COMPS[*]}" 'be-both'   "an app brings its whole group"
  assert_match "${PROFILE_COMPS[*]}" 'fe-both'
  assert_match "${PROFILE_COMPS[*]}" 'be-beonly' "a component named outright"
  assert_match "${PROFILE_COMPS[*]}" 'fe-feonly' "and a role across every app"
  _clear
}

test_a_component_named_twice_appears_once() {
  _clear
  _profile dupes both be-both be-both
  profile_resolve dupes
  local n; n=$(printf '%s\n' "${PROFILE_COMPS[@]}" | grep -c '^be-both$')
  assert_eq "$n" "1" "deduped, like resolve_targets"
  _clear
}

test_a_word_that_names_nothing_is_reported_not_fatal() {
  # resolve_targets die()s on an unknown target, which is right for something
  # somebody typed and quite wrong here: `pitcrew json --watch` reports every
  # profile every frame, and one rotted profile must not take the dashboard
  # down with it.
  _clear
  _profile rotted both ghost-app
  profile_resolve rotted
  assert_eq "${PROFILE_MISSING[*]}" "ghost-app" "the word is named"
  assert_match "${PROFILE_COMPS[*]}" 'be-both'  "and the rest still resolves"
  _clear
}

test_a_profile_keeps_meaning_what_you_meant_as_the_app_grows() {
  # The reason a profile stores words and not components. "both" covers
  # whatever both has today — that is the whole design, and it is why the
  # stats have to be computed rather than saved alongside.
  _clear
  _profile grow both
  profile_resolve grow
  local before=${#PROFILE_COMPS[@]}
  PITCREW_APP_ROLES[both]="${PITCREW_APP_ROLES[both]} worker"
  PITCREW_CMD[worker-both]="true"
  mapfile -t PITCREW_COMPS < <(all_components)
  profile_resolve grow
  assert_eq "${#PROFILE_COMPS[@]}" "$(( before + 1 ))" "the new role is covered"
  assert_match "${PROFILE_COMPS[*]}" 'worker-both' "without touching the file"
  # put the model back
  PITCREW_APP_ROLES[both]="be fe"
  unset 'PITCREW_CMD[worker-both]'
  mapfile -t PITCREW_COMPS < <(all_components)
  _clear
}

# ── the stats ───────────────────────────────────────────────────────────────

test_the_stats_say_how_much_of_it_is_already_running() {
  _clear
  _profile core both be-beonly
  SNAP_STATE=([be-both]=up [fe-both]=down [be-beonly]=starting)
  SNAP_RSS=([be-both]=1048576)
  profile_stat core
  assert_eq "$PSTAT_TOTAL"    3         "three components"
  assert_eq "$PSTAT_UP"       1         "one up"
  assert_eq "$PSTAT_STARTING" 1         "one on its way"
  assert_eq "$PSTAT_RSS"      1048576   "and what they are holding"
  [ "$PSTAT_CAP" -gt 0 ] || _t_bad "the committed cap should be the sum of their limits"
  SNAP_STATE=(); SNAP_RSS=()
  _clear
}

test_something_else_on_the_port_counts_as_up() {
  # `external` means the port answers and pitcrew did not start it. For "is
  # this profile already running" that is a yes — starting it again would just
  # fail on a taken port.
  _clear
  _profile core both
  SNAP_STATE=([be-both]=external [fe-both]=down)
  profile_stat core
  assert_eq "$PSTAT_UP" 1 "external counts"
  SNAP_STATE=()
  _clear
}

test_the_ports_a_profile_claims_are_part_of_the_answer() {
  _clear
  _profile core both
  profile_stat core
  assert_match "$PSTAT_PORTS" '19801' "the backend port"
  assert_match "$PSTAT_PORTS" '19802' "and the frontend one"
  _clear
}

# ── the commands ────────────────────────────────────────────────────────────

test_list_says_what_each_profile_is_doing_not_what_you_typed() {
  _clear
  _profile core both
  local out; out=$(plain "$(cmd_profile list)")
  assert_match "$out" '@core'    "the name"
  assert_match "$out" '0/2 up'   "and what it is doing"
  assert_match "$out" ':19801'   "and the ports it claims"
  _clear
}

test_list_flags_a_profile_that_can_no_longer_start() {
  _clear
  _profile rotted both ghost-app
  local out; out=$(plain "$(cmd_profile list)")
  assert_match "$out" 'ghost-app no longer exists' "named on the row"
  assert_match "$out" 'will not start'             "and what that means"
  _clear
}

test_show_lists_every_component_and_what_it_would_commit() {
  _clear
  _profile core both be-beonly
  local out; out=$(plain "$(cmd_profile show core)")
  assert_match "$out" 'saved as .*both be-beonly' "the words, as saved"
  assert_match "$out" 'be-both'                   "and every component they cover"
  assert_match "$out" 'fe-both'
  assert_match "$out" 'be-beonly'
  assert_match "$out" 'commits .* if every component reaches its cap' "and the budget"
  _clear
}

test_no_profiles_says_how_to_make_one() {
  _clear
  local out; out=$(plain "$(cmd_profile list)")
  assert_match "$out" 'no profiles yet' "not an error"
  assert_match "$out" 'profile save'    "and the way to make one"
}

test_show_and_rm_refuse_a_name_that_is_not_there() {
  _clear
  assert_fails cmd_profile show nosuch
  assert_fails cmd_profile rm nosuch
}

test_a_profile_name_cannot_escape_its_directory() {
  # The name becomes a filename. Writing somewhere else entirely is not a thing
  # a save command should be able to do.
  _clear
  assert_fails cmd_profile save ../escape both
  assert_fails cmd_profile save . both
  [ -e "$PROFILE_DIR/../escape" ] && _t_bad "a file was written outside the profile directory"
  _clear
}

# ── the stream ──────────────────────────────────────────────────────────────

test_the_stream_carries_what_a_profile_covers() {
  # The desktop app draws profile rows from this and nothing else. Reading
  # pitcrew's directory itself is what it used to do, and a directory listing
  # cannot know that "sales" now covers a worker.
  command -v python3 >/dev/null 2>&1 || return 0
  _clear
  _profile core both
  _profile rotted ghost-app
  # no_cr: the assertion below anchors on a line boundary, and a native Windows
  # python writes CRLF into this pipe. See harness.sh.
  local out; out=$(no_cr "$(cmd_json | python3 -c '
import json, sys
d = json.load(sys.stdin)
for p in sorted(d["profiles"], key=lambda x: x["name"]):
    print(p["name"], p["total"], p["up"], ",".join(p["components"]), ",".join(p["missing"]))
')")
  assert_match "$out" $'(^|\n)core 2 0 be-both,fe-both (\n|$)' "resolved, counted, and named"
  assert_match "$out" 'rotted 0 0  ghost-app' "and a rotted one says which word died"
  _clear
}

test_reporting_every_profile_every_frame_costs_no_forks() {
  # `pitcrew json --watch` is what the desktop app runs, and it emits one of
  # these per interval. A fork per profile per frame is exactly the cost the
  # rest of the collector goes to such lengths to avoid.
  _clear
  _profile a both
  _profile b beonly feonly
  _profile c all
  # Counted the way test/perf_test.sh counts: a SIGCHLD trap. Field 10 of
  # /proc/self/stat is minflt, not a child count, and reading it here reported
  # thirty-five forks that never happened.
  local forks=0 i n
  trap 'forks=$((forks + 1))' CHLD
  for ((i = 0; i < 5; i++)); do
    profile_names_arr
    for n in "${PROFILE_NAMES[@]}"; do profile_stat "$n"; done
  done
  trap - CHLD
  [ "$forks" -eq 0 ] || _t_bad "15 profile stats forked $forks times"
  _clear
}

run_tests
