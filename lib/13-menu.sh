#!/usr/bin/env bash
# lib/13-menu.sh — the fzf action picker, in two forms sharing one choice
# list and one dispatcher:
#   menu()       — standalone entry (`pitcrew menu`): clears the screen,
#                  prints its own status table, loops until closed.
#   watch_menu() — opened with 'm' from the live dashboard (05-dashboard.sh).
#                  Never leaves the dashboard's screen/alt-buffer — it's a
#                  togglable section under the already-live view, not a
#                  separate screen you switch to. Closes back to the same
#                  live dashboard, which was never actually left.

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
  local opener=""
  if command -v xdg-open >/dev/null; then opener=xdg-open
  elif command -v open >/dev/null; then opener=open   # macOS
  else return 0; fi
  local app fe
  for app in "${PITCREW_APPS[@]}"; do
    fe="${PITCREW_FE_PORT[$app]:-}"
    [ -n "$fe" ] && "$opener" "http://localhost:$fe" >/dev/null 2>&1 &
  done
}

pick_apps() {
  printf '%s\n' "${PITCREW_APPS[@]}" | fzf --multi --height=40% --border=rounded \
    --prompt='apps ❯ ' --pointer='▶' --marker='✔ ' \
    --header='TAB = select several · Enter = confirm · Esc = cancel'
}

menu_choices() { # $1 = "overlay" trims entries that are meaningless inside the watch overlay
  local items=(
    '🚀  start EVERYTHING'
    '▶   start selected apps…'
    '📦  start a saved profile…'
    '💾  save running apps as a profile…'
    '🧩  start backends only'
    '🎨  start frontends only'
    '🔄  restart selected apps…'
    '♻   restart stale apps (code changed since start)'
    '⏹   stop all apps (keep deps running)'
    '🛑  stop everything (apps + deps)'
  )
  [ "${1:-}" = overlay ] || items+=('📡  live dashboard (watch mode)')
  items+=(
    '📜  view logs of one service…'
    '🍃  open a configured shell…'
    '🩺  doctor — check my environment'
    '🌐  open all frontend URLs'
  )
  [ "${1:-}" = overlay ] || items+=('↻   refresh status')
  items+=('✖   close menu')
  printf '%s\n' "${items[@]}"
}

# ── actions taken from inside the live dashboard ────────────────────────────
# The frame owns the screen, so nothing here may print. Each one does the work
# silently, leaves a toast, and closes the picker — cmd_watch then repaints and
# you watch the components go ○ down → ◐ starting → ● up in the dashboard
# itself, which is the whole point of having one.
#
# This is what used to break: cmd_start wrote a banner, a "launched X" list, a
# whole boot dashboard and a URL table straight over the live frame, then
# blocked on "press Enter", then reopened the picker — so the monitor was gone
# and did not come back.

ov_deps() { # start docker deps quietly; returns 1 only if docker really can't
  [ ${#PITCREW_DEPS[@]} -gt 0 ] || return 0
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    toast "${RED}✗${RESET} docker is not available — deps not started"
    return 1
  fi
  # start_deps can die() on its own; keep that inside a subshell so it can
  # never take the dashboard down with it
  ( start_deps ) >/dev/null 2>&1 || true
  SNAP_DEP_AT=0                     # make the next frame re-check dep state
  return 0
}

ov_start() { # $@ = targets
  MENU_CLOSE=1
  ov_deps || return 0
  start_targets "$@" >/dev/null 2>&1
  if [ ${#STARTED[@]} -eq 0 ]; then toast "${GREY}nothing to start${RESET}"; return 0; fi
  toast "${YELLOW}▶${RESET} starting ${BOLD}${STARTED[*]}${RESET}"
}

ov_stop() { # $@ = targets, may include --deps
  MENU_CLOSE=1
  cmd_stop "$@" >/dev/null 2>&1
  SNAP_DEP_AT=0
  toast "${GREY}■${RESET} stopped ${BOLD}${*:-all}${RESET}"
}

ov_restart() { # $@ = targets
  MENU_CLOSE=1
  cmd_stop "$@" >/dev/null 2>&1
  start_targets "$@" >/dev/null 2>&1
  toast "${YELLOW}↻${RESET} restarting ${BOLD}${STARTED[*]}${RESET}"
}

ov_stale() {
  MENU_CLOSE=1
  local stale; mapfile -t stale < <(stale_comps)
  if [ ${#stale[@]} -eq 0 ]; then toast "${GREEN}✔${RESET} everything is fresh"; return 0; fi
  local c
  for c in "${stale[@]}"; do stop_comp "$c" >/dev/null 2>&1; done
  for c in "${stale[@]}"; do start_comp "$c" >/dev/null 2>&1; done
  toast "${YELLOW}↻${RESET} restarted stale ${BOLD}${stale[*]}${RESET}"
}

# Runs one chosen action. Sets MENU_CLOSE=1 when the picker loop (either
# menu() or watch_menu()) should stop reopening.
#   $1 = the chosen line
#   $2 = "overlay" when this came from the live dashboard
dispatch_choice() {
  local choice=$1 mode=${2:-} sel prof running pname shname
  MENU_CLOSE=0
  case "$choice" in
    🚀*) if [ "$mode" = overlay ]; then ov_start all
         else cmd_start all; read -rp "  press Enter…"; fi ;;
    ▶*)  sel=$(pick_apps) || true
         [ -n "${sel:-}" ] || return 0
         if [ "$mode" = overlay ]; then ov_start $sel
         else cmd_start $sel; read -rp "  press Enter…"; fi ;;
    📦*) prof=$(pick_profile) || { warn "no profiles yet — save one first"; sleep 2; return 0; }
         [ -n "${prof:-}" ] || return 0
         if [ "$mode" = overlay ]; then ov_start "@$prof"
         else cmd_start "@$prof"; read -rp "  press Enter…"; fi ;;
    💾*) running=$(running_comps | tr '\n' ' ')
         if [ -z "$running" ]; then warn "nothing is running to save"; sleep 2; return 0; fi
         say "  running now: ${CYAN}$running${RESET}"
         read -rp "  profile name: " pname
         [ -n "$pname" ] && { cmd_profile save "$pname" $running; sleep 1; } ;;
    🧩*) if [ "$mode" = overlay ]; then ov_start backends
         else cmd_start backends; read -rp "  press Enter…"; fi ;;
    🎨*) if [ "$mode" = overlay ]; then ov_start frontends
         else cmd_start frontends; read -rp "  press Enter…"; fi ;;
    🔄*) sel=$(pick_apps) || true
         [ -n "${sel:-}" ] || return 0
         if [ "$mode" = overlay ]; then ov_restart $sel
         else cmd_stop $sel; cmd_start $sel; read -rp "  press Enter…"; fi ;;
    ♻*)  if [ "$mode" = overlay ]; then ov_stale
         else cmd_stale --restart; read -rp "  press Enter…"; fi ;;
    ⏹*)  if [ "$mode" = overlay ]; then ov_stop all
         else cmd_stop all; sleep 1; fi ;;
    🛑*) if [ "$mode" = overlay ]; then ov_stop all --deps
         else cmd_stop all --deps; sleep 1; fi ;;
    📡*) cmd_watch ;;
    📜*) cmd_logs ;;
    🍃*) if [ ${#PITCREW_SHELLS[@]} -eq 0 ]; then warn "no shells configured (set PITCREW_SHELLS)"; sleep 2; return 0; fi
         shname=$(printf '%s\n' "${!PITCREW_SHELLS[@]}" | fzf --height=30% --border=rounded --prompt='shell ❯ ') || true
         [ -n "${shname:-}" ] && { clear; cmd_shell "$shname"; read -rp "  press Enter…"; } ;;
    🩺*) cmd_doctor; read -rp "  press Enter…" ;;
    🌐*) cmd_urls
         if [ "$mode" = overlay ]; then toast "${BLUE}🌐${RESET} opened frontend URLs"; MENU_CLOSE=1; else sleep 1; fi ;;
    ↻*)  : ;;
    *)   MENU_CLOSE=1 ;;   # ✖ close menu, Esc/empty choice, or anything unrecognized
  esac
  return 0
}

menu() {
  command -v fzf >/dev/null || die "interactive menu needs fzf (or use: pitcrew start|stop|status)"
  local choice
  while true; do
    clear
    banner
    status_table
    echo; hr
    choice=$(menu_choices | fzf --height=65% --border=rounded --ansi --prompt='pitcrew ❯ ' \
             --pointer='▶' --header='what do you want to do?') || break
    dispatch_choice "$choice"
    [ "$MENU_CLOSE" = 1 ] && break
  done
  clear
}

# Opened with 'm' from the live dashboard. Stays in the SAME screen — no
# clear, no leaving the alt-buffer — so the dashboard is never "switched
# away from"; this is just a togglable section under it.
watch_menu() {
  command -v fzf >/dev/null || return
  tui_pause
  printf '\n\n%b── menu %b\n' "$GREY" "$RESET"
  local choice
  while true; do
    choice=$(menu_choices overlay | fzf --height=50% --border=rounded --ansi --prompt='pitcrew ❯ ' \
             --pointer='▶' --header='pick an action · Esc to close') || break
    dispatch_choice "$choice" overlay
    [ "$MENU_CLOSE" = 1 ] && break
  done
  tui_resume
}
