#!/usr/bin/env bash
# lib/07b-supervise.sh — optional auto-restart for components that die.
#
# Scope, deliberately: this runs inside the live dashboard's frame loop, not in
# a daemon. pitcrew has no session and nothing to attach to, and adding a
# background supervisor would mean inventing one — a pidfile for the
# supervisor, a way to stop it, a way to notice it died. Restarting while
# you're watching covers the case that actually hurts (a service dies during a
# long session and sits red until you happen to look) without that machinery.
# `pitcrew doctor` says whether it is on, so the limitation is never a surprise.
#
# Backoff is exponential and capped by an attempt budget, because the failure
# mode of naive auto-restart is worse than no auto-restart: a service that
# crashes on a syntax error gets restarted forever, and the log you need is
# buried under a thousand identical boot attempts.

PITCREW_RESTART="${PITCREW_RESTART:-0}"                   # 1 = bring crashed components back
PITCREW_RESTART_BACKOFF="${PITCREW_RESTART_BACKOFF:-2}"   # base delay, doubling per attempt
PITCREW_RESTART_MAX="${PITCREW_RESTART_MAX:-5}"           # attempts before giving up
PITCREW_RESTART_RESET="${PITCREW_RESTART_RESET:-60}"      # seconds up before the count clears

declare -gA RESTART_N=()       # comp -> attempts used in the current crash streak
declare -gA RESTART_AT=()      # comp -> epoch at which the next attempt is due
declare -gA RESTART_GAVEUP=()  # comp -> set once the budget is exhausted
declare -gA UP_SINCE=()        # comp -> epoch it last became healthy

supervise_clear() { # forget a component's crash history (manual restart = a fresh start)
  unset "RESTART_N[$1]" "RESTART_AT[$1]" "RESTART_GAVEUP[$1]" "UP_SINCE[$1]"
  return 0
}

supervise() { # called once per frame; a no-op unless PITCREW_RESTART=1
  [ "${PITCREW_RESTART:-0}" = 1 ] || return 0
  local c st now=${SNAP_NOW_S:-0} n wait
  for c in "${PITCREW_COMPS[@]}"; do
    st=${SNAP_STATE[$c]:-n/a}

    if [ "$st" = up ]; then
      [ -n "${UP_SINCE[$c]:-}" ] || UP_SINCE[$c]=$now
      # Staying healthy is what earns the budget back. Without this, a service
      # that crashes once a week eventually exhausts its attempts and stops
      # being restarted at all.
      if [ $(( now - ${UP_SINCE[$c]} )) -ge "$PITCREW_RESTART_RESET" ]; then
        unset "RESTART_N[$c]" "RESTART_AT[$c]" "RESTART_GAVEUP[$c]"
      fi
      continue
    fi
    unset "UP_SINCE[$c]"
    [ "$st" = crashed ] || continue          # starting: leave it alone. down: not ours.
    [ -n "${RESTART_GAVEUP[$c]:-}" ] && continue

    n=${RESTART_N[$c]:-0}
    if [ "$n" -ge "$PITCREW_RESTART_MAX" ]; then
      RESTART_GAVEUP[$c]=1
      unset "RESTART_AT[$c]"
      toast "${RED}✗${RESET} ${BOLD}$c${RESET} keeps crashing — gave up after $n restarts (${MAGENTA}r${RESET} to try again)"
      continue
    fi

    # First sighting of this crash only schedules the attempt; the restart
    # itself happens on a later frame once the backoff has elapsed.
    if [ -z "${RESTART_AT[$c]:-}" ]; then
      wait=$(( PITCREW_RESTART_BACKOFF * (1 << n) ))
      RESTART_AT[$c]=$(( now + wait ))
      continue
    fi
    [ "$now" -ge "${RESTART_AT[$c]}" ] || continue

    RESTART_N[$c]=$(( n + 1 ))
    unset "RESTART_AT[$c]"
    stop_comp "$c" >/dev/null 2>&1
    start_comp "$c" >/dev/null 2>&1
    toast "${YELLOW}↻${RESET} auto-restarting ${BOLD}$c${RESET} ${GREY}(attempt ${RESTART_N[$c]}/${PITCREW_RESTART_MAX})${RESET}"
  done
  return 0
}
