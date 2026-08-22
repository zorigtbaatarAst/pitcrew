#!/usr/bin/env bash
# lib/13-menu.sh — the action picker, in two forms sharing one choice list and
# one dispatcher. Both go through pick() (lib/01-core.sh), which is fzf where
# fzf is installed and a numbered prompt where it is not — a stock macOS has no
# fzf, and this menu is not optional there:
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
  printf '%s\n' "${PITCREW_APPS[@]}" | pick --multi --height 40% \
    --prompt 'apps ❯ ' \
    --header 'TAB = select several · Enter = confirm · Esc = cancel'
}

# Each entry is "key<TAB>label". The picker displays only the label but returns
# the whole line, so dispatch happens on the key.
#
# This used to dispatch on the leading emoji, which quietly broke the moment
# two entries shared one: `case` takes the first match, so "change theme" ran
# "start frontends only" and looked like it did nothing at all. A key is
# unique on purpose, and menu_keys_test.sh fails if one is ever duplicated or
# left without a dispatch arm.
menu_choices() { # $1 = "overlay" trims entries meaningless inside the watch overlay
  local items=(
    $'start-all\t🚀  start EVERYTHING'
    $'start-apps\t▶   start selected apps…'
    $'start-profile\t📦  start a saved profile…'
    $'save-profile\t💾  save running apps as a profile…'
    $'start-be\t🧩  start backends only'
    $'start-fe\t🎨  start frontends only'
    $'restart-apps\t🔄  restart selected apps…'
    $'restart-stale\t♻   restart stale apps (code changed since start)'
    $'stop-apps\t⏹   stop all apps (keep deps running)'
    $'stop-all\t🛑  stop everything (apps + deps)'
  )
  [ "${1:-}" = overlay ] || items+=($'watch\t📡  live dashboard (watch mode)')
  items+=(
    $'logs\t📜  view logs of one service…'
    $'shell\t🍃  open a configured shell…'
    $'switch\t🗂   switch project…'
    $'theme\t🌈  change theme…'
    $'render\t📈  graph & gauge style…'
    $'limits\t🧠  RAM caps…'
    $'zen\t🧘  zen — hide everything that is fine'
    $'diagnose\t🔎  diagnose — what is wrong with the stack'
    $'doctor\t🩺  doctor — check my environment'
    $'urls\t🌐  open all frontend URLs'
  )
  [ "${1:-}" = overlay ] || items+=($'refresh\t↻   refresh status')
  items+=($'close\t✖   close menu')
  printf '%s\n' "${items[@]}"
}

menu_keys() { menu_choices "${1:-}" | cut -f1; }

# The picker shows the label and hands back the key with it. `pick` is fzf
# where fzf exists and a numbered prompt where it does not — see lib/01-core.sh.
menu_pick() { # $1 = height, $2 = header, $3 = overlay|""
  menu_choices "${3:-}" | pick --height "$1" --prompt 'pitcrew ❯ ' --header "$2"
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
  local planned; mapfile -t planned < <(resolve_targets "$@" 2>/dev/null)
  ram_preflight "${planned[@]}"
  start_targets "$@" >/dev/null 2>&1
  if [ ${#STARTED[@]} -eq 0 ]; then toast "${GREY}nothing to start${RESET}"; return 0; fi
  if [ -n "$RAM_WARN" ]; then
    toast "${C_WARN}⚠${RESET} $RAM_WARN"
  else
    toast "${YELLOW}▶${RESET} starting ${BOLD}${STARTED[*]}${RESET}"
  fi
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
  local choice=${1%%$'\t'*} mode=${2:-} sel prof running pname shname th rnd rkey rval lc lcomp lval
  MENU_CLOSE=0
  case "$choice" in
    start-all)     if [ "$mode" = overlay ]; then ov_start all
                   else cmd_start all; read -rp "  press Enter…"; fi ;;
    start-apps)    sel=$(pick_apps) || true
                   [ -n "${sel:-}" ] || return 0
                   if [ "$mode" = overlay ]; then ov_start $sel
                   else cmd_start $sel; read -rp "  press Enter…"; fi ;;
    start-profile) prof=$(pick_profile) || { warn "no profiles yet — save one first"; sleep 2; return 0; }
                   [ -n "${prof:-}" ] || return 0
                   if [ "$mode" = overlay ]; then ov_start "@$prof"
                   else cmd_start "@$prof"; read -rp "  press Enter…"; fi ;;
    save-profile)  running=$(running_comps | tr '\n' ' ')
                   if [ -z "$running" ]; then warn "nothing is running to save"; sleep 2; return 0; fi
                   say "  running now: ${CYAN}$running${RESET}"
                   read -rp "  profile name: " pname
                   [ -n "$pname" ] && { cmd_profile save "$pname" $running; sleep 1; } ;;
    start-be)      if [ "$mode" = overlay ]; then ov_start backends
                   else cmd_start backends; read -rp "  press Enter…"; fi ;;
    start-fe)      if [ "$mode" = overlay ]; then ov_start frontends
                   else cmd_start frontends; read -rp "  press Enter…"; fi ;;
    restart-apps)  sel=$(pick_apps) || true
                   [ -n "${sel:-}" ] || return 0
                   if [ "$mode" = overlay ]; then ov_restart $sel
                   else cmd_stop $sel; cmd_start $sel; read -rp "  press Enter…"; fi ;;
    restart-stale) if [ "$mode" = overlay ]; then ov_stale
                   else cmd_stale --restart; read -rp "  press Enter…"; fi ;;
    stop-apps)     if [ "$mode" = overlay ]; then ov_stop all
                   else cmd_stop all; sleep 1; fi ;;
    stop-all)      if [ "$mode" = overlay ]; then ov_stop all --deps
                   else cmd_stop all --deps; sleep 1; fi ;;
    watch)         cmd_watch ;;
    logs)          cmd_logs ;;
    shell)         if [ ${#PITCREW_SHELLS[@]} -eq 0 ]; then warn "no shells configured (set PITCREW_SHELLS)"; sleep 2; return 0; fi
                   shname=$(printf '%s\n' "${!PITCREW_SHELLS[@]}" | pick --height 30% --prompt 'shell ❯ ') || true
                   [ -n "${shname:-}" ] && { clear; cmd_shell "$shname"; read -rp "  press Enter…"; } ;;
    switch)        switch_project ;;
    theme)         th=$(theme_list | pick --height 40% --prompt 'theme ❯ ' \
                        --header 'live preview · Enter applies and remembers · Esc cancels' \
                        --preview "'$SELF' theme --swatch {}" --preview-window 'down:3') || true
                   if [ -n "${th:-}" ]; then
                     theme_save "$th"
                     PITCREW_THEME_ENV=$th; theme_load
                     if [ "$mode" = overlay ]; then
                       toast "${C_ACCENT}🌈${RESET} theme ${BOLD}$th${RESET}"; MENU_CLOSE=1
                     fi
                   fi ;;
    render)        # one flat list of every setting × every value, each with a
                   # swatch in the preview pane — the same shape as the theme
                   # picker, because it is the same kind of choice
                   rnd=$(render_choices | pick --height 45% \
                        --prompt 'render ❯ ' \
                        --header 'live preview · Enter applies and remembers · Esc cancels' \
                        --preview "'$SELF' render --swatch {1}" --preview-window 'down:3') || true
                   if [ -n "${rnd:-}" ]; then
                     rkey=${rnd%%$'\t'*}; rval=${rkey#*=}; rkey=${rkey%%=*}
                     render_save "$rkey" "$rval"
                     render_set  "$rkey" "$rval"
                     if [ "$mode" = overlay ]; then
                       toast "${C_ACCENT}📈${RESET} $rkey ${BOLD}$rval${RESET}"; MENU_CLOSE=1
                     fi
                   fi ;;
    limits)        # two steps rather than one flat component×size list: twelve
                   # components times eleven sizes is a haystack, and the first
                   # question ("which service") is the one you already know.
                   lc=$(limit_choices | pick --height 45% \
                        --prompt 'cap ❯ ' \
                        --header 'pick a component · Esc cancels') || true
                   if [ -n "${lc:-}" ]; then
                     lcomp=${lc%%$'\t'*}
                     lval=$(limit_size_choices "$lcomp" | pick --height 45% \
                          --prompt "$lcomp ❯ " \
                          --header 'Enter sets it · applies when the service next starts') || true
                     if [ -n "${lval:-}" ]; then
                       lval=${lval%%$'\t'*}
                       [ "$lval" = default ] && lval=""
                       if limits_save "$lcomp" "$lval"; then
                         cap_cache_set "$lcomp"
                         if [ "$mode" = overlay ]; then
                           toast "${C_ACCENT}🧠${RESET} $lcomp ${BOLD}$(comp_max "$lcomp")${RESET}"
                           MENU_CLOSE=1
                         else
                           ok "$lcomp capped at $(comp_max "$lcomp")"; sleep 1
                         fi
                       else
                         toast "${RED}✗${RESET} could not write $LIMITS_FILE"
                       fi
                     fi
                   fi ;;
    zen)           if [ "$ZEN" = 1 ]; then ZEN=0; else ZEN=1; SEL=0; fi
                   MENU_CLOSE=1 ;;
    diagnose)      if [ "$mode" = overlay ]; then diag_view; MENU_CLOSE=1
                   else cmd_diagnose; read -rp "  press Enter…"; fi ;;
    doctor)        cmd_doctor; read -rp "  press Enter…" ;;
    urls)          cmd_urls
                   if [ "$mode" = overlay ]; then toast "${BLUE}🌐${RESET} opened frontend URLs"; MENU_CLOSE=1; else sleep 1; fi ;;
    refresh)       : ;;
    close)         MENU_CLOSE=1 ;;
    # Esc, an empty choice, or a key with no arm. Every real item has its own
    # arm above so that "no arm" always means "someone forgot", never "this one
    # is meant to fall through" — that ambiguity is what hid the emoji clash.
    *)             MENU_CLOSE=1 ;;
  esac
  return 0
}

menu() {
  local choice
  while true; do
    clear
    banner
    status_table
    echo; hr
    choice=$(menu_pick 65% 'what do you want to do?') || break
    dispatch_choice "$choice"
    [ "$MENU_CLOSE" = 1 ] && break
  done
  clear
}

# Opened with 'm' from the live dashboard. Stays in the SAME screen — no
# clear, no leaving the alt-buffer — so the dashboard is never "switched
# away from"; this is just a togglable section under it.
watch_menu() {
  tui_pause
  printf '\n\n%b── menu %b\n' "$GREY" "$RESET"
  local choice
  while true; do
    choice=$(menu_pick 50% 'pick an action · Esc to close' overlay) || break
    dispatch_choice "$choice" overlay
    [ "$MENU_CLOSE" = 1 ] && break
  done
  tui_resume
}
