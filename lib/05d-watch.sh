#!/usr/bin/env bash
# lib/05c-watch.sh — the live loop: paint, read a key, act, repaint.
#
# NOTE ON THE NAME: every file in this group is `05<letter>-`, never `05-`.
# `lib/*.sh` is sourced in glob order, and a UTF-8 collation IGNORES punctuation
# when comparing — so "05-dashboard.sh" sorts AFTER "05a-cells.sh" on a normal
# desktop and before it under LC_ALL=C. This group has top-level code that reads
# variables the previous file sets, so that difference is the difference between
# working and `PITCREW_REFRESH: unbound variable`. Letters sort the same either
# way.
#
# Split out of one 1200-line file. The seams are the ones that were already
# there in comments: the viewport and the working set, the cell/layout
# arithmetic, the frame builder, and the interactive loop. Bash does not care
# what order functions are defined in, and lib/*.sh is sourced in name order,
# so 05 → 05a → 05b → 05c all load before 06.

cmd_watch() {
  local W H bw sw frame line ts pick sc c app i n rule_len r
  local ln avail
  tui_enter
  trap 'tui_leave; trap - INT; return 0' INT
  trap 'TERM_DIRTY=1' WINCH
  while true; do
    collect_frame
    supervise
    build_frame
    n=${#VIEW[@]}
    frame=$FRAME
    printf '\033[H%b\033[0J' "$frame"

    read_key "$PITCREW_REFRESH" || continue
    case "$KEY" in
      q|Q|esc) break ;;
      up)   [ $n -gt 0 ] && SEL=$(( (SEL - 1 + n) % n )) ;;
      down) [ $n -gt 0 ] && SEL=$(( (SEL + 1) % n )) ;;
      enter)
        c=${VIEW[$SEL]:-}
        [ -n "$c" ] && { [ -n "${EXPANDED[$c]:-}" ] && unset "EXPANDED[$c]" || EXPANDED[$c]=1; } ;;
      ' ') c=${VIEW[$SEL]:-}
           [ -n "$c" ] && { [ -n "${MARKED[$c]:-}" ] && unset "MARKED[$c]" || MARKED[$c]=1; }
           [ "$n" -gt 0 ] && SEL=$(( (SEL + 1) % n )) ;;      # mark-and-advance
      l|L) log_view "${VIEW[$SEL]:-}" ;;
      e|E) err_view ;;
      d|D) diag_view ;;
      o|O) case "$SORT" in name) SORT=state ;; state) SORT=ram ;; ram) SORT=cpu ;; *) SORT=name ;; esac ;;
      /)   filter_prompt ;;
      a|A) target_set
           [ ${#TARGETS[@]} -eq 0 ] && { toast "${C_MUTED}nothing selected${RESET}"; continue; }
           ram_preflight "${TARGETS[@]}"
           for c in "${TARGETS[@]}"; do supervise_clear "$c"; start_comp "$c" >/dev/null 2>&1; done
           if [ -n "$RAM_WARN" ]; then toast "${C_WARN}⚠${RESET} $RAM_WARN"
           else toast "${YELLOW}▶${RESET} starting ${BOLD}${TARGETS[*]}${RESET}"; fi
           MARKED=() ;;
      r|R) target_set
           [ ${#TARGETS[@]} -eq 0 ] && continue
           for c in "${TARGETS[@]}"; do
             supervise_clear "$c"; stop_comp "$c" >/dev/null 2>&1; start_comp "$c" >/dev/null 2>&1
           done
           toast "${YELLOW}↻${RESET} restarting ${BOLD}${TARGETS[*]}${RESET}"; MARKED=() ;;
      s|S) target_set
           [ ${#TARGETS[@]} -eq 0 ] && continue
           for c in "${TARGETS[@]}"; do stop_comp "$c" >/dev/null 2>&1; done
           toast "${GREY}■${RESET} stopped ${BOLD}${TARGETS[*]}${RESET}"; MARKED=() ;;
      p|P) switch_project ;;
      m|M) watch_menu ;;
      x|X) MARKED=(); FILTER=""; SORT=name; toast "${C_MUTED}cleared marks, filter and sort${RESET}" ;;
      mouse) watch_mouse ;;
    esac
  done
  trap - INT WINCH
  err_close
  tui_leave
}

# Typing a filter repaints the real frame on every keystroke, so the list
# narrows as you type rather than after you commit.
filter_prompt() {
  local saved=$FILTER
  while true; do
    collect_frame; build_frame
    local hint
    printf -v hint ' %b filter %b %b%s%b%b▏%b  %besc cancels · enter keeps%b' \
      "$C_CAP$C_TEXT" "$RESET" "$C_TEXT" "$FILTER" "$RESET" "$C_ACCENT" "$RESET" \
      "$C_MUTED" "$RESET"
    printf '\033[H%b\033[0J' "$FRAME"
    printf '\033[%d;1H%b\033[K' "$TERM_H" "$hint"
    read_key 0.5 || continue
    case "$KEY" in
      enter) break ;;
      esc)   FILTER=$saved; break ;;
      $'\177'|$'\b') FILTER=${FILTER%?} ;;
      mouse) ;;
      up|down|left|right|tab) ;;
      "") ;;
      *) FILTER+=$KEY ;;
    esac
  done
  SEL=0
  return 0
}

# Click a service row to select it; click the selected row again to open its
# process tree. Wheel scrolls the selection.
watch_mouse() {
  local app c
  case "$MOUSE_BTN" in
    64) [ ${#VIEW[@]} -gt 0 ] && SEL=$(( (SEL - 1 + ${#VIEW[@]}) % ${#VIEW[@]} )); return ;;
    65) [ ${#VIEW[@]} -gt 0 ] && SEL=$(( (SEL + 1) % ${#VIEW[@]} )); return ;;
    0)  [ "${MOUSE_REL:-0}" = 1 ] && return ;;
    *)  return ;;
  esac
  app=${ROW_COMP[$MOUSE_Y]:-}
  [ -n "$app" ] || return
  # left half of the row is the backend cell, right half the frontend
  term_size
  if [ "${MOUSE_X:-0}" -gt $((TERM_W / 2)) ]; then c="fe-$app"; else c="be-$app"; fi
  [ -n "${SNAP_STATE[$c]:-}" ] || return
  local i
  for i in "${!VIEW[@]}"; do
    if [ "${VIEW[$i]}" = "$c" ]; then
      if [ "$SEL" = "$i" ]; then
        [ -n "${EXPANDED[$c]:-}" ] && unset "EXPANDED[$c]" || EXPANDED[$c]=1
      fi
      SEL=$i
      return
    fi
  done
}

watch_stop() {
  command -v fzf >/dev/null || return
  local pick sc
  tui_pause
  printf '\n\n%b── stop %b\n' "$GREY" "$RESET"
  pick=$(running_comps | fzf --multi --height=40% --border=rounded \
    --prompt='stop ❯ ' --pointer='▶' --marker='✔ ' \
    --header='TAB = select several · Enter = stop · Esc = cancel') || pick=""
  local stopped=()
  while IFS= read -r sc; do
    [ -n "$sc" ] || continue
    stop_comp "$sc" >/dev/null 2>&1
    stopped+=("$sc")
  done <<< "$pick"
  tui_resume
  [ ${#stopped[@]} -gt 0 ] && toast "${GREY}■${RESET} stopped ${BOLD}${stopped[*]}${RESET}"
  return 0
}

# The error radar keeps the lines it matched, not just a count — this is what
# turns "⚡7" into something you can act on without leaving the dashboard.
err_view() {
  local c line
  while true; do
    local frame="" W H rows
    term_size; W=$TERM_W; H=$TERM_H
    rows=$((H - 4))                       # title + blank + rows + blank + key
    frame="  ${BOLD}${RED}errors${RESET} ${GREY}(pattern: ${PITCREW_ERROR_PATTERN})${RESET}"$'\e[K\n\e[K\n'
    local shown=0
    for c in "${PITCREW_COMPS[@]}"; do
      [ "${ERR_COUNT[$c]:-0}" -gt 0 ] || continue
      frame+="  ${CYAN}${c}${RESET} ${GREY}${ERR_COUNT[$c]} matched${RESET}"$'\e[K\n'
      shown=$((shown + 1))
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        frame+="    ${DIM}${line:0:$((W - 6))}${RESET}"$'\e[K\n'
        shown=$((shown + 1))
        [ $shown -ge $rows ] && break
      done <<< "${ERR_LINES[$c]}"
      [ $shown -ge $rows ] && break
    done
    [ $shown -eq 0 ] && { frame+="  ${GREEN}no matching lines in any log${RESET}"$'\e[K\n'; shown=1; }
    # same rule as everywhere else: the key hint lives on the bottom row
    while [ "$shown" -lt "$rows" ]; do frame+=$'\e[K\n'; shown=$((shown + 1)); done
    frame+=$'\e[K\n'" ${BOLD}${MAGENTA}q${RESET}${DIM}${GREY} back${RESET}"$'\e[K'
    fit_frame "$frame" "$W" "$H"
    printf '\033[H%b\033[0J' "$FIT"
    read_key 1 || continue
    case "$KEY" in q|Q|esc) break ;; esac
  done
}

# The diagnostics panel: the same findings `pitcrew diagnose` prints, without
# leaving the dashboard.
#
# The recovery flow is deliberately diagnose → candidates → review → apply, and
# the review step is this screen: every component that would be stopped is
# listed by name with what it is holding and how long it has been idle, and
# only then does `s` act. A button that picks its own victims off-screen is the
# one thing a developer cannot afford to trust — the whole value is knowing
# exactly what is about to happen before it does.
diag_view() {
  local i sev shown rows W H frame line c
  while true; do
    term_size; W=$TERM_W; H=$TERM_H
    rows=$((H - 2))
    frame=""
    diag_verdict_line
    frame+="  $R"$'\e[K\n\e[K\n'; shown=2

    # the machine, in one line rather than the three `diagnose` can afford
    if [ "${SYS_MEM_TOTAL_KB:-0}" -gt 0 ]; then
      local mpct=$(( SYS_MEM_USED_KB * 100 / SYS_MEM_TOTAL_KB ))
      human $(( SYS_MEM_USED_KB * 1024 )); local usedh=$HUMAN
      human $(( SYS_MEM_TOTAL_KB * 1024 )); local totalh=$HUMAN
      pct_color "$mpct"; bar "$mpct" 16; local mbar=$R
      pct_color "${SYS_CPU_PCT:-0}"; bar "${SYS_CPU_PCT:-0}" 16; local cbar=$R
      printf -v line '  %bRAM%b %s %b%s%b%b/%s%b   %bCPU%b %s %b%s%%%b' \
        "$C_MUTED" "$RESET" "$mbar" "$C_TEXT" "$usedh" "$RESET" "$C_MUTED" "$totalh" "$RESET" \
        "$C_MUTED" "$RESET" "$cbar" "$C_TEXT" "${SYS_CPU_PCT:-0}" "$RESET"
      frame+="$line"$'\e[K\n'; shown=$((shown + 1))
      if [ "${SYS_SWAP_USED_KB:-0}" -gt 0 ]; then
        human $(( SYS_SWAP_USED_KB * 1024 ))
        frame+="  ${C_MUTED}SWP${RESET} ${C_WARN}${HUMAN} in use${RESET}"$'\e[K\n'
        shown=$((shown + 1))
      fi
      frame+=$'\e[K\n'; shown=$((shown + 1))
    fi

    if [ "$DIAG_N" -eq 0 ]; then
      frame+="  ${C_OK}nothing needs your attention${RESET}"$'\e[K\n'
      shown=$((shown + 1))
    fi
    for sev in crit warn info; do
      for i in "${!DIAG_SEV[@]}"; do
        [ "${DIAG_SEV[i]}" = "$sev" ] || continue
        [ $shown -ge $((rows - 4)) ] && break 2
        diag_icon "$sev"
        printf -v line '  %s %b%s%b' "$R" "$C_TEXT$BOLD" "${DIAG_TITLE[i]}" "$RESET"
        frame+="${line:0:$((W + 60))}"$'\e[K\n'; shown=$((shown + 1))
        frame+="      ${C_MUTED}${DIAG_DETAIL[i]:0:$((W - 8))}${RESET}"$'\e[K\n'; shown=$((shown + 1))
      done
    done

    if [ ${#DIAG_IDLE_COMPS[@]} -gt 0 ] && [ $shown -lt $((rows - 4)) ]; then
      human "$DIAG_IDLE_BYTES"
      frame+=$'\e[K\n'"  ${BOLD}recoverable${RESET} ${C_MUTED}— stopping these returns ${RESET}${C_ACCENT}${HUMAN}${RESET}"$'\e[K\n'
      shown=$((shown + 2))
      for c in "${DIAG_IDLE_COMPS[@]}"; do
        [ $shown -ge $((rows - 2)) ] && break
        human "${SNAP_RSS[$c]:-0}"
        printf -v line '    %b%-22s%b %b%7s%b   %b%s%b' \
          "$C_TEXT" "$c" "$RESET" "$C_ACCENT" "$HUMAN" "$RESET" \
          "$C_MUTED" "${DIAG_IDLE_WHY[$c]:-}" "$RESET"
        frame+="$line"$'\e[K\n'; shown=$((shown + 1))
      done
    fi

    while [ "$shown" -lt "$rows" ]; do frame+=$'\e[K\n'; shown=$((shown + 1)); done
    line=" ${C_CAP}${C_TEXT} q ${RESET}${C_MUTED} back${RESET}  "
    [ ${#DIAG_IDLE_COMPS[@]} -gt 0 ] && \
      line+="${C_CAP}${C_TEXT} s ${RESET}${C_MUTED} stop the ${#DIAG_IDLE_COMPS[@]} idle above${RESET}  "
    line+="${C_CAP}${C_TEXT} r ${RESET}${C_MUTED} re-check${RESET}"
    frame+="$line"$'\e[K'
    fit_frame "$frame" "$W" "$H"
    printf '\033[H%b\033[0J' "$FIT"

    read_key 1 || { collect_frame; continue; }
    case "$KEY" in
      q|Q|esc) break ;;
      r|R) collect_frame ;;
      s|S) [ ${#DIAG_IDLE_COMPS[@]} -gt 0 ] || continue
           local stopped=("${DIAG_IDLE_COMPS[@]}")
           for c in "${stopped[@]}"; do stop_comp "$c" >/dev/null 2>&1; done
           collect_frame
           toast "${GREY}■${RESET} stopped ${BOLD}${stopped[*]}${RESET}"
           break ;;
    esac
  done
}
