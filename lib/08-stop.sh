#!/usr/bin/env bash
# lib/08-stop.sh — stopping components, tool-managed AND externally-started.

stop_comp() {
  local c=$1 stopped=0 pid
  pid=$(read_pid "$c")
  if [ "$HAS_SYSTEMD" = 1 ] && scope_exists "$c"; then
    systemctl --user stop "$SESSION-$c.scope" 2>/dev/null && stopped=1
  elif pid_alive "$pid"; then
    kill_tree "$pid"
    stopped=1
  fi
  rm -f "$LOG_DIR/$c.pid"
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
  # `--deps` means "everything, plus the containers"; a bare `deps` target
  # means "just the containers". The latter used to resolve to no components
  # and then stop nothing at all, exiting 0 — the command looked like it had
  # worked.
  local stop_deps=0 only_deps=0 raw=() w
  for w in "$@"; do
    case "$w" in
      --deps) stop_deps=1 ;;
      deps)   stop_deps=1; only_deps=1 ;;
      *)      raw+=("$w") ;;
    esac
  done
  [ ${#raw[@]} -eq 0 ] && [ $only_deps -eq 0 ] && raw=(all)
  local c
  if [ ${#raw[@]} -gt 0 ]; then
    local words; mapfile -t words < <(expand_profiles "${raw[@]}")
    local comps; mapfile -t comps < <(resolve_targets "${words[@]}")
    for c in "${comps[@]}"; do stop_comp "$c"; done
  fi
  if [ $stop_deps -eq 1 ]; then
    for c in "${PITCREW_DEPS[@]}"; do
      if [[ " ${PITCREW_PROTECTED_DEPS[*]} " == *" $c "* ]]; then
        say "  ${YELLOW}⚠${RESET} $c is protected — pitcrew never stops it (use docker directly if you really mean it)"
        continue
      fi
      docker stop "$c" >/dev/null 2>&1 && say "  ${GREY}■${RESET} stopped container $c"
    done
  fi
  say "  ${GREEN}done${RESET}"
}
