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

summary_line() { # → R, and SUM_UP / SUM_STARTING for the empty state
  local c st up=0 starting=0 crashed=0 down=0
  for c in "${PITCREW_COMPS[@]}"; do
    case "${SNAP_STATE[$c]:-down}" in
      up) up=$((up+1)) ;; starting) starting=$((starting+1)) ;;
      crashed) crashed=$((crashed+1)) ;; down) down=$((down+1)) ;;
    esac
  done
  SUM_UP=$up; SUM_STARTING=$starting
  R="  ${C_OK}${up} up${RESET}"
  [ $starting -gt 0 ] && R+="${C_MUTED} · ${RESET}${C_WARN}${starting} starting${RESET}"
  [ $crashed  -gt 0 ] && R+="${C_MUTED} · ${RESET}${C_CRIT}${crashed} crashed${RESET}"
  [ $down     -gt 0 ] && R+="${C_MUTED} · ${down} down${RESET}"
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

# The rail colour is the worst state across an app's roles: it is a
# peripheral-vision signal, so it must report the thing that needs attention,
# not an average.
centre() { # $1 total width, $2 visible width of $3, $3 rendered text → R
  local pad=$(( ($1 - $2) / 2 )); [ $pad -lt 0 ] && pad=0
  printf -v R '%*s%s' "$pad" "" "$3"
}

rail_color() { # $1 app → RAILC
  local app=$1 s1=${SNAP_STATE[be-$app]:-n/a} s2=${SNAP_STATE[fe-$app]:-n/a} st
  RAILC=$C_FAINT
  for st in "$s1" "$s2"; do
    case "$st" in
      crashed)  RAILC=$C_CRIT; return ;;
      starting) RAILC=$C_WARN ;;
      up)       [ "$RAILC" = "$C_FAINT" ] && RAILC=$C_OK ;;
    esac
  done
}

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
    "$C_MUTED" "" "port" "$1" "graph" "ram" "cpu" "" "$RESET"
}

comp_cell() { # $1 comp, $2 graph width → R: one aligned service cell
  local c=$1 gw=$2 st port cur app role cell pct half i
  st=${SNAP_STATE[$c]:-n/a}
  app=${c#??-}; role=${c:0:2}
  if [ "$role" = be ]; then port=${PITCREW_BE_PORT[$app]:-}; else port=${PITCREW_FE_PORT[$app]:-}; fi
  cur=${SNAP_RSS[$c]:-}

  state_icon "$st"; cell="$R "
  if [ "$st" = n/a ]; then
    printf -v R '%b%-6s%b ' "$C_FAINT" "n/a" "$RESET"
  else
    printf -v R '%b:%-5s%b ' "$C_MUTED" "${port:--}" "$RESET"
  fi
  cell+="$R"

  if [[ "$cur" =~ ^[0-9]+$ ]] && [ "$cur" -gt 0 ]; then
    # The graph's HEIGHT auto-scales to this service's own recent range, and
    # its COLOUR runs cool-to-hot by cell height. That leaves "how close am I
    # to the configured cap" without a channel, so it moves to the number —
    # which is where you look for it anyway.
    pct=$(( cur * 100 / ${COMP_MAX_B[$c]:-1} ))
    pct_color "$pct"
    spark "${HIST_MEM[$c]:-}" "$gw" 67108864              # 64M floor
    cell+="$R"
    human "$cur"
    # units and the % sign are chrome: bright value, dim unit
    printf -v R ' %b%5s%b%b%s%b %b%3s%b%b%%%b' \
      "$PCOL" "${HUMAN%[GM]}" "$RESET" "$C_MUTED" "${HUMAN: -1}" "$RESET" \
      "$C_TEXT" "${SNAP_CPU[$c]:-0}" "$RESET" "$C_MUTED" "$RESET"
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
    # a faint baseline, not a lone dot: the column reads as an empty chart
    # rather than as something broken
    local base=""
    for ((i = 0; i < gw; i++)); do base+="▁"; done
    printf -v R '%b%s%b %6s %4s' "$C_FAINT" "$base" "$RESET" "" ""
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

FRAME_N=0
collect_frame() {
  FRAME_N=$(( FRAME_N + 1 ))
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
    # Below this width two cells side by side stop being readable: the graph is
    # squeezed to nothing and the columns collide. One component per row beats
    # two unreadable ones.
    local narrow=0
    [ "$W" -lt "${PITCREW_NARROW_AT:-110}" ] && narrow=1
    if [ $narrow = 1 ]; then
      bw=$(( W - ROW_PREFIX_W - CELL_FIXED_W - 2 ))
    else
      bw=$(( (W - ROW_PREFIX_W - CELL_GAP_W - 2 * CELL_FIXED_W) / 2 ))
    fi
    [ $bw -lt 8 ] && bw=8; [ $bw -gt 40 ] && bw=40
    sw=$(( W / 5 )); [ $sw -lt 12 ] && sw=12; [ $sw -gt 40 ] && sw=40
    ROW_COMP=()
    frame=""; ln=0
    printf -v ts '%(%H:%M:%S)T' -1        # builtin strftime — no `date` fork

    # ── title rule ──
    printf -v line '%b──%b %b%s%b %blive%b %b' "$C_FAINT" "$RESET" "$C_ACCENT$BOLD" "${PITCREW_PROJECT_NAME:-pitcrew}" "$RESET" "$C_MUTED" "$RESET" "$C_FAINT"
    # visible chrome: "── " + name + " live " + rule + " " + ts + " ──", and
    # one column short of the edge on purpose. Auto-wrap is off so a full-width
    # line is legal, but a printable character in the very last cell is the
    # classic place for a terminal (tmux especially) to disagree about whether
    # the cursor wrapped — and a single wrong wrap scrolls the whole frame.
    rule_len=$((W - 14 - ${#PITCREW_PROJECT_NAME} - ${#ts})); [ $rule_len -lt 0 ] && rule_len=0
    r=""; while [ ${#r} -lt $rule_len ]; do r+="─"; done
    frame+="$line$r $ts ──$RESET"$'\e[K\n\e[K\n'; ln=$((ln + 2))

    # ── system gauges, as history rather than a single instant ──
    # Scale floors of 100 and total-RAM make these absolute rather than
    # auto-scaled: 4% CPU should look like 4%, not like a full bar.
    pct_color "${SYS_CPU_PCT:-0}"
    spark "$HIST_SYS_CPU" "$sw" 100 "$PCOL"
    printf -v line '   %bCPU%b %s %b%3s%b%b%%%b' "$C_MUTED" "$RESET" "$R" "$C_TEXT" "${SYS_CPU_PCT:-0}" "$RESET" "$C_MUTED" "$RESET"
    frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    if [ -n "$SYS_MEM_TOTAL_KB" ] && [ "${SYS_MEM_TOTAL_KB:-0}" -gt 0 ]; then
      local mpct=$(( SYS_MEM_USED_KB * 100 / SYS_MEM_TOTAL_KB )) used
      pct_color "$mpct"
      spark "$HIST_SYS_MEM" "$sw" "$SYS_MEM_TOTAL_KB" "$PCOL"
      human $(( SYS_MEM_USED_KB * 1024 )); used=$HUMAN
      human $(( SYS_MEM_TOTAL_KB * 1024 ))
      printf -v line '   %bRAM%b %s %b%s%b %b/%b %b%s%b' "$C_MUTED" "$RESET" "$R" \
        "$C_TEXT" "$used" "$RESET" "$C_FAINT" "$RESET" "$C_MUTED" "$HUMAN" "$RESET"
    else
      printf -v line '   %bRAM%b %bunavailable on this OS%b' "$C_MUTED" "$RESET" "$C_FAINT" "$RESET"
    fi
    frame+="$line"$'\e[K\n\e[K\n'; ln=$((ln + 2))

    # ── deps, folded onto their own rule line ──
    if [ ${#PITCREW_DEPS[@]} -gt 0 ]; then
      local dep dline
      printf -v dline '%b──%b %b%s%b   ' "$C_FAINT" "$RESET" "$C_TEXT$BOLD" "deps" "$RESET"
      for dep in "${PITCREW_DEPS[@]}"; do
        state_icon "${SNAP_DEP[$dep]:-down}"
        dline+="$R ${dep}   "
      done
      frame+="$dline"$'\e[K\n\e[K\n'; ln=$((ln + 2))
    fi

    # ── services ──
    summary_line
    printf -v line '%b──%b %b%s%b%s' "$C_FAINT" "$RESET" "$C_TEXT$BOLD" "services" "$RESET" "$R"
    frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    # Column headers over an empty table are pure noise — they were the worst
    # thing about the first screen anyone sees.
    local empty=0
    [ "${SUM_UP:-0}" -eq 0 ] && [ "${SUM_STARTING:-0}" -eq 0 ] && empty=1

    cell_header "$bw"; local chdr=$R
    if [ $empty = 1 ]; then :
    elif [ $narrow = 1 ]; then
      printf -v line '%b%-*s%s%b' "$C_MUTED" "$ROW_PREFIX_W" "   service" "$chdr" "$RESET"
      frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    else
      printf -v line '%b%-*s%-*s%*s%s%b' "$C_MUTED" \
        "$ROW_PREFIX_W" "   app" "$((CELL_FIXED_W + bw))" "backend" "$CELL_GAP_W" "" "frontend" "$RESET"
      frame+="$line"$'\e[K\n'; ln=$((ln + 1))
      printf -v line '%*s%s%*s%s' "$ROW_PREFIX_W" "" "$chdr" "$CELL_GAP_W" "" "$chdr"
      frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    fi

    # rows left for services + any expanded trees, keeping the legend/help visible
    avail=$(( H - ln - 5 ))

    # A first run used to show twelve rows of dots under a table header. Say
    # what to do instead, centred on its own width rather than a shared guess.
    if [ $empty = 1 ]; then
      local msg1 msg2
      printf -v msg1 '%b%s%b' "$C_TEXT$BOLD" "nothing is running yet" "$RESET"
      printf -v msg2 '%bpress%b %b m %b %bfor the menu, or run%b %b pitcrew start %b' \
        "$C_MUTED" "$RESET" "$C_CAP$C_TEXT" "$RESET" \
        "$C_MUTED" "$RESET" "$C_CAP$C_TEXT" "$RESET"
      frame+=$'\e[K\n'; ln=$((ln + 1))
      centre "$W" 22 "$msg1"; frame+="$R"$'\e[K\n'; ln=$((ln + 1))
      frame+=$'\e[K\n'; ln=$((ln + 1))
      centre "$W" 46 "$msg2"; frame+="$R"$'\e[K\n'; ln=$((ln + 1))
      avail=$(( avail - 4 ))
    else
    for ((i = 0; i < ${#PITCREW_APPS[@]}; i++)); do
      [ $avail -le 0 ] && break
      app=${PITCREW_APPS[i]}
      local nm=$C_SUBTLE selected=0
      if [ "${PITCREW_COMPS[$SEL]:-}" = "be-$app" ] || [ "${PITCREW_COMPS[$SEL]:-}" = "fe-$app" ]; then
        selected=1; nm="$C_TEXT$BOLD"
      fi
      rail_color "$app"
      local label=$app
      [ -n "${APP_ICON[$app]:-}" ] && label="${APP_ICON[$app]} $app"
      printf -v line '%b▐%b  %b%-11.11s%b ' "$RAILC" "$RESET" "$nm" "$label" "$RESET"
      if [ $narrow = 1 ]; then
        # one component per row; the role moves into the label
        local nrow rc
        for rc in "be-$app" "fe-$app"; do
          [ -n "${SNAP_STATE[$rc]:-}" ] || continue
          rail_color "$app"
          printf -v nrow '%b▐%b  %b%-11.11s%b ' "$RAILC" "$RESET" "$nm" "${label} ${rc:0:2}" "$RESET"
          comp_cell "$rc" "$bw"; nrow+="$R"
          frame+="$nrow"$'\e[K\n'; ln=$((ln + 1)); avail=$((avail - 1))
          ROW_COMP[$ln]="$app"
        done
        continue
      fi
      comp_cell "be-$app" "$bw"; line+="$R"
      comp_cell "fe-$app" "$bw"; line+="  $R"
      # Selection is a full-width background band rather than a caret. Every
      # RESET inside the row would drop the band, so re-arm it after each one.
      if [ "$selected" = 1 ] && [ -n "$C_BAND" ]; then
        line=${line//"$RESET"/"$RESET$C_BAND"}
        local rw=$(( ROW_PREFIX_W + CELL_GAP_W + 2 * (CELL_FIXED_W + bw) )) sp=""
        while [ ${#sp} -lt $(( W - rw )) ] && [ $rw -lt "$W" ]; do sp+=" "; done
        line="$C_BAND$line$sp$RESET"
      fi
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
          printf -v line '   %b│%b   %b%s%b %b%-6s%b %b%-18s%b %b%6s%b%b%s%b %b%3s%b%b%%%b' \
            "$C_FAINT" "$RESET" "$C_FAINT" "$branch" "$RESET" \
            "$C_MUTED" "$p" "$RESET" "$C_SUBTLE" "${SNAP_PROC_CMD[$p]:-?}" "$RESET" \
            "$C_TEXT" "${HUMAN%[GM]}" "$RESET" "$C_MUTED" "${HUMAN: -1}" "$RESET" \
            "$C_TEXT" "${SNAP_PROC_CPU[$p]:-0}" "$RESET" "$C_MUTED" "$RESET"
          frame+="$line"$'\e[K\n'
          ln=$((ln + 1)); avail=$((avail - 1))
        done
      done
    done
    fi

    frame+=$'\e[K\n'
    # Auto-wrap is off, so anything wider than the terminal is silently
    # truncated by it — drop legend entries that will not fit instead.
    local leg="   " lg vis=3
    for lg in "● up" "◐ starting" "✗ crashed" "○ down" "· n/a" "⚡ log errors" "$FRAME_TAG"; do
      [ $(( vis + ${#lg} + 2 )) -gt "$W" ] && break
      leg+="$lg  "; vis=$(( vis + ${#lg} + 2 ))
    done
    printf -v line '%b%s%b' "$C_FAINT" "$leg" "$RESET"
    frame+="$line"$'\e[K\n'
    if [ -n "$TOAST" ] && [ $(( ${SNAP_NOW_S:-0} - TOAST_AT )) -lt 5 ]; then
      printf -v line '   %s' "$TOAST"
    else
      TOAST=""; line=""
    fi
    frame+="$line"$'\e[K\n'
    # key caps: an inverse-video cap and a dim label reads as an app footer
    # rather than as a line of shell output
    line=" "
    local kc cap lbl kvis=1 addw
    for kc in "↑↓:select" "⏎:tree" "l:logs" "e:errors" "r:restart" "s:stop" "m:menu" "q:quit"; do
      cap=${kc%%:*}; lbl=${kc#*:}
      addw=$(( ${#cap} + 2 + 1 + ${#lbl} + 2 ))     # " cap " + " " + label + "  "
      [ $(( kvis + addw )) -gt "$W" ] && break
      line+="${C_CAP}${C_TEXT} ${cap} ${RESET}${C_MUTED} ${lbl}${RESET}  "
      kvis=$(( kvis + addw ))
    done
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
