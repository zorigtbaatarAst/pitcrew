#!/usr/bin/env bash
# The performance contract, as a test.
#
# The dashboard's whole design rests on one invariant: a frame forks NOTHING.
# That is not a nice-to-have — it is why a sub-second refresh and per-service
# history are affordable at all, and it is fragile in a way ordinary review
# does not catch, because a single `$(helper)` looks harmless and costs a
# subshell 12 times a frame.
#
# Measured with a SIGCHLD trap, which counts this shell's child processes
# EXACTLY and is blind to anything else running on the machine.
#
# Two metrics were tried and rejected first. /proc/stat's `processes` counter
# is system-wide: this box forks ~175/s on its own, which swamps the signal.
# The `times` builtin measures child CPU *time*, so it misses the regression
# that matters most — a `$(helper)` around pure bash forks a subshell that
# burns no measurable CPU at all, and the budget passes while the dashboard
# forks on every row. Counting children catches both the cheap and the
# expensive kind.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

FRAMES=${FRAMES:-25}
LOG_DIR=$(mktemp -d)
TMP=$(mktemp)
PITCREW_DEP_INTERVAL=999999      # docker inspect is a fork by definition; not under test

# Every component needs a log AND a live process. Without a live pid the frame
# never takes the "service is up" branch — no tree walk, no per-process stats,
# no sparkline, no byte formatting — which is exactly where the per-component
# work lives. A budget measured against idle components would pass while the
# real dashboard forked on every row.
PERF_PIDS=()
for c in "${PITCREW_COMPS[@]}"; do
  printf 'boot line\nERROR seeded\n' > "$LOG_DIR/$c.log"
  sleep 300 & PERF_PIDS+=($!)
  echo $! > "$LOG_DIR/$c.pid"
done
_perf_cleanup() {
  err_close
  local p; for p in "${PERF_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  rm -rf "$LOG_DIR" "$TMP"
}

_forks_over() { # $1 = frames → FORKS, the number of children this shell spawned
  _forks_of "$1" _frame
}

_forks_of() { # $1 = iterations, $2... = what to run → FORKS
  local n=$1 i; shift
  FORKS=0
  trap 'FORKS=$((FORKS + 1))' CHLD
  for ((i = 0; i < n; i++)); do "$@" >/dev/null 2>&1; done
  trap - CHLD
}

_now_ms() { local e=${EPOCHREALTIME/,/.}; printf '%s' $(( ${e%.*} * 1000 + 10#${e#*.} / 1000 )); }

# The REAL frame, not an imitation of it. This used to be a hand-copied
# version of cmd_watch's loop body, which meant anything added to the dashboard
# afterwards — a footer, a header, a new column — sat outside the fork budget
# and could regress without failing anything. cmd_watch is now split so the
# test drives exactly what the dashboard drives.
PITCREW_COLS=140 PITCREW_LINES=40      # pin the frame size; see term_size()
_frame() { collect_frame; build_frame; }

test_the_fixture_actually_exercises_the_live_path() {
  # guards the guard: if this stops being true the fork budget below becomes
  # meaningless without failing
  _frame >/dev/null 2>&1
  local c live=0
  for c in "${PITCREW_COMPS[@]}"; do
    [ -n "${SNAP_RSS[$c]:-}" ] && [ "${SNAP_RSS[$c]:-0}" -gt 0 ] && live=$((live + 1))
  done
  assert_eq "$live" "${#PITCREW_COMPS[@]}" "components reporting live RSS"
}

test_a_frame_forks_nothing() {
  _frame >/dev/null 2>&1                       # warm-up: first frame opens log fds
  _forks_over "$FRAMES"
  # Zero is the real contract on /proc. The small allowance is only for a
  # background health probe landing mid-run; one stray $( ) per component would
  # be FRAMES × components. Before the collector rewrite a single frame was 431.
  #
  # The portable collector (what macOS runs, and what
  # PITCREW_FORCE_COLLECTOR=ps exercises here) cannot be fork-free: there is no
  # /proc to read, so it pays one `ps` and one port listing. Its contract is
  # that the cost is CONSTANT — two forks a frame no matter how many components
  # the project has. That is the number that has to hold; a per-component $( )
  # would sail past a flat "≤ 2 total" budget on this path.
  local budget=2 what="budget 2 total"
  if [ "$PITCREW_COLLECTOR" != proc ]; then
    # One `ps` and one port listing — and on a platform that cannot read its
    # memory gauge out of a file, one more for that. macOS has no
    # /proc/meminfo, so every frame there also pays a `vm_stat`: three, not
    # two. The budget said two and macOS has been failing this since it was
    # written, which is worse than useless — it is a red check nobody reads.
    #
    # PITCREW_SYS_CPU_SELF is exactly "this platform reads its gauges from a
    # file", so it is the right thing to key on rather than `uname`.
    local per=2 extra=""
    if [ "${PITCREW_SYS_CPU_SELF:-0}" != 1 ]; then
      per=3; extra=", one vm_stat"
    fi
    budget=$(( FRAMES * per + 2 ))
    what="budget $per per frame — one ps, one port listing$extra, independent of ${#PITCREW_COMPS[@]} components"
  fi
  [ "$FORKS" -le "$budget" ] \
    || _t_bad "$FORKS forks over $FRAMES frames ($what) — something in the frame path is forking"
  printf '      \033[90m%d frames, %d forks (%s collector)\033[0m\n' "$FRAMES" "$FORKS" "$PITCREW_COLLECTOR"
}

test_a_zen_frame_forks_nothing_either() {
  # Zen draws a different layout, not the same one with rows removed, so it is
  # a second frame path — and a second place for a $( ) to hide. `comp_state`
  # PRINTS its answer, which makes the natural `state_icon "$(comp_state ...)"`
  # one fork per row per frame; zen_row inlines the lookup instead, and this is
  # what keeps it that way.
  local saved=$ZEN
  ZEN=1
  _frame >/dev/null 2>&1
  _forks_over "$FRAMES"
  ZEN=$saved
  local budget=2
  [ "$PITCREW_COLLECTOR" != proc ] && budget=$(( FRAMES * 3 + 2 ))
  [ "$FORKS" -le "$budget" ] \
    || _t_bad "zen: $FORKS forks over $FRAMES frames (budget $budget)"
}

test_a_frame_is_fast_enough_for_a_sub_second_refresh() {
  _frame >/dev/null 2>&1
  local best=999999 i a d
  for ((i = 0; i < 10; i++)); do
    a=$(_now_ms); _frame >/dev/null 2>&1; d=$(( $(_now_ms) - a ))
    [ $d -lt $best ] && best=$d
  done
  # generous on purpose: this catches a catastrophic regression without
  # flapping on a loaded CI runner. The fork budget above is the sharp test.
  [ "$best" -le 250 ] || _t_bad "best frame took ${best}ms (budget 250ms)"
  printf '      \033[90mbest frame %dms\033[0m\n' "$best"
}

test_idle_logs_are_not_re_read_every_frame() {
  # the mtime marker must still skip untouched logs — without it 12 idle logs
  # cost ~7ms a frame doing nothing at all
  _frame >/dev/null 2>&1
  local fds_before fds_after c
  fds_before=""; for c in "${PITCREW_COMPS[@]}"; do fds_before+="${ERR_FD[$c]:-}"; done
  local i; for ((i = 0; i < 5; i++)); do err_scan; done
  fds_after=""; for c in "${PITCREW_COMPS[@]}"; do fds_after+="${ERR_FD[$c]:-}"; done
  assert_eq "$fds_after" "$fds_before" "log fds are reused, never reopened"
}

trap _perf_cleanup EXIT
test_the_json_writer_forks_nothing_either() {
  # `pitcrew json --watch` is the desktop app's whole data path and a status
  # line's polling loop, so it is a frame loop in every sense that matters —
  # but it was never held to the frame loop's contract.
  #
  # It escaped every field through `$(_json_str ...)`. Twelve components came
  # to 295 forks and 176ms an object, five times the cost of the entire
  # terminal frame, while the GUI consuming it rendered in 0.4ms. The same
  # work through a global is 14ms.
  #
  # A `$( )` around any of the encoders would put all of that straight back,
  # and it would be invisible: the output is identical either way.
  # Each object takes a snapshot, so the collector's own cost is allowed here
  # for the same reasons the frame budget allows it — and no more than that.
  local before=$FORKS objects=5 per=0 what="no forks at all"
  if [ "$PITCREW_COLLECTOR" != proc ]; then
    per=2; what="one ps and one port listing per object"
    [ "${PITCREW_SYS_CPU_SELF:-0}" = 1 ] || { per=3; what="$what, one vm_stat"; }
  fi
  _forks_of "$objects" cmd_json
  [ "$FORKS" -le $(( objects * per + 2 )) ] \
    || _t_bad "$FORKS forks over $objects json objects ($what) — an encoder is being called as \$( )"
  printf '      \033[90m%d objects, %d forks (%s)\033[0m\n' "$objects" "$FORKS" "$PITCREW_COLLECTOR"
  FORKS=$before
}

test_the_json_encoders_set_a_global_rather_than_printing() {
  # The convention, stated as an assertion. An encoder that PRINTS is only
  # usable through a subshell, so the two facts are the same fact — and the
  # next person to add a field will copy whatever the neighbouring line does.
  local out
  out=$(_json_str 'a"b'; printf '|%s' "$JSTR")
  assert_eq "$out" '|"a\"b"' "_json_str sets JSTR and prints nothing"
  out=$(_json_num ""; printf '|%s' "$JNUM")
  assert_eq "$out" '|null' "_json_num sets JNUM and prints nothing"
  out=$(comp_max_source "${PITCREW_COMPS[0]}"; printf '|%s' "$MAXSRC")
  assert_eq "$out" '|role' "comp_max_source sets MAXSRC and prints nothing"
}

run_tests
