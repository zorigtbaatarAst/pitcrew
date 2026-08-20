#!/usr/bin/env bash
# lib/11-logs.sh — in-place live log viewer, and a generic named "shell"
# shortcut (config-defined foreground commands, e.g. a db shell). No
# multiplexer: "attach" is gone — Enter instead opens the full log in your
# pager, since that's what attaching to a log-tailing pane was really for.

log_components() { # stable order: only components that have a log file
  local c
  while IFS= read -r c; do [ -f "$LOG_DIR/$c.log" ] && echo "$c"; done < <(all_components)
}

log_view() { # in-place live log viewer ($1 = optional preselect); assumes alt screen is active
  local comps=() sel=0 i i0 used tok c f key rest W H rows frame hdr line shown
  mapfile -t comps < <(log_components)
  [ ${#comps[@]} -eq 0 ] && { say "  ${YELLOW}⚠${RESET} no service logs yet — start something first"; sleep 2; return; }
  if [ -n "${1:-}" ]; then
    for i in "${!comps[@]}"; do [ "${comps[$i]}" = "$1" ] && sel=$i; done
  fi
  while true; do
    printf '\033[?7l'   # no auto-wrap: a too-wide line must never break the repaint line count
    mapfile -t comps < <(log_components)
    [ ${#comps[@]} -eq 0 ] && break
    snapshot
    [ "$sel" -ge ${#comps[@]} ] && sel=$((${#comps[@]} - 1))
    # Same viewport as the dashboard: measured once and re-measured on
    # SIGWINCH, instead of two `tput` forks every second forever.
    term_size; W=$TERM_W; H=$TERM_H
    # tab bar + blank + rows + hint bar == exactly the window, so the hint bar
    # sits on the bottom row whether the log has three lines or three thousand
    rows=$((H - 3)); [ $rows -lt 3 ] && rows=3
    c=${comps[$sel]}; f="$LOG_DIR/$c.log"

    # tab bar: sliding window — the selection stays visible, the bar never overflows the width
    i0=$((sel > 2 ? sel - 2 : 0))
    hdr="  "; used=2
    [ "$i0" -gt 0 ] && { hdr+="${GREY}‹ ${RESET}"; used=$((used + 2)); }
    for ((i = i0; i < ${#comps[@]}; i++)); do
      if [ "$i" -lt 9 ]; then tok="$((i + 1)) ${comps[$i]}"; else tok="${comps[$i]}"; fi
      if [ $((used + ${#tok} + 5)) -gt "$W" ]; then hdr+="${GREY}›${RESET}"; break; fi
      if [ "$i" -eq "$sel" ]; then
        state_icon "${SNAP_STATE[$c]:-n/a}"
        hdr+="$R ${BOLD}${CYAN}${tok}${RESET}   "
      else
        hdr+="${GREY}${tok}${RESET}   "
      fi
      used=$((used + ${#tok} + 5))
    done

    frame="$hdr"$'\e[K\n\e[K\n'
    shown=0
    while IFS= read -r line; do
      frame+="$line"$'\e[K\n'; shown=$((shown + 1))
    done < <(tail -n $((rows + 60)) "$f" 2>/dev/null | strip_ansi | grep -vE '^[[:space:]]*$' \
             | expand -t 4 | awk -v w=$((W - 1)) '{ print substr($0, 1, w) }' | tail -n "$rows")
    # A log with four lines in it used to leave the hint bar floating four
    # rows down the screen; push it to the bottom and leave it there.
    while [ "$shown" -lt "$rows" ]; do frame+=$'\e[K\n'; shown=$((shown + 1)); done
    # Same rule as the dashboard's key caps: drop the hints that do not fit
    # rather than let the terminal cut one in half. `q back` is first because
    # a hint bar you cannot read all of should still tell you the way out.
    line=" "; local kc cap lbl kvis=1 addw
    for kc in "q:back" "Tab/←→:switch" "1-9:jump" "x:stop" "r:restart" "Enter:full log"; do
      cap=${kc%%:*}; lbl=${kc#*:}
      addw=$(( ${#cap} + 1 + ${#lbl} + 2 ))
      [ $(( kvis + addw )) -gt "$W" ] && break
      line+="${BOLD}${MAGENTA}${cap}${RESET}${DIM}${GREY} ${lbl}${RESET}  "
      kvis=$(( kvis + addw ))
    done
    frame+="$line$RESET"$'\e[K'
    fit_frame "$frame" "$W" "$H"
    printf '\033[H%b\033[0J' "$FIT"

    read_key 1 || continue
    key=$KEY
    case "$key" in
      q|Q|esc) break ;;
      right|down|l|L|n|N|tab) sel=$(( (sel + 1) % ${#comps[@]} )) ;;
      left|up|h|H|p|P)        sel=$(( (sel - 1 + ${#comps[@]}) % ${#comps[@]} )) ;;
      [1-9]) i=$((key - 1)); [ "$i" -lt ${#comps[@]} ] && sel=$i ;;
      x|X) stop_comp "$c" >/dev/null 2>&1 ;;
      r|R) stop_comp "$c" >/dev/null 2>&1; start_comp "$c" >/dev/null 2>&1 ;;
      enter)
        tui_pause
        if [ -n "${PAGER:-}" ]; then "$PAGER" "$f"
        elif command -v less >/dev/null; then less -R "$f"
        else more "$f"; fi
        tui_resume ;;
    esac
  done
}

cmd_logs() { # standalone entry: wrap log_view in its own alt screen
  [ -d "$LOG_DIR" ] || die "no logs yet — nothing has been started"
  tui_enter
  trap 'tui_leave; trap - INT; return 0' INT
  trap 'TERM_DIRTY=1' WINCH          # reached without the dashboard's own trap
  log_view "${1:-}"
  trap - INT WINCH
  tui_leave
}

cmd_shell() { # $1 = name of a PITCREW_SHELLS entry (e.g. "mongo", "redis") — runs in the foreground
  local name=${1:-}
  if [ -z "$name" ]; then
    if [ ${#PITCREW_SHELLS[@]} -eq 0 ]; then die "no shells configured — set PITCREW_SHELLS in your config"; fi
    say "  ${BOLD}configured shells${RESET}"
    local k; for k in "${!PITCREW_SHELLS[@]}"; do say "    ${CYAN}$k${RESET}  ${GREY}${PITCREW_SHELLS[$k]}${RESET}"; done
    return
  fi
  local cmd="${PITCREW_SHELLS[$name]:-}"
  [ -n "$cmd" ] || die "no shell named '$name' — see: pitcrew shell"
  bash -c "$cmd"
}
