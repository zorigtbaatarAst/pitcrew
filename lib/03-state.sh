#!/usr/bin/env bash
# lib/03-state.sh — is a component up/starting/crashed/down/n-a right now?
#
# No terminal multiplexer involved: every started component has a pidfile at
# .pitcrew/logs/<comp>.pid. A live pid + open port = up. A live pid with the
# port not open yet = still booting. A *stale* pidfile (recorded, now dead)
# = crashed. No pidfile at all = down. `stop_comp` removes the pidfile on a
# clean stop, which is exactly what makes a leftover one mean "it died".
#
# The classification itself now happens once per frame inside snapshot()
# (lib/03a-snapshot.sh); the functions here are lookups over its result. That
# matters because comp_state used to be recomputed two or three times per
# component per frame, each time re-opening a TCP socket and re-curling a
# health endpoint. Anything that loops over components calls snapshot() first.

read_pid() { local p=""; [ -r "$LOG_DIR/$1.pid" ] && read -r p < "$LOG_DIR/$1.pid" 2>/dev/null; printf '%s' "$p"; }

pid_alive() { local pid=$1; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }

be_health() { # $1 app → UP or DOWN, from the cached probe result
  printf '%s' "${SNAP_HEALTH[$1]:-UP}"
}

comp_state() { # pure lookup — call snapshot() before any loop over components
  case "$1" in
    dep-*) printf '%s' "${SNAP_DEP[${1#dep-}]:-down}" ;;
    *)     printf '%s' "${SNAP_STATE[$1]:-n/a}" ;;
  esac
}

is_external() { # $1 comp → true if something's on its port that pitcrew isn't tracking
  local c=$1 app=${1#??-} role=${1:0:2} port
  if [ "$role" = be ]; then port=${PITCREW_BE_PORT[$app]:-}; else port=${PITCREW_FE_PORT[$app]:-}; fi
  [ -n "$port" ] && [ -n "${SNAP_PORT_OPEN[$port]:-}" ] && ! pid_alive "${SNAP_PID[$c]:-}"
}

state_icon() { # $1 state → R (see the calling convention note in lib/04-meters.sh)
  case "$1" in
    up)       R="${C_OK}●${RESET}" ;;
    # a booting service is the one thing on screen that is actively changing,
    # so it is the one thing that should move. SPIN existed and was unused here.
    starting) R="${C_WARN}${SPIN[FRAME_N % 10]}${RESET}" ;;
    crashed)  R="${C_CRIT}✗${RESET}" ;;
    down)     R="${C_MUTED}○${RESET}" ;;
    *)        R="${DIM}${C_FAINT}·${RESET}" ;;
  esac
}

running_comps() {
  local c st
  snapshot
  for c in "${PITCREW_COMPS[@]}"; do
    st=${SNAP_STATE[$c]:-n/a}
    [ "$st" = up ] || [ "$st" = starting ] && printf '%s\n' "$c"
  done
  return 0
}
