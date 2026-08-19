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
  # An explicit COLUMNS/LINES wins: it is the conventional way to pin a size,
  # and it is the only way to get a real size when stdout is not a terminal
  # (a piped run, a recorded session, a test harness) — tput just says 80.
  TERM_W=${COLUMNS:-}; [ -n "$TERM_W" ] || TERM_W=$(tput cols 2>/dev/null)
  [ -n "$TERM_W" ] || TERM_W=100
  TERM_H=${LINES:-}; [ -n "$TERM_H" ] || TERM_H=$(tput lines 2>/dev/null)
  [ -n "$TERM_H" ] || TERM_H=30
  TERM_DIRTY=0
  return 0
}

# A closed menu still has to say what it did, now that actions no longer print
# anything. One line above the key hints, self-expiring.
TOAST=""
TOAST_AT=0
toast() { TOAST=$1; TOAST_AT=${SNAP_NOW_S:-0}; }

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
  [ $starting -gt 0 ] && R+="${GREY} · ${RESET}${YELLOW}${starting} starting${RESET}"
  [ $crashed  -gt 0 ] && R+="${GREY} · ${RESET}${RED}${crashed} crashed${RESET}"
  [ $down     -gt 0 ] && R+="${GREY} · ${RESET}${GREY}${down} down${RESET}"
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

# ── one service cell ────────────────────────────────────────────────────────
# The field widths are constants because BOTH comp_cell and cell_header build
# from them. The header used to be a hand-spaced literal, so its "ram"/"cpu"
# labels drifted away from their columns the moment the graph width changed
# with the terminal — which is every terminal that isn't the one it was
# eyeballed on.
CELL_PORT_W=7        # ":8082 " or "n/a    "
CELL_FIXED_W=26      # icon(2) + port(7) + ram(7) + cpu(5) + err(5)
ROW_PREFIX_W=15      # marker(2) + " " + app(11) + " "
CELL_GAP_W=2         # between the backend and frontend cells

cell_header() { # $1 graph width → R, exactly CELL_FIXED_W + $1 wide
  printf -v R '%b%2s%-7s%-*s %6s %4s %-4s%b' \
    "$BOLD$GREY" "" "port" "$1" "graph" "ram" "cpu" "" "$RESET"
}

comp_cell() { # $1 comp, $2 graph width → R: one aligned service cell
  local c=$1 gw=$2 st port cur app role cell pct half
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
    # Height auto-scales to this service's own recent range, so the shape is
    # always readable. Colour still comes from how close it is to its
    # configured RAM cap, so the headroom signal is not lost.
    pct=$(( cur * 100 / ${COMP_MAX_B[$c]:-1} ))
    pct_color "$pct"
    spark "${HIST_MEM[$c]:-}" "$gw" 67108864 "$PCOL"      # 64M floor
    cell+="$R"
    human "$cur"
    printf -v R ' %6s %4s' "$HUMAN" "${SNAP_CPU[$c]:-0}%"
    cell+="$R"
  elif is_external "$c"; then
    printf -v R '%b%*s%b %6s %4s' "$DIM$GREY" "$gw" "external" "$RESET" "—" "—"
    cell+="$R"
  elif [ "$st" = crashed ] && [ -n "${SNAP_EXIT[$c]:-}" ]; then
    # the graph area is empty for a dead service anyway — spend it on the one
    # thing you want to know, which is how it died
    local reason
    printf -v reason 'exit %s' "${SNAP_EXIT[$c]}"
    [ "${SNAP_EXIT[$c]}" -gt 128 ] 2>/dev/null && \
      printf -v reason 'signal %s' "$(( ${SNAP_EXIT[$c]} - 128 ))"
    [ -n "${SNAP_EXIT_AT[$c]:-}" ] && [ "${SNAP_EXIT_AT[$c]}" -gt 0 ] 2>/dev/null && \
      printf -v reason '%s · %(%H:%M:%S)T' "$reason" "${SNAP_EXIT_AT[$c]}"
    printf -v R '%b%-*.*s%b %6s %4s' "$RED" "$gw" "$gw" " $reason" "$RESET" "" ""
    cell+="$R"
  else
    half=$(( gw / 2 + 1 ))
    printf -v R '%b%*s%-*s%b %6s %4s' "$DIM$GREY" "$half" "·" "$((gw - half))" "" "$RESET" "" ""
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

# ── one frame, in three pieces ──────────────────────────────────────────────
# Split so the performance test can drive the REAL renderer instead of a
# hand-copied imitation of it. The test used to duplicate the frame body, which
# meant anything added to the dashboard afterwards — a footer, a header — was
# outside the fork budget and could regress unnoticed.
#
#   collect_frame  gathers state (the only part that touches the system)
#   build_frame    turns state into $FRAME (pure; no I/O, no forks)
#   cmd_watch      paints it and handles input

collect_frame() {
  snapshot
  err_scan
  local c
  for c in "${PITCREW_COMPS[@]}"; do
    hist_push "$c" "${SNAP_RSS[$c]:-0}" "${SNAP_CPU[$c]:-0}"
  done
  hist_push_sys "${SYS_CPU_PCT:-0}" "${SYS_MEM_USED_KB:-0}"
  return 0
}

# Constant for the life of the process; computing it inside the frame would be
# a command substitution, i.e. a fork, on every repaint.
FRAME_TAG="${PITCREW_COLLECTOR}·${PITCREW_REFRESH}s"
[ "${PITCREW_RESTART:-0}" = 1 ] && FRAME_TAG+="·supervised"

build_frame() { # → FRAME, and ROW_COMP for mouse hit-testing
  local W H bw sw frame line ts c app i rule_len r ln avail
  # The graph gets whatever the terminal has left over after the fixed
  # columns, so a wide window buys more history instead of dead space.
  term_size; W=$TERM_W; H=$TERM_H
    bw=$(( (W - ROW_PREFIX_W - CELL_GAP_W - 2 * CELL_FIXED_W) / 2 ))
    [ $bw -lt 8 ] && bw=8; [ $bw -gt 40 ] && bw=40
    sw=$(( W / 5 )); [ $sw -lt 12 ] && sw=12; [ $sw -gt 40 ] && sw=40
    ROW_COMP=()
    frame=""; ln=0
    printf -v ts '%(%H:%M:%S)T' -1        # builtin strftime — no `date` fork

    # ── title rule ──
    printf -v line '%b── %b%s · live%b ' "$CYAN" "$BOLD" "${PITCREW_PROJECT_NAME:-pitcrew}" "$RESET$CYAN"
    rule_len=$((W - 12 - ${#PITCREW_PROJECT_NAME} - ${#ts})); [ $rule_len -lt 0 ] && rule_len=0
    r=""; while [ ${#r} -lt $rule_len ]; do r+="─"; done
    frame+="$line$r $ts ──$RESET"$'\e[K\n\e[K\n'; ln=$((ln + 2))

    # ── system gauges, as history rather than a single instant ──
    # Scale floors of 100 and total-RAM make these absolute rather than
    # auto-scaled: 4% CPU should look like 4%, not like a full bar.
    pct_color "${SYS_CPU_PCT:-0}"
    spark "$HIST_SYS_CPU" "$sw" 100 "$PCOL"
    printf -v line '   %bCPU%b %s %3s%%' "$BOLD" "$RESET" "$R" "${SYS_CPU_PCT:-0}"
    frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    if [ -n "$SYS_MEM_TOTAL_KB" ] && [ "${SYS_MEM_TOTAL_KB:-0}" -gt 0 ]; then
      local mpct=$(( SYS_MEM_USED_KB * 100 / SYS_MEM_TOTAL_KB )) used
      pct_color "$mpct"
      spark "$HIST_SYS_MEM" "$sw" "$SYS_MEM_TOTAL_KB" "$PCOL"
      human $(( SYS_MEM_USED_KB * 1024 )); used=$HUMAN
      human $(( SYS_MEM_TOTAL_KB * 1024 ))
      printf -v line '   %bRAM%b %s %s / %s' "$BOLD" "$RESET" "$R" "$used" "$HUMAN"
    else
      printf -v line '   %bRAM%b %bunavailable on this OS%b' "$BOLD" "$RESET" "$GREY" "$RESET"
    fi
    frame+="$line"$'\e[K\n\e[K\n'; ln=$((ln + 2))

    # ── deps, folded onto their own rule line ──
    if [ ${#PITCREW_DEPS[@]} -gt 0 ]; then
      local dep dline
      printf -v dline '%b── deps%b   ' "$BOLD$GREY" "$RESET"
      for dep in "${PITCREW_DEPS[@]}"; do
        state_icon "${SNAP_DEP[$dep]:-down}"
        dline+="$R ${dep}   "
      done
      frame+="$dline"$'\e[K\n\e[K\n'; ln=$((ln + 2))
    fi

    # ── services ──
    summary_line
    printf -v line '%b── services%b%s' "$BOLD$GREY" "$RESET" "$R"
    frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    printf -v line '%b%-*s%-*s%*s%s%b' "$BOLD$GREY" \
      "$ROW_PREFIX_W" "   app" "$((CELL_FIXED_W + bw))" "backend" "$CELL_GAP_W" "" "frontend" "$RESET"
    frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    cell_header "$bw"; local chdr=$R
    printf -v line '%*s%s%*s%s' "$ROW_PREFIX_W" "" "$chdr" "$CELL_GAP_W" "" "$chdr"
    frame+="$line"$'\e[K\n'; ln=$((ln + 1))

    # rows left for services + any expanded trees, keeping the legend/help visible
    avail=$(( H - ln - 5 ))
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
      "$DIM$GREY" "$FRAME_TAG" "$RESET"
    frame+="$line"$'\e[K\n'
    if [ -n "$TOAST" ] && [ $(( ${SNAP_NOW_S:-0} - TOAST_AT )) -lt 5 ]; then
      printf -v line '   %s' "$TOAST"
    else
      TOAST=""; line=""
    fi
    frame+="$line"$'\e[K\n'
    printf -v line ' %b↑↓%b select  %b⏎%b tree  %bl%b logs  %be%b errors  %br%b restart  %bs%b stop  %bm%b menu  %bq%b quit' \
      "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" \
      "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET"
    frame+="$line"$'\e[K'

  FRAME=$frame
  return 0
}

cmd_watch() {
  local W H bw sw frame line ts pick sc c app i n rule_len r
  local ln avail
  tui_enter
  trap 'tui_leave; trap - INT; return 0' INT
  trap 'TERM_DIRTY=1' WINCH
  n=${#PITCREW_COMPS[@]}

  while true; do
    collect_frame
    supervise
    build_frame
    frame=$FRAME
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
           [ -n "$c" ] && { supervise_clear "$c"
                            stop_comp "$c" >/dev/null 2>&1; start_comp "$c" >/dev/null 2>&1
                            toast "${YELLOW}↻${RESET} restarting ${BOLD}$c${RESET}"; } ;;
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
