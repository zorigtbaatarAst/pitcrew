#!/usr/bin/env bash
# lib/10-logs.sh — in-place live log viewer, log grid, and a generic named
# "shell" shortcut (config-defined quick tmux windows, e.g. a db shell).

log_components() { # stable order: only components that have a log file
  local c
  while IFS= read -r c; do [ -f "$LOG_DIR/$c.log" ] && echo "$c"; done < <(all_components)
}

log_view() { # in-place live log viewer ($1 = optional preselect); assumes alt screen is active
  local comps=() sel=0 i i0 used tok c f key rest W H rows frame hdr line
  mapfile -t comps < <(log_components)
  [ ${#comps[@]} -eq 0 ] && { say "  ${YELLOW}⚠${RESET} no service logs yet — start something first"; sleep 2; return; }
  if [ -n "${1:-}" ]; then
    for i in "${!comps[@]}"; do [ "${comps[$i]}" = "$1" ] && sel=$i; done
  fi
  while true; do
    printf '\033[?7l'   # no auto-wrap: a too-wide line must never break the repaint line count
    mapfile -t comps < <(log_components)
    [ ${#comps[@]} -eq 0 ] && break
    [ "$sel" -ge ${#comps[@]} ] && sel=$((${#comps[@]} - 1))
    W=$(tput cols 2>/dev/null); [ -n "$W" ] || W=100
    H=$(tput lines 2>/dev/null); [ -n "$H" ] || H=30
    rows=$((H - 4)); [ $rows -lt 3 ] && rows=3
    c=${comps[$sel]}; f="$LOG_DIR/$c.log"

    # tab bar: sliding window — the selection stays visible, the bar never overflows the width
    i0=$((sel > 2 ? sel - 2 : 0))
    hdr="  "; used=2
    [ "$i0" -gt 0 ] && { hdr+="${GREY}‹ ${RESET}"; used=$((used + 2)); }
    for ((i = i0; i < ${#comps[@]}; i++)); do
      if [ "$i" -lt 9 ]; then tok="$((i + 1)) ${comps[$i]}"; else tok="${comps[$i]}"; fi
      if [ $((used + ${#tok} + 5)) -gt "$W" ]; then hdr+="${GREY}›${RESET}"; break; fi
      if [ "$i" -eq "$sel" ]; then
        hdr+="$(state_icon "$(comp_state "$c")") ${BOLD}${CYAN}${tok}${RESET}   "
      else
        hdr+="${GREY}${tok}${RESET}   "
      fi
      used=$((used + ${#tok} + 5))
    done

    frame="$hdr"$'\e[K\n\e[K\n'
    while IFS= read -r line; do
      frame+="$line"$'\e[K\n'
    done < <(tail -n $((rows + 60)) "$f" 2>/dev/null | strip_ansi | grep -vE '^[[:space:]]*$' \
             | expand -t 4 | awk -v w=$((W - 1)) '{ print substr($0, 1, w) }' | tail -n "$rows")
    printf -v line ' %bTab/←→%b switch  %b1-9%b jump  %bx%b stop  %br%b restart  %bEnter%b attach  %bq%b back' \
      "$BOLD$MAGENTA" "$RESET$DIM$GREY" "$BOLD$MAGENTA" "$RESET$DIM$GREY" \
      "$BOLD$MAGENTA" "$RESET$DIM$GREY" "$BOLD$MAGENTA" "$RESET$DIM$GREY" \
      "$BOLD$MAGENTA" "$RESET$DIM$GREY" "$BOLD$MAGENTA" "$RESET$DIM$GREY"
    frame+="$line$RESET"$'\e[K'
    printf '\033[H%b\033[0J' "$frame"

    if IFS= read -rsn1 -t 1 key 2>/dev/null; then
      [ -z "$key" ] && key=enter
    else
      key=""   # timeout → just refresh
    fi
    if [ "$key" = $'\e' ]; then
      rest=""; IFS= read -rsn2 -t 0.01 rest 2>/dev/null || true
      case "$rest" in
        '[C'|'[B') key=next ;;
        '[D'|'[A') key=prev ;;
        '')        key=q ;;     # bare Esc
        *)         key="" ;;
      esac
    fi
    case "$key" in
      q|Q) break ;;
      next|l|L|n|N|$'\t') sel=$(( (sel + 1) % ${#comps[@]} )) ;;
      prev|h|H|p|P)       sel=$(( (sel - 1 + ${#comps[@]}) % ${#comps[@]} )) ;;
      [1-9]) i=$((key - 1)); [ "$i" -lt ${#comps[@]} ] && sel=$i ;;
      x|X) stop_comp "$c" >/dev/null 2>&1 ;;
      r|R) stop_comp "$c" >/dev/null 2>&1; start_comp "$c" >/dev/null 2>&1 ;;
      enter)
        if win_exists "$c"; then
          printf '\033[?7h'; tput rmcup 2>/dev/null; tput cnorm 2>/dev/null
          say "${GREY}attaching to $c — detach with Ctrl+b then d${RESET}"; sleep 1
          tmux select-window -t "$SESSION:$c" 2>/dev/null
          attach_to "$SESSION"
          tput smcup 2>/dev/null; tput civis 2>/dev/null
        fi ;;
    esac
  done
  printf '\033[?7h'
}

cmd_logs() { # standalone entry: wrap log_view in its own alt screen
  [ -d "$LOG_DIR" ] || die "no logs yet — nothing has been started"
  tput smcup 2>/dev/null; tput civis 2>/dev/null
  trap 'tput cnorm 2>/dev/null; tput rmcup 2>/dev/null; trap - INT; return 0' INT
  log_view "${1:-}"
  trap - INT
  tput cnorm 2>/dev/null; tput rmcup 2>/dev/null
}

cmd_grid() {
  tmux has-session -t "$SESSION" 2>/dev/null || die "nothing is running"
  local wins
  wins=$(tmux list-windows -t "$SESSION" -F '#W' | grep -v '^_')
  [ -n "$wins" ] || die "no service windows"
  tmux kill-window -t "$SESSION:_grid" 2>/dev/null
  local first=1 w
  while IFS= read -r w; do
    local f="$LOG_DIR/$w.log"; [ -f "$f" ] || continue
    if [ $first -eq 1 ]; then
      tmux new-window -d -t "$SESSION" -n _grid "tail -n 30 -f '$f'"
      first=0
    else
      tmux split-window -d -t "$SESSION:_grid" "tail -n 30 -f '$f'"
    fi
    tmux select-layout -t "$SESSION:_grid" tiled >/dev/null
  done <<< "$wins"
  [ $first -eq 1 ] && die "no logs yet — services were started before grid support; restart them once"
  local i=0
  tmux set-option -t "$SESSION" pane-border-status top 2>/dev/null
  while IFS= read -r w; do
    [ -f "$LOG_DIR/$w.log" ] || continue
    tmux select-pane -t "$SESSION:_grid.$i" -T " $w " 2>/dev/null
    i=$((i + 1))
  done <<< "$wins"
  tmux select-window -t "$SESSION:_grid"
  attach_to "$SESSION"
}

cmd_shell() { # $1 = name of a PITCREW_SHELLS entry (e.g. "mongo", "redis")
  local name=${1:-}
  if [ -z "$name" ]; then
    if [ ${#PITCREW_SHELLS[@]} -eq 0 ]; then die "no shells configured — set PITCREW_SHELLS in your config"; fi
    say "  ${BOLD}configured shells${RESET}"
    local k; for k in "${!PITCREW_SHELLS[@]}"; do say "    ${CYAN}$k${RESET}  ${GREY}${PITCREW_SHELLS[$k]}${RESET}"; done
    return
  fi
  local cmd="${PITCREW_SHELLS[$name]:-}"
  [ -n "$cmd" ] || die "no shell named '$name' — see: pitcrew shell"
  ensure_session
  tmux kill-window -t "$SESSION:_shell-$name" 2>/dev/null
  tmux new-window -d -t "$SESSION" -n "_shell-$name" "$cmd"
  tmux select-window -t "$SESSION:_shell-$name"
  say "${GREY}$name — detach with Ctrl+b then d${RESET}"; sleep 1
  attach_to "$SESSION"
}
