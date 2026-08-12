#!/usr/bin/env bash
# lib/12-menu.sh — interactive fzf menu, URL printing/opening.

print_urls() {
  say ""
  say "  ${BOLD}URLs${RESET}"
  local app fe be
  for app in "${PITCREW_APPS[@]}"; do
    fe="${PITCREW_FE_PORT[$app]:-}"; be="${PITCREW_BE_PORT[$app]:-}"
    if [ -n "$fe" ]; then
      printf '    %b%-12s%b %bhttp://localhost:%s%b' "$CYAN" "$app" "$RESET" "$BLUE" "$fe" "$RESET"
    else
      printf '    %b%-12s%b %b(no frontend)%b' "$CYAN" "$app" "$RESET" "$GREY" "$RESET"
    fi
    [ -n "$be" ] && printf '   %bapi → http://localhost:%s%s%b' "$GREY" "$be" "${PITCREW_URL_PATH[$app]:-}" "$RESET"
    printf '\n'
  done
  say ""
}

cmd_urls() {
  print_urls
  command -v xdg-open >/dev/null || return 0
  local app fe
  for app in "${PITCREW_APPS[@]}"; do
    fe="${PITCREW_FE_PORT[$app]:-}"
    [ -n "$fe" ] && xdg-open "http://localhost:$fe" >/dev/null 2>&1 &
  done
}

pick_apps() {
  printf '%s\n' "${PITCREW_APPS[@]}" | fzf --multi --height=40% --border=rounded \
    --prompt='apps ❯ ' --pointer='▶' --marker='✔ ' \
    --header='TAB = select several · Enter = confirm · Esc = cancel'
}

menu() {
  command -v fzf >/dev/null || die "interactive menu needs fzf (or use: pitcrew start|stop|status)"
  while true; do
    clear
    banner
    status_table
    echo; hr
    local choice
    choice=$(printf '%s\n' \
      '🚀  start EVERYTHING' \
      '▶   start selected apps…' \
      '📦  start a saved profile…' \
      '💾  save running apps as a profile…' \
      '🧩  start backends only' \
      '🎨  start frontends only' \
      '🔄  restart selected apps…' \
      '♻   restart stale apps (code changed since start)' \
      '⏹   stop all apps (keep deps running)' \
      '🛑  stop everything (apps + deps)' \
      '📡  live dashboard (watch mode)' \
      '🧾  log grid — all services tiled in one screen' \
      '📜  view logs of one service…' \
      '🍃  open a configured shell…' \
      '🩺  doctor — check my environment' \
      '🖥   attach to tmux session' \
      '🌐  open all frontend URLs' \
      '↻   refresh status' \
      '✖   quit' \
      | fzf --height=65% --border=rounded --ansi --prompt='pitcrew ❯ ' \
            --pointer='▶' --header='what do you want to do?') || break
    case "$choice" in
      🚀*) cmd_start all; read -rp "  press Enter…" ;;
      ▶*)  local sel; sel=$(pick_apps) || true
           [ -n "${sel:-}" ] && { cmd_start $sel; read -rp "  press Enter…"; } ;;
      📦*) local prof; prof=$(pick_profile) || { warn "no profiles yet — save one first"; sleep 2; continue; }
           [ -n "${prof:-}" ] && { cmd_start "@$prof"; read -rp "  press Enter…"; } ;;
      💾*) local running; running=$(running_comps | tr '\n' ' ')
           if [ -z "$running" ]; then warn "nothing is running to save"; sleep 2; continue; fi
           say "  running now: ${CYAN}$running${RESET}"
           local pname; read -rp "  profile name: " pname
           [ -n "$pname" ] && { cmd_profile save "$pname" $running; sleep 1; } ;;
      🧩*) cmd_start backends;  read -rp "  press Enter…" ;;
      🎨*) cmd_start frontends; read -rp "  press Enter…" ;;
      🔄*) local sel; sel=$(pick_apps) || true
           [ -n "${sel:-}" ] && { cmd_stop $sel; cmd_start $sel; read -rp "  press Enter…"; } ;;
      ♻*)  cmd_stale --restart; read -rp "  press Enter…" ;;
      ⏹*)  cmd_stop all; sleep 1 ;;
      🛑*) cmd_stop all --deps; sleep 1 ;;
      📡*) cmd_watch ;;
      🧾*) cmd_grid ;;
      📜*) cmd_logs ;;
      🍃*) if [ ${#PITCREW_SHELLS[@]} -eq 0 ]; then warn "no shells configured (set PITCREW_SHELLS)"; sleep 2; continue; fi
           local shname; shname=$(printf '%s\n' "${!PITCREW_SHELLS[@]}" | fzf --height=30% --border=rounded --prompt='shell ❯ ') || true
           [ -n "${shname:-}" ] && cmd_shell "$shname" ;;
      🩺*) cmd_doctor; read -rp "  press Enter…" ;;
      🖥*)  tmux has-session -t "$SESSION" 2>/dev/null && attach_to "$SESSION" || { say "nothing running"; sleep 1; } ;;
      🌐*) cmd_urls; sleep 1 ;;
      ↻*)  : ;;
      ✖*)  break ;;
      *)   break ;;
    esac
  done
  clear
}
