#!/usr/bin/env bash
# lib/03-state.sh — is a component up/starting/crashed/down/n-a right now?
#
# No terminal multiplexer involved: every started component has a pidfile at
# .pitcrew/logs/<comp>.pid. A live pid + open port = up. A live pid with the
# port not open yet = still booting. A *stale* pidfile (recorded, now dead)
# = crashed. No pidfile at all = down. `stop_comp` removes the pidfile on a
# clean stop, which is exactly what makes a leftover one mean "it died".

read_pid() { cat "$LOG_DIR/$1.pid" 2>/dev/null; }

pid_alive() { local pid=$1; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }

be_health() { # $1 app → UP or DOWN, via the configured actuator-style health path
  # NOTE: `app` must be its own `local` statement — bash expands the RHS of every
  # name=value in one `local ...` command against the PRE-statement scope, so a
  # combined `local app=$1 path=${MAP[$app]}` reads $app from before this call.
  local app=$1
  local path=${PITCREW_BE_HEALTH_PATH[$app]:-} port=${PITCREW_BE_PORT[$app]:-}
  [ -n "$path" ] && [ -n "$port" ] || { echo UP; return; }   # no health path configured → port-open is enough
  curl -sf -m 2 "http://127.0.0.1:${port}${path}" 2>/dev/null \
    | grep -q '"UP"' && echo UP || echo DOWN
}

comp_state() {
  local c=$1
  case "$c" in
    be-*|fe-*)
      local app=${c#??-}
      local role=${c:0:2}
      app_has_role "$app" "$role" || { echo n/a; return; }
      local port; port=$(comp_port "$c")
      local pid; pid=$(read_pid "$c")
      if port_open "$port"; then
        if [ "$role" = be ] && [ "$(be_health "$app")" != UP ]; then echo starting; else echo up; fi
      elif pid_alive "$pid"; then
        echo starting                # process is up, port not open yet — still booting
      elif [ -n "$pid" ]; then
        echo crashed                  # pidfile recorded, process is gone — died on its own
      else
        echo down
      fi ;;
    dep-*)
      container_running "${c#dep-}" && echo up || echo down ;;
  esac
}

is_external() { # $1 comp → true if something's on its port that pitcrew isn't tracking
  local c=$1 pid; pid=$(read_pid "$c")
  port_open "$(comp_port "$c")" && ! pid_alive "$pid"
}

state_icon() {
  case "$1" in
    up)       printf '%b' "${GREEN}●${RESET}" ;;
    starting) printf '%b' "${YELLOW}◐${RESET}" ;;
    crashed)  printf '%b' "${RED}✗${RESET}" ;;
    down)     printf '%b' "${GREY}○${RESET}" ;;
    n/a)      printf '%b' "${DIM}${GREY}·${RESET}" ;;
  esac
}

running_comps() {
  local c st
  while IFS= read -r c; do
    st=$(comp_state "$c")
    [ "$st" = up ] || [ "$st" = starting ] && echo "$c"
  done < <(all_components)
}
