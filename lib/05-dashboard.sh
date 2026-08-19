#!/usr/bin/env bash
# lib/05-dashboard.sh — the one-shot status table and the full-screen live
# dashboard (flicker-free single-paint redraw).
#
# Every value on screen comes from the SNAP_* arrays that snapshot() filled
# for this frame, and the frame is composed by appending to strings — never by
# `$(helper)`, which would fork. See the calling-convention note at the top of
# lib/04-meters.sh.

PITCREW_REFRESH="${PITCREW_REFRESH:-1}"      # seconds between frames; fractions OK
PITCREW_MOUSE="${PITCREW_MOUSE:-0}"          # opt-in: click to select/expand, wheel to scroll

# tput is an external command, so asking it for the terminal size every frame
# is two forks per frame for a number that only changes when you resize the
# window. Read it once and let SIGWINCH mark it dirty.
TERM_DIRTY=1
term_size() {
  [ "$TERM_DIRTY" = 1 ] || return 0
  TERM_W=$(tput cols 2>/dev/null);  [ -n "$TERM_W" ] || TERM_W=100
  TERM_H=$(tput lines 2>/dev/null); [ -n "$TERM_H" ] || TERM_H=30
  TERM_DIRTY=0
  return 0
}

declare -gA EXPANDED=()                      # comp -> 1 when its process tree is open
declare -gA ROW_COMP=()                      # screen row -> comp (for mouse hit-testing)
SEL=0                                        # index into PITCREW_COMPS

summary_line() { # → R
  local c st up=0 starting=0 crashed=0 down=0
  for c in "${PITCREW_COMPS[@]}"; do
    case "${SNAP_STATE[$c]:-down}" in
      up) up=$((up+1)) ;; starting) starting=$((starting+1)) ;;
      crashed) crashed=$((crashed+1)) ;; down) down=$((down+1)) ;;
    esac
  done
  R="  ${GREEN}${up} up${RESET}"
  [ $starting -gt 0 ] && R+="  ${YELLOW}${starting} starting${RESET}"
  [ $crashed  -gt 0 ] && R+="  ${RED}${crashed} crashed${RESET}"
  [ $down     -gt 0 ] && R+="  ${GREY}${down} down${RESET}"
}

status_table() {
  snapshot
  err_scan
  local dep st app bs fs bx fx line
  if [ ${#PITCREW_DEPS[@]} -gt 0 ]; then
    say "  ${BOLD}deps${RESET}"
    for dep in "${PITCREW_DEPS[@]}"; do
      st=${SNAP_DEP[$dep]:-down}
      state_icon "$st"
      printf '    %b %-16s %s\n' "$R" "$dep" "${GREY}${st}${RESET}"
    done
    say ""
  fi
  summary_line; say "$R"
  say ""
  printf '  %b%-12s %-34s %s%b\n' "$BOLD" "app" "backend              ram" "frontend             ram" "$RESET"
  for app in "${PITCREW_APPS[@]}"; do
    bs=${SNAP_STATE[be-$app]:-n/a}; fs=${SNAP_STATE[fe-$app]:-n/a}
    bx=""; fx=""
    is_external "be-$app" && bx=" ${DIM}ext${RESET}"
    is_external "fe-$app" && fx=" ${DIM}ext${RESET}"
    line=""
    state_icon "$bs"; line+="$R"
    mem_meter "be-$app"; local bmem=$R
    state_icon "$fs"; local ficon=$R
    mem_meter "fe-$app"; local fmem=$R
    local berr="" ferr=""
    [ "${ERR_COUNT[be-$app]:-0}" -gt 0 ] && berr=" ${RED}⚡${ERR_COUNT[be-$app]}${RESET}"
    [ "${ERR_COUNT[fe-$app]:-0}" -gt 0 ] && ferr=" ${RED}⚡${ERR_COUNT[fe-$app]}${RESET}"
    printf '    %b%-12s%b %b %-8s %b:%-5s%b %b%b%b   %b %-8s %b:%-5s%b %b%b%b\n' \
      "$CYAN" "$app" "$RESET" \
      "$line" "$bs" "$GREY" "${PITCREW_BE_PORT[$app]:--}" "$RESET" "$bmem" "$berr" "$bx" \
      "$ficon" "$fs" "$GREY" "${PITCREW_FE_PORT[$app]:--}" "$RESET" "$fmem" "$ferr" "$fx"
  done
  say ""
  say "  ${GREY}● up  ◐ starting  ✗ crashed  ○ down  · n/a  ⚡ errors in log  ext = something else on that port${RESET}"
}

cmd_status() { banner; status_table; echo; }

comp_cell() { # $1 comp, $2 graph width → R: one aligned service cell
  local c=$1 gw=$2 st port cur app role cell
  st=${SNAP_STATE[$c]:-n/a}
  app=${c#??-}; role=${c:0:2}
  if [ "$role" = be ]; then port=${PITCREW_BE_PORT[$app]:-}; else port=${PITCREW_FE_PORT[$app]:-}; fi
  cur=${SNAP_RSS[$c]:-}

  state_icon "$st"; cell="$R "
  if [ "$st" = n/a ]; then
    printf -v R '%b%-6s%b ' "$GREY" "n/a" "$RESET"
  else
    printf -v R '%b:%-5s%b ' "$GREY" "${port:--}" "$RESET"
  fi
  cell+="$R"

  if [[ "$cur" =~ ^[0-9]+$ ]] && [ "$cur" -gt 0 ]; then
    spark "${HIST_MEM[$c]:-}" "$gw" "${COMP_MAX_B[$c]:-1}"
    cell+="$R"
    human "$cur"
    printf -v R ' %6s %4s' "$HUMAN" "${SNAP_CPU[$c]:-0}%"
    cell+="$R"
  elif is_external "$c"; then
    printf -v R '%b%*s%b %6s %4s' "$DIM$GREY" "$gw" "external" "$RESET" "—" "—"
    cell+="$R"
  else
    printf -v R '%b%*s%b %6s %4s' "$DIM$GREY" "$gw" "" "$RESET" "" ""
    cell+="$R"
  fi

  if [ "${ERR_COUNT[$c]:-0}" -gt 0 ]; then
    printf -v R ' %b%-4s%b' "$RED" "⚡${ERR_COUNT[$c]}" "$RESET"
  else
    printf -v R ' %-4s' ""
  fi
  R="$cell$R"
}

# Child processes of one component, heaviest first. Insertion sort over a
# handful of pids — cheaper than forking `sort`, and it runs per open row only.
_tree_sorted() { # $1 comp → TREE_SORTED array
  local c=$1 p i j n
  TREE_SORTED=(${SNAP_PIDS[$c]:-})
  n=${#TREE_SORTED[@]}
  for ((i = 1; i < n; i++)); do
    p=${TREE_SORTED[i]}; j=$((i - 1))
    while [ $j -ge 0 ] && [ "${SNAP_PROC_RSS[${TREE_SORTED[j]}]:-0}" -lt "${SNAP_PROC_RSS[$p]:-0}" ]; do
      TREE_SORTED[j+1]=${TREE_SORTED[j]}; j=$((j - 1))
    done
    TREE_SORTED[j+1]=$p
  done
}

cmd_watch() {
  local W H bw frame line ts pick sc c app i n rule_len r
  local ln avail
  tui_enter
  trap 'tui_leave; trap - INT; return 0' INT
  trap 'TERM_DIRTY=1' WINCH
  n=${#PITCREW_COMPS[@]}

  while true; do
    term_size; W=$TERM_W; H=$TERM_H
    bw=$(( (W - 70) / 2 )); [ $bw -lt 6 ] && bw=6; [ $bw -gt 24 ] && bw=24

    snapshot
    err_scan
    for c in "${PITCREW_COMPS[@]}"; do
      hist_push "$c" "${SNAP_RSS[$c]:-0}" "${SNAP_CPU[$c]:-0}"
    done

    ROW_COMP=()
    frame=""; ln=0
    printf -v ts '%(%H:%M:%S)T' -1        # builtin strftime — no `date` fork

    # ── title rule ──
    printf -v line '%b── %b%s · live%b ' "$CYAN" "$BOLD" "${PITCREW_PROJECT_NAME:-pitcrew}" "$RESET$CYAN"
    rule_len=$((W - 12 - ${#PITCREW_PROJECT_NAME} - ${#ts})); [ $rule_len -lt 0 ] && rule_len=0
    r=""; while [ ${#r} -lt $rule_len ]; do r+="─"; done
    frame+="$line$r $ts ──$RESET"$'\e[K\n\e[K\n'; ln=$((ln + 2))

    # ── system gauges ──
    printf -v line '   %bCPU%b ' "$BOLD" "$RESET"
    bar "${SYS_CPU_PCT:-0}" 20; frame+="$line$R"
    printf -v line ' %3s%%      %bRAM%b ' "${SYS_CPU_PCT:-0}" "$BOLD" "$RESET"
    if [ -n "$SYS_MEM_TOTAL_KB" ]; then
      bar $((SYS_MEM_USED_KB * 100 / SYS_MEM_TOTAL_KB)) 20; frame+="$line$R"
      human $((SYS_MEM_USED_KB * 1024)); local used=$HUMAN
      human $((SYS_MEM_TOTAL_KB * 1024))
      printf -v line ' %s / %s' "$used" "$HUMAN"
    else
      frame+="$line${GREY}unavailable on this OS${RESET}"; line=""
    fi
    frame+="$line"$'\e[K\n\e[K\n'; ln=$((ln + 2))

    # ── deps ──
    if [ ${#PITCREW_DEPS[@]} -gt 0 ]; then
      local dep dline="   "
      for dep in "${PITCREW_DEPS[@]}"; do
        state_icon "${SNAP_DEP[$dep]:-down}"
        dline+="$R $dep   "
      done
      frame+="${GREY}── deps ${RESET}"$'\e[K\n'"$dline"$'\e[K\n\e[K\n'; ln=$((ln + 3))
    fi

    # ── services ──
    summary_line
    frame+="${GREY}── services${RESET}${R}"$'\e[K\n'; ln=$((ln + 1))
    printf -v line '   %b%-11s %-*s %s%b' "$BOLD$GREY" "app" "$((bw + 26))" "backend    ram        cpu" "frontend    ram        cpu" "$RESET"
    frame+="$line"$'\e[K\n'; ln=$((ln + 1))

    # rows left for services + any expanded trees, keeping the legend/help visible
    avail=$(( H - ln - 4 ))
    for ((i = 0; i < ${#PITCREW_APPS[@]}; i++)); do
      [ $avail -le 0 ] && break
      app=${PITCREW_APPS[i]}
      local marker="  " nm="$CYAN"
      if [ "${PITCREW_COMPS[$SEL]:-}" = "be-$app" ] || [ "${PITCREW_COMPS[$SEL]:-}" = "fe-$app" ]; then
        marker=" ${MAGENTA}▸${RESET}"; nm="$BOLD$CYAN"
      fi
      printf -v line '%b %b%-11s%b ' "$marker" "$nm" "$app" "$RESET"
      comp_cell "be-$app" "$bw"; line+="$R"
      comp_cell "fe-$app" "$bw"; line+="  $R"
      frame+="$line"$'\e[K\n'
      ln=$((ln + 1)); avail=$((avail - 1))
      ROW_COMP[$ln]="$app"

      # expanded process tree — the data is already in the snapshot, so this
      # costs nothing extra to render
      for c in "be-$app" "fe-$app"; do
        [ -n "${EXPANDED[$c]:-}" ] || continue
        _tree_sorted "$c"
        local p k=0 tot=${#TREE_SORTED[@]}
        for p in "${TREE_SORTED[@]}"; do
          [ $avail -le 0 ] && break
          k=$((k + 1))
          local branch="├"; [ $k -eq $tot ] && branch="└"
          human "${SNAP_PROC_RSS[$p]:-0}"
          printf -v line '      %b%s%b %b%-6s %-18s%b %7s %4s%%' \
            "$GREY" "$branch" "$RESET" "$DIM" "$p" "${SNAP_PROC_CMD[$p]:-?}" "$RESET" \
            "$HUMAN" "${SNAP_PROC_CPU[$p]:-0}"
          frame+="$line"$'\e[K\n'
          ln=$((ln + 1)); avail=$((avail - 1))
        done
      done
    done

    frame+=$'\e[K\n'
    printf -v line '   %b● up  ◐ starting  ✗ crashed  ○ down  · n/a  ⚡ log errors  %s%b' \
      "$DIM$GREY" "${PITCREW_COLLECTOR}·${PITCREW_REFRESH}s" "$RESET"
    frame+="$line"$'\e[K\n\e[K\n'
    printf -v line ' %b↑↓%b select  %b⏎%b tree  %bl%b logs  %be%b errors  %br%b restart  %bs%b stop  %bm%b menu  %bq%b quit' \
      "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" \
      "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET"
    frame+="$line"$'\e[K'

    printf '\033[H%b\033[0J' "$frame"

    read_key "$PITCREW_REFRESH" || continue
    case "$KEY" in
      q|Q|esc) break ;;
      up)   [ $n -gt 0 ] && SEL=$(( (SEL - 1 + n) % n )) ;;
      down) [ $n -gt 0 ] && SEL=$(( (SEL + 1) % n )) ;;
      enter)
        c=${PITCREW_COMPS[$SEL]:-}
        [ -n "$c" ] && { [ -n "${EXPANDED[$c]:-}" ] && unset "EXPANDED[$c]" || EXPANDED[$c]=1; } ;;
      l|L) log_view "${PITCREW_COMPS[$SEL]:-}" ;;
      e|E) err_view ;;
      r|R) c=${PITCREW_COMPS[$SEL]:-}
           [ -n "$c" ] && { stop_comp "$c" >/dev/null 2>&1; start_comp "$c" >/dev/null 2>&1; } ;;
      s|S) watch_stop ;;
      m|M) watch_menu ;;
      mouse) watch_mouse ;;
    esac
  done
  trap - INT WINCH
  err_close
  tui_leave
}

# Click a service row to select it; click the selected row again to open its
# process tree. Wheel scrolls the selection.
watch_mouse() {
  local app c
  case "$MOUSE_BTN" in
    64) [ ${#PITCREW_COMPS[@]} -gt 0 ] && SEL=$(( (SEL - 1 + ${#PITCREW_COMPS[@]}) % ${#PITCREW_COMPS[@]} )); return ;;
    65) [ ${#PITCREW_COMPS[@]} -gt 0 ] && SEL=$(( (SEL + 1) % ${#PITCREW_COMPS[@]} )); return ;;
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
  for i in "${!PITCREW_COMPS[@]}"; do
    if [ "${PITCREW_COMPS[$i]}" = "$c" ]; then
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
  while IFS= read -r sc; do [ -n "$sc" ] && stop_comp "$sc"; done <<< "$pick"
  tui_resume
}

# The error radar keeps the lines it matched, not just a count — this is what
# turns "⚡7" into something you can act on without leaving the dashboard.
err_view() {
  local c line
  while true; do
    local frame="" W H rows
    term_size; W=$TERM_W; H=$TERM_H
    rows=$((H - 3))
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
    [ $shown -eq 0 ] && frame+="  ${GREEN}no matching lines in any log${RESET}"$'\e[K\n'
    frame+=$'\e[K\n'" ${BOLD}${MAGENTA}q${RESET}${DIM}${GREY} back${RESET}"$'\e[K'
    printf '\033[H%b\033[0J' "$frame"
    read_key 1 || continue
    case "$KEY" in q|Q|esc) break ;; esac
  done
}
