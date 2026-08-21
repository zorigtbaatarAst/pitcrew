#!/usr/bin/env bash
# lib/05a-dashboard.sh — the viewport, the working set, and the one-shot table.
#
# Every value on screen comes from the SNAP_* arrays that snapshot() filled
# for this frame, and the frame is composed by appending to strings — never by
# `$(helper)`, which would fork. See the calling-convention note at the top of
# lib/04-meters.sh.
#
# NOTE ON THE NAME: every file in this group is `05<letter>-`, never `05-`.
# `lib/*.sh` is sourced in glob order, and a UTF-8 collation IGNORES punctuation
# when comparing — so a bare "05-dashboard.sh" would sort AFTER "05b-cells.sh" on a normal
# desktop and before it under LC_ALL=C. This group has top-level code that reads
# variables the previous file sets, so that difference is the difference between
# working and `PITCREW_REFRESH: unbound variable`. Letters sort the same either
# way.
#
# Split out of one 1200-line file. The seams are the ones that were already
# there in comments: the viewport and the working set, the cell/layout
# arithmetic, the frame builder, and the interactive loop. Bash does not care
# what order functions are defined in, and lib/*.sh is sourced in name order,
# so 05a → 05b → 05c → 05d all load before 06.

PITCREW_REFRESH="${PITCREW_REFRESH:-1}"      # seconds between frames; fractions OK
PITCREW_MOUSE="${PITCREW_MOUSE:-0}"          # opt-in: click to select/expand, wheel to scroll

# ── the viewport ────────────────────────────────────────────────────────────
# The terminal is the window, and like a browser window it can be resized at
# any moment. Every layout decision below is a function of these two numbers,
# so measuring them wrong does not degrade the frame — it corrupts it.
#
# $COLUMNS is NOT the answer, and trusting it was a real bug: bash sets that
# variable for itself and does not keep it up to date, so after a resize the
# dashboard went on drawing a 150-column frame into an 84-column terminal.
# Auto-wrap is off, so the terminal silently guillotined every row — the
# "frontend" header showed as "f", the second column vanished mid-cell, and
# the key hints stopped at whatever cap straddled the edge. Ask the tty.
#
# Asking costs a fork, which is why it is not asked every frame: SIGWINCH says
# when the answer changed, and that is the only time the question is worth
# asking. Measurement order, most explicit first:
#
#   PITCREW_COLS / PITCREW_LINES   pin it — scripts, recordings, the tests
#   the tty itself                 one `stty size`, else two `tput`s
#   COLUMNS / LINES                no tty to ask (a pipe, a CI run)
#   100 x 30                       something to draw on
TERM_DIRTY=1
term_size() {
  [ "$TERM_DIRTY" = 1 ] || return 0
  TERM_W=${PITCREW_COLS:-}; TERM_H=${PITCREW_LINES:-}
  if [ -z "$TERM_W" ] || [ -z "$TERM_H" ]; then
    _tty_size
    [ -n "$TERM_W" ] || TERM_W=${TTY_W:-${COLUMNS:-100}}
    [ -n "$TERM_H" ] || TERM_H=${TTY_H:-${LINES:-30}}
  fi
  # A terminal that reports nonsense (0 columns is a real answer from a tty
  # that is being torn down) must not reach the layout, where it becomes a
  # negative width and a frame full of printf errors.
  [ "$TERM_W" -ge 20 ] 2>/dev/null || TERM_W=20
  [ "$TERM_H" -ge 4  ] 2>/dev/null || TERM_H=4
  TERM_DIRTY=0
  return 0
}

# → TTY_W / TTY_H, both empty when there is no terminal to ask. Its own
# function so the layout has ONE place that talks to the outside world — and
# so a test can put a terminal where CI has none.
_tty_size() {
  TTY_W=""; TTY_H=""
  local size
  # `stty size` is one fork for both numbers and it asks the terminal on
  # stdin, which is the fd the dashboard already owns for keys — so it keeps
  # working when stdout is being redirected somewhere else.
  if [ -t 0 ] && size=$(stty size 2>/dev/null); then
    read -r TTY_H TTY_W <<< "$size"
    [ -n "$TTY_W" ] && return 0
  fi
  # Neither may be asked without a terminal to ask: with stdout on a pipe
  # `tput cols` does not fail, it cheerfully answers 80 — a wrong number that
  # would then beat the real one the caller passed in the environment.
  if [ -t 1 ]; then
    TTY_W=$(tput cols 2>/dev/null); TTY_H=$(tput lines 2>/dev/null)
  fi
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

# ── zen ─────────────────────────────────────────────────────────────────────
# The dashboard's default answer to "what is happening" is everything: six
# apps, two gauges, a dep rule, a legend, a graph per component. That is the
# right answer when you are looking AT it, and the wrong one when it is sitting
# on a second monitor while you write code — there, twelve healthy rows are
# twelve rows of nothing, and the one that broke has to compete with them.
#
# Zen keeps the verdict and shows only what is not fine. Everything that is
# context rather than content goes: gauges, deps that are up, the legend, the
# graph column, and every healthy component.
#
# It is also the focus mode, and deliberately the same switch. A component you
# MARK stays visible in zen even when it is healthy — that is "I am working on
# this one", which is the other half of the same question. Same for an active
# filter. So `space` on the app you are working on plus `z` gives you exactly
# that app and anything that breaks, and nothing else.
ZEN=${PITCREW_ZEN:-0}
case "$ZEN" in 1|true|yes|on) ZEN=1 ;; *) ZEN=0 ;; esac

# Does this app earn a row in zen? Anything not plainly up, anything you marked,
# and anything an active filter narrowed to.
_zen_keeps() { # $1 app
  local app=$1 c
  [ -n "$FILTER" ] && return 0                 # you already said what you wanted
  for c in "be-$app" "fe-$app"; do
    [ -n "${MARKED[$c]:-}" ] && return 0
    case "${SNAP_STATE[$c]:-}" in
      ''|n/a|up) ;;
      *) return 0 ;;
    esac
  done
  return 1
}
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
    [ "$ZEN" = 1 ] && ! _zen_keeps "$app" && continue
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
    # shellcheck disable=SC2206  # SNAP_PIDS IS a space-separated pid list
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

# The one-shot table. It scrolls in your terminal rather than owning the
# screen, so auto-wrap is ON here and an over-long row wraps instead of being
# eaten — but a wrapped row is still a mangled row, and the legend was 96
# columns wide on an 80-column terminal. Same rule as the dashboard: fit it.
STATUS_ROW_W=78          # the two-column row, measured
status_table() {
  snapshot
  err_scan
  local dep st app bs fs bx fx line W twocol=1
  term_size; W=$TERM_W
  [ "$W" -lt "$STATUS_ROW_W" ] && twocol=0
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
  # These are hand-aligned to the columns printf builds below, so they have to
  # widen with mem_meter when the cap is spelled out.
  local _ram_hdr="ram" _ram_pad=34
  if [ "${PITCREW_RAM_CELL:-value}" = cap ]; then _ram_hdr="ram / cap"; _ram_pad=39; fi
  if [ "$twocol" = 1 ]; then
    printf '  %b%-12s %-*s %s%b\n' "$BOLD" "app" "$_ram_pad" \
      "backend              $_ram_hdr" "frontend             $_ram_hdr" "$RESET"
  else
    printf '  %b%-12s %s%b\n' "$BOLD" "app" "role  state       port      $_ram_hdr" "$RESET"
  fi
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
    if [ "$twocol" = 1 ]; then
      printf '    %b%-12s%b %b %-8s %b:%-5s%b %b%b%b   %b %-8s %b:%-5s%b %b%b%b\n' \
        "$CYAN" "$app" "$RESET" \
        "$line" "$bs" "$GREY" "${PITCREW_BE_PORT[$app]:--}" "$RESET" "$bmem" "$berr" "$bx" \
        "$ficon" "$fs" "$GREY" "${PITCREW_FE_PORT[$app]:--}" "$RESET" "$fmem" "$ferr" "$fx"
      continue
    fi
    # one role per line: two squeezed columns wrap into an unreadable mess
    printf '    %b%-12s%b %bbe%b %b %-8s %b:%-5s%b %b%b%b\n' \
      "$CYAN" "$app" "$RESET" "$C_MUTED" "$RESET" \
      "$line" "$bs" "$GREY" "${PITCREW_BE_PORT[$app]:--}" "$RESET" "$bmem" "$berr" "$bx"
    printf '    %b%-12s%b %bfe%b %b %-8s %b:%-5s%b %b%b%b\n' \
      "$CYAN" "" "$RESET" "$C_MUTED" "$RESET" \
      "$ficon" "$fs" "$GREY" "${PITCREW_FE_PORT[$app]:--}" "$RESET" "$fmem" "$ferr" "$fx"
  done
  say ""
  # drop the entries that will not fit rather than wrapping the line
  local leg="  " lg vis=2
  for lg in "● up" "◐ starting" "✗ crashed" "○ down" "· n/a" "⚡ errors in log" \
            "ext = something else on that port"; do
    [ $(( vis + ${#lg} + 2 )) -gt "$W" ] && break
    leg+="$lg  "; vis=$(( vis + ${#lg} + 2 ))
  done
  say "${GREY}${leg}${RESET}"
}

cmd_status() {
  banner
  status_table
  # status_table has already taken the snapshot and scanned the logs, so the
  # verdict costs nothing more than the checks themselves. One line, at the
  # bottom, where the eye lands after reading the table.
  diag_run
  diag_verdict_line
  say ""
  say "  $R"
  [ "$DIAG_N" -gt 0 ] && say "  ${C_FAINT}${DIAG_N} finding$([ "$DIAG_N" = 1 ] || printf 's') · ${RESET}${C_MUTED}pitcrew diagnose${RESET}"
  echo
}

# The rail colour is the worst state across an app's roles: it is a
# peripheral-vision signal, so it must report the thing that needs attention,
