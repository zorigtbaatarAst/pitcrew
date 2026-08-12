#!/usr/bin/env bash
# lib/07-stop.sh — stopping components, tool-managed AND externally-started.

stop_comp() {
  local c=$1 stopped=0
  systemctl --user stop "$SESSION-$c.scope" 2>/dev/null && stopped=1
  if win_exists "$c"; then
    tmux kill-window -t "$SESSION:$c" 2>/dev/null
    stopped=1
  fi
  [ $stopped -eq 1 ] && say "  ${GREY}■${RESET} stopped $c"
  # the same service may still be running from outside the tool — stop by port
  local port; port=$(comp_port "$c")
  if port_open "$port"; then
    if kill_port "$port"; then
      say "  ${GREY}■${RESET} stopped external $c ${GREY}(was started outside pitcrew, port $port)${RESET}"
    else
      warn "$c: something still listens on :$port and could not be stopped"
    fi
  fi
}

cmd_stop() {
  local stop_deps=0 raw=()
  local w
  for w in "$@"; do [ "$w" = "--deps" ] && stop_deps=1 || raw+=("$w"); done
  [ ${#raw[@]} -eq 0 ] && raw=(all)
  local words; mapfile -t words < <(expand_profiles "${raw[@]}")
  local comps; mapfile -t comps < <(resolve_targets "${words[@]}")
  local c
  for c in "${comps[@]}"; do stop_comp "$c"; done
  if [ $stop_deps -eq 1 ]; then
    for c in "${PITCREW_DEPS[@]}"; do
      if [[ " ${PITCREW_PROTECTED_DEPS[*]} " == *" $c "* ]]; then
        say "  ${YELLOW}⚠${RESET} $c is protected — pitcrew never stops it (use docker directly if you really mean it)"
        continue
      fi
      docker stop "$c" >/dev/null 2>&1 && say "  ${GREY}■${RESET} stopped container $c"
    done
  fi
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    [ "$(tmux list-windows -t "$SESSION" -F '#W' | grep -cv '^_')" -eq 0 ] \
      && tmux kill-session -t "$SESSION" 2>/dev/null
  fi
  say "  ${GREEN}done${RESET}"
}
