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

# ── the working set ─────────────────────────────────────────────────────────
# Detection routinely finds 15+ services in a real monorepo and you want three
# of them. Profiles solve that once you know the names; filter, sort and marks
# solve it while you are still working out which three.
FILTER=""                      # substring match on the app name
SORT=name                      # name | ram | cpu | state
declare -gA MARKED=()          # comp -> 1, the set that `a` and `s` act on
VIEW_APPS=()                   # apps visible this frame, in display order
VIEW=()                        # their components, flattened — SEL indexes THIS

# crashed first: the sort exists to bring what needs attention to the top
_state_rank() { case "$1" in crashed) SR=0 ;; starting) SR=1 ;; up) SR=2 ;;
                             external) SR=3 ;; down) SR=4 ;; *) SR=5 ;; esac; }

_app_sortkey() { # $1 app → SORTKEY (higher sorts first)
  local app=$1 c v
  SORTKEY=0
  case "$SORT" in
    ram|cpu) for c in "be-$app" "fe-$app"; do
               [ "$SORT" = ram ] && v=${SNAP_RSS[$c]:-0} || v=${SNAP_CPU[$c]:-0}
               [ "${v:-0}" -gt "$SORTKEY" ] && SORTKEY=${v:-0}
             done ;;
    state)   SORTKEY=9
             for c in "be-$app" "fe-$app"; do
               [ -n "${SNAP_STATE[$c]:-}" ] || continue
               _state_rank "${SNAP_STATE[$c]}"
               [ "$SR" -lt "$SORTKEY" ] && SORTKEY=$SR
             done
             SORTKEY=$(( 9 - SORTKEY )) ;;   # invert: worst state sorts first
  esac
}

build_view() {
  local app c i j n key
  VIEW_APPS=(); VIEW=()
  for app in "${PITCREW_APPS[@]}"; do
    if [ -n "$FILTER" ]; then case "$app" in *"$FILTER"*) ;; *) continue ;; esac; fi
    VIEW_APPS+=("$app")
  done
  if [ "$SORT" != name ]; then
    # insertion sort over a handful of apps — cheaper than forking sort
    local -a keys=()
    n=${#VIEW_APPS[@]}
    for ((i = 0; i < n; i++)); do _app_sortkey "${VIEW_APPS[i]}"; keys[i]=$SORTKEY; done
    for ((i = 1; i < n; i++)); do
      app=${VIEW_APPS[i]}; key=${keys[i]}; j=$((i - 1))
      while [ $j -ge 0 ] && [ "${keys[j]}" -lt "$key" ]; do
        VIEW_APPS[j+1]=${VIEW_APPS[j]}; keys[j+1]=${keys[j]}; j=$((j - 1))
      done
      VIEW_APPS[j+1]=$app; keys[j+1]=$key
    done
  fi
  for app in "${VIEW_APPS[@]}"; do
    for c in "be-$app" "fe-$app"; do
      [ -n "${SNAP_STATE[$c]:-}" ] && VIEW+=("$c")
    done
  done
  return 0
}

# what `a` and `s` act on: the marked set, or the selection when nothing is marked
target_set() {
  TARGETS=()
  local c
  for c in "${PITCREW_COMPS[@]}"; do [ -n "${MARKED[$c]:-}" ] && TARGETS+=("$c"); done
  [ ${#TARGETS[@]} -eq 0 ] && [ -n "${VIEW[$SEL]:-}" ] && TARGETS=("${VIEW[$SEL]}")
  return 0
}

declare -gA EXPANDED=()                      # comp -> 1 when its process tree is open
declare -gA ROW_COMP=()                      # screen row -> comp (for mouse hit-testing)
SEL=0                                        # index into PITCREW_COMPS
ROW_OFF=0                                    # first VIEW_APPS index drawn this frame
SCROLL_ABOVE=0                               # apps hidden off the top / bottom
SCROLL_BELOW=0

_app_rows() { # $1 app → APP_ROWS: screen rows this app costs in the current layout
  local app=$1 c
  if [ "$LAYOUT" = wide ]; then
    APP_ROWS=1
  else
    APP_ROWS=0
    for c in "be-$app" "fe-$app"; do [ -n "${SNAP_STATE[$c]:-}" ] && APP_ROWS=$((APP_ROWS + 1)); done
  fi
  for c in "be-$app" "fe-$app"; do
    [ -n "${EXPANDED[$c]:-}" ] || continue
    local -a pids=(${SNAP_PIDS[$c]:-})
    APP_ROWS=$(( APP_ROWS + ${#pids[@]} ))
  done
  return 0
}

# The list used to simply stop at the bottom of the screen: on a short window
# ↑/↓ moved a selection you could no longer see, and `a`/`s` then acted on an
# invisible row. Scroll the window to the selection instead of clipping it.
scroll_to_selection() { # $1 = rows available → ROW_OFF
  local budget=$1 si=0 i sum=0 selapp=${VIEW[$SEL]:-}
  selapp=${selapp#??-}
  for i in "${!VIEW_APPS[@]}"; do
    [ "${VIEW_APPS[i]}" = "$selapp" ] && { si=$i; break; }
  done
  [ "$ROW_OFF" -gt "$si" ] && ROW_OFF=$si
  [ "$ROW_OFF" -lt 0 ] && ROW_OFF=0
  for ((i = ROW_OFF; i <= si; i++)); do _app_rows "${VIEW_APPS[i]}"; sum=$((sum + APP_ROWS)); done
  while [ "$sum" -gt "$budget" ] && [ "$ROW_OFF" -lt "$si" ]; do
    _app_rows "${VIEW_APPS[ROW_OFF]}"
    sum=$(( sum - APP_ROWS )); ROW_OFF=$(( ROW_OFF + 1 ))
  done
  return 0
}

summary_line() { # → R, and SUM_UP / SUM_STARTING for the empty state
  local c st up=0 starting=0 crashed=0 down=0 external=0
  for c in "${PITCREW_COMPS[@]}"; do
    case "${SNAP_STATE[$c]:-down}" in
      up) up=$((up+1)) ;; starting) starting=$((starting+1)) ;;
      crashed) crashed=$((crashed+1)) ;; external) external=$((external+1)) ;;
      down) down=$((down+1)) ;;
    esac
  done
  SUM_UP=$up; SUM_STARTING=$starting; SUM_EXTERNAL=$external
  R="  ${C_OK}${up} up${RESET}"
  [ $starting -gt 0 ] && R+="${C_MUTED} · ${RESET}${C_WARN}${starting} starting${RESET}"
  [ $crashed  -gt 0 ] && R+="${C_MUTED} · ${RESET}${C_CRIT}${crashed} crashed${RESET}"
  [ $external -gt 0 ] && R+="${C_MUTED} · ${RESET}${C_INFO}${external} external${RESET}"
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
      external) [ "$RAILC" = "$C_FAINT" ] && RAILC=$C_INFO ;;
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
CELL_FIXED_W=26      # icon(2) + port(7) + ram+cpu(12) + err(5)
ROW_PREFIX_W=15      # marker(2) + " " + app(11) + " "
ROW_PREFIX_MIN_W=6   # marker(2) + " " + app(2) + " " — nothing below this reads
CELL_GAP_W=2         # between the backend and frontend cells
CELL_MIN_GRAPH_W=6   # under this a sparkline is decoration, not information

# One place decides what the frame is drawing, so the column header, the rows
# and the selection band can never disagree about it. Three tiers, widest first:
#
#   wide    backend and frontend side by side
#   narrow  one component per row — one readable cell beats two squeezed ones
#   tiny    one component per row and NO graph: under ~50 columns the sparkline
#           pushes the port and the numbers off the right edge, and with
#           auto-wrap off the terminal drops them silently. Losing history is
#           cheap; losing "which port, how much RAM" is not.
layout_for_width() { # $1 W → LAYOUT, GRAPH_W, PREFIX_W
  local w=$1
  PREFIX_W=$ROW_PREFIX_W
  if [ "$w" -ge "${PITCREW_NARROW_AT:-110}" ]; then
    LAYOUT=wide
    GRAPH_W=$(( (w - PREFIX_W - CELL_GAP_W - 2 * CELL_FIXED_W) / 2 ))
  else
    LAYOUT=narrow
    GRAPH_W=$(( w - PREFIX_W - CELL_FIXED_W - 2 ))
  fi
  if [ "$GRAPH_W" -lt "$CELL_MIN_GRAPH_W" ]; then
    LAYOUT=tiny
    GRAPH_W=0
    # give the name column whatever the cell leaves, so the row still ends
    # inside the terminal instead of being cut off by it
    PREFIX_W=$(( w - CELL_FIXED_W ))
    [ "$PREFIX_W" -gt "$ROW_PREFIX_W" ]     && PREFIX_W=$ROW_PREFIX_W
    [ "$PREFIX_W" -lt "$ROW_PREFIX_MIN_W" ] && PREFIX_W=$ROW_PREFIX_MIN_W
  fi
  [ "$GRAPH_W" -gt 40 ] && GRAPH_W=40
  return 0
}

cell_header() { # $1 graph width → R, exactly CELL_FIXED_W + $1 wide
  local g=""
  [ "$1" -gt 0 ] && printf -v g '%-*s' "$1" "graph"
  printf -v R '%b%2s%-7s%s %6s %4s %-4s%b' \
    "$C_MUTED" "" "port" "$g" "ram" "cpu" "" "$RESET"
}

comp_cell() { # $1 comp, $2 graph width (0 = no graph column) → R: one aligned cell
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
    if [ "$gw" -gt 0 ]; then
      spark "${HIST_MEM[$c]:-}" "$gw" 67108864            # 64M floor
      cell+="$R"
    fi
    human "$cur"
    # units and the % sign are chrome: bright value, dim unit
    printf -v R ' %b%5s%b%b%s%b %b%3s%b%b%%%b' \
      "$PCOL" "${HUMAN%[GM]}" "$RESET" "$C_MUTED" "${HUMAN: -1}" "$RESET" \
      "$C_TEXT" "${SNAP_CPU[$c]:-0}" "$RESET" "$C_MUTED" "$RESET"
    cell+="$R"
  elif is_external "$c"; then
    # %*.*s, not %*s: "external" is 8 columns and the graph slot can be 6
    [ "$gw" -gt 0 ] && {
      printf -v R '%b%*.*s%b' "$DIM$GREY" "$gw" "$gw" "external" "$RESET"; cell+="$R"; }
    printf -v R ' %6s %4s' "—" "—"
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
  # Part of the frame, not of the caller: build_frame has to be self-contained
  # or the performance test drives something the dashboard does not.
  build_view
  local nview=${#VIEW[@]}
  [ "$nview" -gt 0 ] && [ "$SEL" -ge "$nview" ] && SEL=$((nview - 1))
  [ "$SEL" -lt 0 ] && SEL=0
  # The graph gets whatever the terminal has left over after the fixed
  # columns, so a wide window buys more history instead of dead space.
  term_size; W=$TERM_W; H=$TERM_H
    layout_for_width "$W"
    bw=$GRAPH_W
    local narrow=0; [ "$LAYOUT" = wide ] || narrow=1
    # A short window has to spend its rows on services, not on chrome. The two
    # system gauges fold onto one line and the blank spacers and the legend go
    # — otherwise the header alone eats the screen and the table renders zero
    # rows, which is what a 14-line terminal used to show.
    local compact=0 micro=0
    [ "$H" -lt "${PITCREW_COMPACT_AT:-24}" ] && compact=1
    # A pane this short has room for the title, the table and the keys and
    # nothing else. Everything that is context rather than content goes.
    [ "$H" -lt "${PITCREW_MICRO_AT:-12}" ] && { compact=1; micro=1; }
    local gap=$'\e[K\n\e[K\n' gapn=2
    [ $compact = 1 ] && { gap=$'\e[K\n'; gapn=1; }
    if [ $compact = 1 ]; then
      sw=$(( W / 8 )); [ $sw -lt 8 ] && sw=8; [ $sw -gt 20 ] && sw=20
    else
      sw=$(( W / 5 )); [ $sw -lt 12 ] && sw=12; [ $sw -gt 40 ] && sw=40
    fi
    ROW_COMP=()
    SCROLL_ABOVE=0; SCROLL_BELOW=0
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
    frame+="$line$r $ts ──$RESET$gap"; ln=$((ln + gapn))

    # ── system gauges, as history rather than a single instant ──
    # Scale floors of 100 and total-RAM make these absolute rather than
    # auto-scaled: 4% CPU should look like 4%, not like a full bar.
    if [ $micro = 0 ]; then
      pct_color "${SYS_CPU_PCT:-0}"
      spark "$HIST_SYS_CPU" "$sw" 100 "$PCOL"
      local cpuline
      printf -v cpuline '   %bCPU%b %s %b%3s%b%b%%%b' "$C_MUTED" "$RESET" "$R" \
        "$C_TEXT" "${SYS_CPU_PCT:-0}" "$RESET" "$C_MUTED" "$RESET"
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
      # compact folds them onto one line; the RAM gauge is worth more than the
      # blank row under it
      if [ $compact = 1 ]; then
        frame+="$cpuline$line"$'\e[K\n'; ln=$((ln + 1))
      else
        frame+="$cpuline"$'\e[K\n'"$line"$'\e[K\n\e[K\n'; ln=$((ln + 3))
      fi
    fi

    # ── deps, folded onto their own rule line ──
    # Six deps used to run 40 columns past the right edge, and with auto-wrap
    # off the terminal ate them without a trace. Wrap onto a continuation line;
    # when there are no rows to spare, say how many did not fit.
    if [ ${#PITCREW_DEPS[@]} -gt 0 ] && [ $micro = 0 ]; then
      local dep dline dvis dshown=0 dtotal=${#PITCREW_DEPS[@]}
      local DEPS_INDENT_W=10        # visible width of "── deps   "
      printf -v dline '%b──%b %b%s%b   ' "$C_FAINT" "$RESET" "$C_TEXT$BOLD" "deps" "$RESET"
      dvis=$DEPS_INDENT_W
      for dep in "${PITCREW_DEPS[@]}"; do
        if [ $(( dvis + ${#dep} + 5 )) -gt "$W" ]; then
          # nothing on this line yet means it will never fit — truncate, do not
          # loop forever widening a line the terminal cannot hold
          if [ $compact = 1 ] || [ "$dvis" -le "$DEPS_INDENT_W" ]; then
            printf -v R '%b+%s%b' "$C_MUTED" "$(( dtotal - dshown ))" "$RESET"
            dline+="$R"; break
          fi
          frame+="$dline"$'\e[K\n'; ln=$((ln + 1))
          printf -v dline '%*s' "$DEPS_INDENT_W" ''; dvis=$DEPS_INDENT_W
        fi
        state_icon "${SNAP_DEP[$dep]:-down}"
        dline+="$R ${dep}   "
        dvis=$(( dvis + ${#dep} + 5 )); dshown=$(( dshown + 1 ))
      done
      frame+="$dline$gap"; ln=$((ln + gapn))
    fi

    # ── services ──
    summary_line
    printf -v line '%b──%b %b%s%b%s' "$C_FAINT" "$RESET" "$C_TEXT$BOLD" "services" "$RESET" "$R"
    frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    # Column headers over an empty table are pure noise — they were the worst
    # thing about the first screen anyone sees.
    local empty=0
    # "nothing is running" is only the right thing to say on a resting
    # dashboard. Once you are filtering or marking you are choosing what to
    # start, and hiding the rows is exactly backwards.
    local nmarked=0 _mc
    for _mc in "${PITCREW_COMPS[@]}"; do [ -n "${MARKED[$_mc]:-}" ] && nmarked=$((nmarked + 1)); done
    [ "${SUM_UP:-0}" -eq 0 ] && [ "${SUM_STARTING:-0}" -eq 0 ] && [ "${SUM_EXTERNAL:-0}" -eq 0 ] \
      && [ -z "$FILTER" ] && [ "$nmarked" -eq 0 ] && empty=1

    cell_header "$bw"; local chdr=$R
    if [ $empty = 1 ] || [ $micro = 1 ]; then :
    elif [ $narrow = 1 ]; then
      printf -v line '%b%-*.*s%s%b' "$C_MUTED" "$PREFIX_W" "$PREFIX_W" "   service" "$chdr" "$RESET"
      frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    else
      printf -v line '%b%-*s%-*s%*s%s%b' "$C_MUTED" \
        "$PREFIX_W" "   app" "$((CELL_FIXED_W + bw))" "backend" "$CELL_GAP_W" "" "frontend" "$RESET"
      frame+="$line"$'\e[K\n'; ln=$((ln + 1))
      printf -v line '%*s%s%*s%s' "$PREFIX_W" "" "$chdr" "$CELL_GAP_W" "" "$chdr"
      frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    fi

    # Rows left for services and any expanded trees, keeping the footer on
    # screen. The footer is blank + legend + status + toast + keys; compact
    # drops the blank and the legend, so it is three rows instead of five.
    local foot=5; [ $compact = 1 ] && foot=3; [ $micro = 1 ] && foot=2
    avail=$(( H - ln - foot ))
    [ $avail -lt 0 ] && avail=0

    # A first run used to show twelve rows of dots under a table header. Say
    # what to do instead, centred on its own width rather than a shared guess.
    if [ ${#VIEW_APPS[@]} -eq 0 ] && [ -n "$FILTER" ]; then
      local nomatch
      printf -v nomatch '%bnothing matches%b %b %s %b' "$C_MUTED" "$RESET" "$C_CAP$C_TEXT" "$FILTER" "$RESET"
      frame+=$'\e[K\n'; ln=$((ln + 1))
      centre "$W" $(( 16 + ${#FILTER} + 2 )) "$nomatch"
      frame+="$R"$'\e[K\n'; ln=$((ln + 1))
      avail=$(( avail - 2 ))
    elif [ $empty = 1 ]; then
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
    scroll_to_selection "$avail"
    local drawn=0
    for ((i = ROW_OFF; i < ${#VIEW_APPS[@]}; i++)); do
      [ $avail -le 0 ] && break
      drawn=$(( drawn + 1 ))
      app=${VIEW_APPS[i]}
      local nm=$C_SUBTLE selected=0
      if [ "${VIEW[$SEL]:-}" = "be-$app" ] || [ "${VIEW[$SEL]:-}" = "fe-$app" ]; then
        selected=1; nm="$C_TEXT$BOLD"
      fi
      rail_color "$app"
      local label=$app mark=" "
      [ -n "${APP_ICON[$app]:-}" ] && label="${APP_ICON[$app]} $app"
      [ -n "${MARKED[be-$app]:-}${MARKED[fe-$app]:-}" ] && mark="${C_ACCENT2}✓${RESET}"
      local nw=$(( PREFIX_W - 4 ))
      printf -v line '%b▐%b%b %b%-*.*s%b ' "$RAILC" "$RESET" "$mark" "$nm" "$nw" "$nw" "$label" "$RESET"
      if [ $narrow = 1 ]; then
        # one component per row; the role moves into the label
        local nrow rc
        for rc in "be-$app" "fe-$app"; do
          [ -n "${SNAP_STATE[$rc]:-}" ] || continue
          rail_color "$app"
              printf -v nrow '%b▐%b%b %b%-*.*s%b ' "$RAILC" "$RESET" "$mark" "$nm" "$nw" "$nw" "${label} ${rc:0:2}" "$RESET"
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
        local rw=$(( PREFIX_W + CELL_GAP_W + 2 * (CELL_FIXED_W + bw) )) sp=""
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
    SCROLL_ABOVE=$ROW_OFF
    SCROLL_BELOW=$(( ${#VIEW_APPS[@]} - ROW_OFF - drawn ))
    [ "$SCROLL_BELOW" -lt 0 ] && SCROLL_BELOW=0
    fi

    if [ $compact = 0 ]; then
      frame+=$'\e[K\n'; ln=$((ln + 1))
      # Auto-wrap is off, so anything wider than the terminal is silently
      # truncated by it — drop legend entries that will not fit instead.
      local leg="   " lg vis=3
      for lg in "● up" "◐ starting" "✗ crashed" "◇ not ours" "○ down" "· n/a" "⚡ log errors" "$FRAME_TAG"; do
        [ $(( vis + ${#lg} + 2 )) -gt "$W" ] && break
        leg+="$lg  "; vis=$(( vis + ${#lg} + 2 ))
      done
      printf -v line '%b%s%b' "$C_FAINT" "$leg" "$RESET"
      frame+="$line"$'\e[K\n'; ln=$((ln + 1))
    fi

    local ws="" nmark=0 mc
    for mc in "${PITCREW_COMPS[@]}"; do [ -n "${MARKED[$mc]:-}" ] && nmark=$((nmark + 1)); done
    [ "$SORT" != name ] && ws+="   ${C_MUTED}sort${RESET} ${C_TEXT}${SORT}${RESET}"
    [ -n "$FILTER" ]    && ws+="   ${C_MUTED}filter${RESET} ${C_CAP}${C_TEXT} ${FILTER} ${RESET}"
    [ "$nmark" -gt 0 ]  && ws+="   ${C_ACCENT2}✓ ${nmark} marked${RESET}"
    [ "$SCROLL_ABOVE" -gt 0 ] && ws+="   ${C_MUTED}↑ ${SCROLL_ABOVE} above${RESET}"
    [ "$SCROLL_BELOW" -gt 0 ] && ws+="   ${C_MUTED}↓ ${SCROLL_BELOW} below${RESET}"
    if [ -n "$ws" ]; then frame+="$ws"$'\e[K\n'; else frame+=$'\e[K\n'; fi
    ln=$((ln + 1))

    if [ -n "$TOAST" ] && [ $(( ${SNAP_NOW_S:-0} - TOAST_AT )) -lt 5 ]; then
      printf -v line '   %s' "$TOAST"
    else
      TOAST=""; line=""
    fi
    [ $micro = 0 ] && { frame+="$line"$'\e[K\n'; ln=$((ln + 1)); }
    # key caps: an inverse-video cap and a dim label reads as an app footer
    # rather than as a line of shell output
    line=" "
    local kc cap lbl kvis=1 addw
    for kc in "↑↓:select" "␣:mark" "a:start" "s:stop" "r:restart" "⏎:tree" \
            "/:filter" "o:sort" "l:logs" "e:errors" "p:project" "m:menu" "q:quit"; do
      cap=${kc%%:*}; lbl=${kc#*:}
      addw=$(( ${#cap} + 2 + 1 + ${#lbl} + 2 ))     # " cap " + " " + label + "  "
      [ $(( kvis + addw )) -gt "$W" ] && break
      line+="${C_CAP}${C_TEXT} ${cap} ${RESET}${C_MUTED} ${lbl}${RESET}  "
      kvis=$(( kvis + addw ))
    done
    frame+="$line"$'\e[K'

  # Last resort. Auto-wrap is off and the frame is painted from the home
  # position, so ONE line too many scrolls the alt screen and every repaint
  # after it lands a row off — the display does not recover. Below ~8 rows
  # there is no layout left to shed, so cut the frame rather than corrupt the
  # terminal. $ln is the newline count kept as the frame is built; the last
  # line carries none, so the frame is $ln + 1 rows tall.
  if [ "$ln" -ge "$H" ]; then
    local keep=$(( H - 1 )) k=0 out="" seg
    [ $keep -lt 0 ] && keep=0
    while IFS= read -r seg; do
      [ $k -ge $keep ] && break
      [ $k -gt 0 ] && out+=$'\n'
      out+="$seg"; k=$(( k + 1 ))
    done <<< "$frame"
    frame=$out
  fi

  FRAME=$frame
  return 0
}

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
