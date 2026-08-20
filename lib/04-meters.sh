#!/usr/bin/env bash
# lib/04-meters.sh — turning the snapshot's raw numbers into the things you
# actually look at: RAM/CPU bars, history sparklines, and the log error radar.
#
# ── calling convention, and why it looks like this ──────────────────────────
# Nothing in the render path may be called as `$(helper ...)`. A command
# substitution forks a subshell, and these helpers run a dozen-plus times per
# component per frame — that alone was a big share of the 431 forks a single
# frame used to cost. So:
#
#   * calculators set one named global   (_level → LVL, human → HUMAN, ...)
#   * renderers set the shared global R  (bar, spark, state_icon, comp_cell)
#
# R is overwritten by every renderer, so a caller must consume it immediately.
# Nothing may ever declare `local R` — that would shadow the global and the
# caller would silently read a stale frame.

# ── render settings ─────────────────────────────────────────────────────────
# How the numbers are DRAWN, as opposed to what they are. Same resolution
# order as the theme, and for the same reason — a one-off run overrides a
# project, a project overrides how you like your terminal:
#
#   the environment  →  the project config  →  the saved preference  →  default
#
#   graph   block | braille | bar   a service's RAM over time
#   scale   range | cap             what the height of that graph MEANS
#   gauge   bar   | graph           the CPU/RAM gauges at the top of the frame
#   ram     value | cap             whether the RAM figure names the cap it is measured against
PITCREW_GRAPH_ENV="${PITCREW_GRAPH:-}"
PITCREW_GRAPH_SCALE_ENV="${PITCREW_GRAPH_SCALE:-}"
PITCREW_GAUGE_ENV="${PITCREW_GAUGE:-}"
PITCREW_RAM_CELL_ENV="${PITCREW_RAM_CELL:-}"
PITCREW_RENDER_FILE="${PITCREW_RENDER_FILE:-$HOME/.config/pitcrew/render}"

RENDER_KEYS=(graph scale gauge ram)
render_values() { # $1 key → the values it accepts
  case "$1" in
    graph) R="block braille bar" ;;
    scale) R="range cap" ;;
    gauge) R="bar graph" ;;
    ram)   R="value cap" ;;
    *)     R="" ;;
  esac
}

render_get() { # $1 key → R, the value in effect
  case "$1" in
    graph) R=$PITCREW_GRAPH ;;
    scale) R=$PITCREW_GRAPH_SCALE ;;
    gauge) R=$PITCREW_GAUGE ;;
    ram)   R=$PITCREW_RAM_CELL ;;
    *)     R="" ;;
  esac
}

_render_valid() { # $1 key, $2 value
  local v; render_values "$1"
  case " $R " in *" $2 "*) return 0 ;; esac
  return 1
}

# A preference file is written only by us, so a value that is not in the list
# means the file was hand-edited or comes from a newer version. Fall back to
# the default rather than drawing with a setting nothing understands.
render_resolve() {
  local key val saved_graph="" saved_scale="" saved_gauge="" saved_ram=""
  if [ -r "$PITCREW_RENDER_FILE" ]; then
    while IFS='=' read -r key val; do
      case "$key" in
        graph) saved_graph=$val ;;
        scale) saved_scale=$val ;;
        gauge) saved_gauge=$val ;;
        ram)   saved_ram=$val ;;
      esac
    done < "$PITCREW_RENDER_FILE"
  fi
  [ -n "$PITCREW_GRAPH_ENV" ]       && PITCREW_GRAPH=$PITCREW_GRAPH_ENV
  [ -n "$PITCREW_GRAPH_SCALE_ENV" ] && PITCREW_GRAPH_SCALE=$PITCREW_GRAPH_SCALE_ENV
  [ -n "$PITCREW_GAUGE_ENV" ]       && PITCREW_GAUGE=$PITCREW_GAUGE_ENV
  [ -n "$PITCREW_RAM_CELL_ENV" ]    && PITCREW_RAM_CELL=$PITCREW_RAM_CELL_ENV
  [ -z "${PITCREW_GRAPH:-}" ]       && PITCREW_GRAPH=$saved_graph
  [ -z "${PITCREW_GRAPH_SCALE:-}" ] && PITCREW_GRAPH_SCALE=$saved_scale
  [ -z "${PITCREW_GAUGE:-}" ]       && PITCREW_GAUGE=$saved_gauge
  [ -z "${PITCREW_RAM_CELL:-}" ]    && PITCREW_RAM_CELL=$saved_ram
  _render_valid graph "${PITCREW_GRAPH:-}"       || PITCREW_GRAPH=block
  _render_valid scale "${PITCREW_GRAPH_SCALE:-}" || PITCREW_GRAPH_SCALE=range
  _render_valid gauge "${PITCREW_GAUGE:-}"       || PITCREW_GAUGE=bar
  _render_valid ram   "${PITCREW_RAM_CELL:-}"    || PITCREW_RAM_CELL=value
  return 0
}

render_save() { # $1 key, $2 value — rewrite the file with this key replaced
  _render_valid "$1" "$2" || return 1
  local k v out="" line
  mkdir -p "$(dirname "$PITCREW_RENDER_FILE")" 2>/dev/null
  for k in "${RENDER_KEYS[@]}"; do
    if [ "$k" = "$1" ]; then v=$2; else render_get "$k"; v=$R; fi
    out+="$k=$v"$'\n'
  done
  printf '%s' "$out" > "$PITCREW_RENDER_FILE"
  return 0
}

render_resolve
PITCREW_HISTORY="${PITCREW_HISTORY:-240}"         # samples kept per component
PITCREW_ERROR_PATTERN="${PITCREW_ERROR_PATTERN:-ERROR|FATAL|Exception|UnhandledRejection}"
PITCREW_ERROR_SCAN_MAX="${PITCREW_ERROR_SCAN_MAX:-2000}"   # lines/frame/component ceiling

# ── choosing a render style ─────────────────────────────────────────────────
# The same shape as `pitcrew theme`: a swatch you can see before you commit to
# it, and a choice that is remembered. The dashboard is something you look at
# for hours — how it draws is a preference, not a constant.

RENDER_SAMPLE_STEADY=""     # a service holding its RAM steady
RENDER_SAMPLE_LEAK=""       # one climbing
_render_samples() {
  [ -n "$RENDER_SAMPLE_STEADY" ] && return 0
  local i
  for ((i = 0; i < 48; i++)); do
    RENDER_SAMPLE_STEADY+="$(( 1060003840 + i % 3 * 400000 )) "
    RENDER_SAMPLE_LEAK+="$(( 600000000 + i * 12000000 )) "
  done
  return 0
}

# The samples are ~1G against a 2G cap, which is what the two scales actually
# differ about — drawn against the 64M floor instead, BOTH of them saturate and
# the swatch would sell you a choice it is not making.
_render_spark() { # $1 history, $2 width, $3 scale → R
  if [ "$3" = range ]; then spark "$1" "$2" 67108864 "$C_OK" range
  else                      spark "$1" "$2" 2147483648 "" abs
  fi
}

render_swatch() { # $1 "key=value" → one line showing what that setting draws
  local key=${1%%=*} val=${1#*=} cur mark sample=""
  local saved_g=$PITCREW_GRAPH saved_s=$PITCREW_GRAPH_SCALE
  _render_samples
  render_get "$key"; cur=$R
  mark="${C_FAINT}○${RESET}"
  [ "$val" = "$cur" ] && mark="${C_OK}●${RESET}"
  case "$key" in
    graph)
      PITCREW_GRAPH=$val
      if [ "$val" = bar ]; then bar 62 22
      else _render_spark "$RENDER_SAMPLE_LEAK" 22 "$PITCREW_GRAPH_SCALE"; fi
      sample=$R; PITCREW_GRAPH=$saved_g ;;
    scale)
      _render_spark "$RENDER_SAMPLE_STEADY" 10 "$val"; sample="$R  "
      _render_spark "$RENDER_SAMPLE_LEAK" 10 "$val"; sample+=$R ;;
    gauge)
      if [ "$val" = bar ]; then bar 34 22; else spark "$RENDER_SAMPLE_LEAK" 22 100 "" abs; fi
      sample=$R ;;
    ram)
      # The same service at 62% of an 8G cap, drawn both ways.
      pct_color 62
      if [ "$val" = cap ]; then
        printf -v sample '%b5.0%b%bG%b%b/8G%b' "$PCOL" "$RESET" "$C_MUTED" "$RESET" "$C_FAINT" "$RESET"
      else
        printf -v sample '%b5.0%b%bG%b   ' "$PCOL" "$RESET" "$C_MUTED" "$RESET"
      fi ;;
    *) printf '  %bno such setting: %s%b\n' "$C_CRIT" "$key" "$RESET"; return 0 ;;
  esac
  printf '  %b %b%-8s%b %s  %b%s%b\n' "$mark" "$C_TEXT" "$val" "$RESET" "$sample" \
    "$C_FAINT" "$(render_describe "$key" "$val")" "$RESET"
  return 0
}

# Each line is "key=value<TAB>label", the same contract the action menu uses:
# fzf shows the label and hands back the whole line, so the choice is made on
# something unambiguous rather than on what it happens to look like.
render_choices() {
  local key val cur mark
  for key in "${RENDER_KEYS[@]}"; do
    render_get "$key"; cur=$R
    render_values "$key"
    for val in $R; do
      mark="${C_FAINT}○${RESET}"
      [ "$val" = "$cur" ] && mark="${C_OK}●${RESET}"
      printf '%s=%s\t%b  %b%-6s%b %b%-8s%b %b%s%b\n' "$key" "$val" \
        "$mark" "$C_MUTED" "$key" "$RESET" "$C_TEXT" "$val" "$RESET" \
        "$C_FAINT" "$(render_describe "$key" "$val")" "$RESET"
    done
  done
}

render_purpose() { # $1 key → what the setting is FOR
  case "$1" in
    graph) echo "a service's RAM over time" ;;
    scale) echo "what the height of that graph means" ;;
    gauge) echo "the CPU and RAM gauges at the top of the frame" ;;
    ram)   echo "whether a service's RAM figure names the cap it is measured against" ;;
  esac
}

render_describe() { # $1 key, $2 value → the one line that says why you would pick it
  case "$1=$2" in
    graph=block)   echo "one cell per sample" ;;
    graph=braille) echo "two samples per cell — twice the history in the same width" ;;
    graph=bar)     echo "no history: how full the RAM cap is, right now" ;;
    scale=range)   echo "height is movement — a steady service stays a flat line" ;;
    scale=cap)     echo "height is the RAM cap — absolute, and flat for anything well under it" ;;
    gauge=bar)     echo "a loading bar: the filled part is the number" ;;
    gauge=graph)   echo "the last few minutes of system load, as history" ;;
    ram=value)     echo "just the figure — the colour already says how close to the cap it is" ;;
    ram=cap)       echo "the figure and its cap: 1.2G/8G, so the headroom is a number not a hue" ;;
    *)             echo "" ;;
  esac
}

# `pitcrew render` — like `pitcrew theme`, it runs before any project config is
# resolved, so it works from anywhere.
cmd_render() {
  local key val
  case "${1:-list}" in
    list|"")
      # every option drawn, not just the one in effect — the point of a swatch
      # is choosing between them without having to try each one first
      local vals
      say ""
      for key in "${RENDER_KEYS[@]}"; do
        render_values "$key"; vals=$R
        say "  ${BOLD}${key}${RESET}   ${C_MUTED}$(render_purpose "$key")${RESET}"
        for val in $vals; do render_swatch "$key=$val"; done
        say ""
      done
      say "  ${C_MUTED}pitcrew render <setting> <value>   ·   saved to $PITCREW_RENDER_FILE${RESET}"
      say "" ;;
    --swatch)
      [ -n "${2:-}" ] || die "usage: pitcrew render --swatch <setting>=<value>"
      render_swatch "$2" ;;
    --reset)
      rm -f "$PITCREW_RENDER_FILE"
      PITCREW_GRAPH=""; PITCREW_GRAPH_SCALE=""; PITCREW_GAUGE=""
      render_resolve
      ok "render preferences cleared — back to the defaults" ;;
    *)
      key=${1%%=*}; val=${1#*=}
      [ "$val" = "$1" ] && val=${2:-}          # "render graph bar" as well as "render graph=bar"
      render_values "$key"
      [ -n "$R" ] || die "no render setting '$key' — try: ${RENDER_KEYS[*]}"
      [ -n "$val" ] || die "usage: pitcrew render $key <${R// /|}>"
      _render_valid "$key" "$val" || die "'$val' is not a $key style — try: ${R// /, }"
      render_save "$key" "$val"
      render_set "$key" "$val"
      ok "$key set to ${BOLD}$val${RESET}"
      render_swatch "$key=$val" ;;
  esac
}

render_set() { # $1 key, $2 value — apply it to the running process
  case "$1" in
    graph) PITCREW_GRAPH=$2 ;;
    scale) PITCREW_GRAPH_SCALE=$2 ;;
    gauge) PITCREW_GAUGE=$2 ;;
    ram)   PITCREW_RAM_CELL=$2 ;;
  esac
  return 0
}

declare -gA HIST_MEM=() HIST_CPU=()
declare -gA ERR_COUNT=() ERR_LINES=() ERR_FD=() ERR_PID=() ERR_PARTIAL=()
declare -ga BRAILLE=()
R=""

to_bytes() { # cold path only (config parsing) — safe to use in $( )
  local n=${1%[GgMm]}
  case "$1" in *G|*g) echo $((n * 1024 ** 3)) ;; *M|*m) echo $((n * 1024 ** 2)) ;; *) echo "$1" ;; esac
}

human() { # bytes → HUMAN as "1.5G" / "820M" (integer math; this used to fork awk)
  local b=${1:-0}
  if [ "$b" -ge 1073741824 ]; then
    printf -v HUMAN '%d.%dG' $((b / 1073741824)) $(( (b % 1073741824) * 10 / 1073741824 ))
  else
    printf -v HUMAN '%dM' $((b / 1048576))
  fi
}

pct_color() { # $1 pct → PCOL
  if   [ "${1:-0}" -ge 85 ]; then PCOL=$RED
  elif [ "${1:-0}" -ge 60 ]; then PCOL=$YELLOW
  else                            PCOL=$GREEN
  fi
}

_level() { # $1 value, $2 max, $3 steps → LVL in 0..steps
  local v=${1:-0} max=${2:-0} steps=$3
  if [ "$max" -le 0 ]; then LVL=0; return; fi
  LVL=$(( v * steps / max ))
  [ "$LVL" -gt "$steps" ] && LVL=$steps
  [ "$LVL" -lt 0 ] && LVL=0
  # anything non-zero shows at least one pixel, or a quiet service looks dead
  [ "$LVL" -eq 0 ] && [ "$v" -gt 0 ] && LVL=1
  return 0
}

bar() { # $1 pct, $2 width → R
  local pct=${1:-0} w=$2 filled i
  pct_color "$pct"
  filled=$((pct * w / 100)); [ $filled -gt "$w" ] && filled=$w; [ $filled -lt 0 ] && filled=0
  R="$PCOL"
  for ((i = 0; i < filled; i++)); do R+="█"; done
  R+="$DIM$GREY"
  for ((i = filled; i < w; i++)); do R+="░"; done
  R+="$RESET"
}

# ── history + sparklines ────────────────────────────────────────────────────
# One instantaneous number can't show a memory leak climbing. Each component
# keeps a ring of recent samples, pushed once per frame.
hist_push() { # $1 comp, $2 mem bytes (may be ""), $3 cpu pct (may be "")
  local c=$1 m=${2:-0} p=${3:-0}
  local -a a
  # shellcheck disable=SC2206  # split on spaces: the history IS a space-separated list
  a=(${HIST_MEM[$c]:-} "${m:-0}")
  [ ${#a[@]} -gt "$PITCREW_HISTORY" ] && a=("${a[@]: -$PITCREW_HISTORY}")
  HIST_MEM[$c]="${a[*]}"
  # shellcheck disable=SC2206  # split on spaces: the history IS a space-separated list
  a=(${HIST_CPU[$c]:-} "${p:-0}")
  [ ${#a[@]} -gt "$PITCREW_HISTORY" ] && a=("${a[@]: -$PITCREW_HISTORY}")
  HIST_CPU[$c]="${a[*]}"
  return 0
}

HIST_SYS_CPU=""
HIST_SYS_MEM=""
hist_push_sys() { # $1 cpu pct, $2 mem used kB
  local -a a
  # shellcheck disable=SC2206  # split on spaces: the history IS a space-separated list
  a=(${HIST_SYS_CPU} "${1:-0}")
  [ ${#a[@]} -gt "$PITCREW_HISTORY" ] && a=("${a[@]: -$PITCREW_HISTORY}")
  HIST_SYS_CPU="${a[*]}"
  # shellcheck disable=SC2206  # split on spaces: the history IS a space-separated list
  a=(${HIST_SYS_MEM} "${2:-0}")
  [ ${#a[@]} -gt "$PITCREW_HISTORY" ] && a=("${a[@]: -$PITCREW_HISTORY}")
  HIST_SYS_MEM="${a[*]}"
  return 0
}

# 2 samples per cell × 4 vertical levels — the same trick btop uses to get
# more resolution out of one character cell. Table built once, on demand.
_BRAILLE_LMASK=(0 64 68 70 71)
_BRAILLE_RMASK=(0 128 160 176 184)
_braille_init() {
  [ ${#BRAILLE[@]} -eq 256 ] && return 0
  local i e
  for ((i = 0; i < 256; i++)); do
    printf -v e '\\u%04x' $((0x2800 + i))
    printf -v "BRAILLE[$i]" '%b' "$e"
  done
  return 0
}

# → LVL in 0..$4, from where $1 sits inside the window's own [min, max].
#
# This is what stops a busy service from drawing a solid block. Scaled from
# ZERO, a backend holding steady at 1.0G puts every sample at the window
# maximum, every cell renders full height in the hottest colour, and the graph
# becomes a red lump that says nothing except "this service exists". Scaled
# from the window MINIMUM, the same service draws a calm flat line and only
# actual movement lifts off it — which is the entire reason to keep history.
_level_range() { # $1 value, $2 window min, $3 span, $4 steps → LVL
  local v=$1 mn=$2 span=$3 steps=$4
  if [ "$v" -le 0 ]; then LVL=0; return 0; fi        # nothing was running then
  if [ "$span" -le 0 ]; then LVL=1; return 0; fi     # perfectly flat: one pixel
  LVL=$(( (v - mn) * steps / span ))
  [ "$LVL" -gt "$steps" ] && LVL=$steps
  # a running service is never invisible: the bottom of its own range is still
  # a line, not a gap
  [ "$LVL" -lt 1 ] && LVL=1
  return 0
}

spark() { # $1 history, $2 width in cells, $3 scale floor, $4 colour, $5 scale mode → R
  #
  # Two scales, and which one you want depends on the question.
  #
  #   range (default)  height is where the sample sits in the window's own
  #                    recent [min, max]. Answers "is this MOVING?" — a leak
  #                    climbs off the baseline while a steady service stays a
  #                    flat line instead of saturating into a solid block.
  #   abs              height is the sample against a fixed maximum: the floor
  #                    passed in, or the window peak if the data exceeds it.
  #                    Answers "how big is this, absolutely?"
  #
  # Colour: with a fixed colour in $4 the whole graph takes it — that is how a
  # RAM graph carries "how close to the cap am I", which cell height cannot
  # say once height means "relative to its own recent range". With no colour
  # the ramp runs cool at the bottom to hot at the top, which is what the
  # absolute scale wants.
  #
  # The newest sample is emboldened so "now" is distinct from history, and the
  # run-in before the data starts is a faint baseline rather than blank space,
  # which makes the column read as a chart area instead of a gap.
  local hist=$1 w=$2 mx=${3:-1} fixed=${4:-} mode=${5:-abs}
  # shellcheck disable=SC2206  # split on spaces: the history IS a space-separated list
  local -a s=($hist)
  local n=${#s[@]} need start i a b l r v from lvl mn=0 span=0
  if [ "$PITCREW_GRAPH" = braille ]; then need=$((w * 2)); else need=$w; fi
  start=$(( n - need ))
  from=$start; [ $from -lt 0 ] && from=0
  if [ "$mode" = range ]; then
    # min and max of exactly the window being drawn, ignoring the samples
    # taken while the service was not running
    mn=-1; mx=0
    for ((i = from; i < n; i++)); do
      v=${s[i]}; [ "${v:-0}" -le 0 ] && continue
      [ "$v" -gt "$mx" ] && mx=$v
      { [ "$mn" -lt 0 ] || [ "$v" -lt "$mn" ]; } && mn=$v
    done
    [ "$mn" -lt 0 ] && mn=0
    span=$(( mx - mn ))
    # A floor under the span, or the graph amplifies sampling noise into a
    # mountain range: an eighth of the peak, and never less than an eighth of
    # the caller's floor, so a 2M helper process is not drawn as a crisis.
    local minspan=$(( mx / 8 )) floorspan=$(( ${3:-0} / 8 ))
    [ "$floorspan" -gt "$minspan" ] && minspan=$floorspan
    [ "$span" -lt "$minspan" ] && span=$minspan
  else
    for ((i = from; i < n; i++)); do v=${s[i]}; [ "$v" -gt "$mx" ] && mx=$v; done
  fi

  R=""
  if [ "$PITCREW_GRAPH" = braille ]; then
    _braille_init
    for ((i = 0; i < need; i += 2)); do
      a=$(( start + i )); b=$(( a + 1 ))
      # a negative index would silently mean "from the end" in bash — guard it
      if [ $a -ge 0 ]; then _spark_level "${s[a]}" "$mx" "$mn" "$span" "$mode" 4; l=$LVL; else l=0; fi
      if [ $b -ge 0 ]; then _spark_level "${s[b]}" "$mx" "$mn" "$span" "$mode" 4; r=$LVL; else r=0; fi
      if [ $b -lt 0 ]; then R+="${C_FAINT}▁"; continue; fi
      lvl=$l; [ $r -gt $lvl ] && lvl=$r
      if [ -n "$fixed" ]; then R+="$fixed"; else R+="${GRAMP[$(( lvl * 4 / 5 ))]}"; fi
      [ $(( i + 2 )) -ge "$need" ] && R+="$BOLD"
      R+="${BRAILLE[$(( _BRAILLE_LMASK[l] + _BRAILLE_RMASK[r] ))]}"
    done
  else
    for ((i = 0; i < w; i++)); do
      a=$(( start + i ))
      if [ $a -ge 0 ]; then
        _spark_level "${s[a]}" "$mx" "$mn" "$span" "$mode" 7
        if [ -n "$fixed" ]; then R+="$fixed"; else R+="${GRAMP[$(( LVL / 2 ))]}"; fi
        [ $(( i + 1 )) -eq "$w" ] && R+="$BOLD"
        R+="${BARS[$LVL]}"
      else
        R+="${C_FAINT}▁"
      fi
    done
  fi
  R+="$RESET"
}

_spark_level() { # $1 value, $2 max, $3 min, $4 span, $5 mode, $6 steps → LVL
  if [ "$5" = range ]; then _level_range "${1:-0}" "$3" "$4" "$6"
  else                      _level "${1:-0}" "$2" "$6"
  fi
}

mem_meter() { # $1 comp → R: one aligned "bar RAM" cell, or a dim "—" if not running
  local c=$1 cur=${SNAP_RSS[$1]:-} max pct
  if ! [[ "$cur" =~ ^[0-9]+$ ]] || [ "$cur" -le 0 ]; then
    R="${GREY}      —${RESET}"; return
  fi
  max=${COMP_MAX_B[$c]:-1}
  _level "$cur" "$max" 7
  pct=$(( cur * 100 / max ))
  pct_color "$pct"
  human "$cur"
  printf -v R '%b%s %5s%b' "$PCOL" "${BARS[$LVL]}" "$HUMAN" "$RESET"
  # `render ram cap` names the cap the colour is already measuring against, so
  # the headroom is a number rather than a hue you have to interpret.
  if [ "${PITCREW_RAM_CELL:-value}" = cap ]; then
    printf -v R '%s%b/%-4s%b' "$R" "$C_FAINT" "${COMP_MAX_LABEL[$c]:-?}" "$RESET"
  fi
}

# ── error radar ─────────────────────────────────────────────────────────────
# Incremental: one long-lived fd per log, reading only what's new. The old
# implementation re-read the last 150 lines of every log every frame through
# two forks, which is exactly what made sub-second refresh impossible.
#
# The only thing that truncates a log is launch_process on (re)start, and that
# always writes a new pid — so a changed pid is the reliable, fork-free signal
# to reopen the file from the beginning.
err_scan() {
  local c f fd pid n line prev last cnt first i
  local mark="$LOG_DIR/.errmark"
  local -a NEW todo=()

  # Nothing has ever been started in this project, so there is no log
  # directory and nothing to scan. Without this the marker write below fails
  # loudly on a clean checkout — `pitcrew status` greets a new user with an
  # error about a file they have never heard of.
  [ -d "$LOG_DIR" ] || return 0

  # Even an empty read costs ~0.5ms per file, so 12 idle logs would burn 7ms a
  # frame doing nothing. `-nt` is a builtin mtime comparison: only logs that
  # were actually written since the last scan get opened at all.
  #
  # The marker is stamped BEFORE the reads (with `: >`, a redirect — no fork),
  # so anything written *during* this scan is newer than it and gets picked up
  # on the next frame instead of being silently skipped.
  for c in "${PITCREW_COMPS[@]}"; do
    f="$LOG_DIR/$c.log"
    [ -r "$f" ] || continue
    # Skip ONLY when the marker is strictly newer than the log, i.e. the log
    # provably has not been touched since the last scan. Testing the other way
    # round ("log is newer than marker") looks equivalent and is not: mtime
    # granularity is coarser than the nanoseconds stat prints, so a log written
    # in the same clock tick as the marker gets an IDENTICAL timestamp, `-nt`
    # is false for a tie, and that log is skipped. A quiet-after-crash service
    # could have its last lines — the interesting ones — missed indefinitely.
    # Ties must favour reading.
    if [ -z "${ERR_FD[$c]:-}" ] || [ "${ERR_PID[$c]-__unset__}" != "${SNAP_PID[$c]:-}" ] \
       || [ ! -e "$mark" ] || ! [ "$mark" -nt "$f" ]; then
      todo+=("$c")
    fi
  done
  : > "$mark" 2>/dev/null
  [ ${#todo[@]} -eq 0 ] && return 0

  for c in "${todo[@]}"; do
    f="$LOG_DIR/$c.log"
    pid=${SNAP_PID[$c]:-}
    if [ "${ERR_PID[$c]-__unset__}" != "$pid" ]; then    # restarted → log was truncated
      [ -n "${ERR_FD[$c]:-}" ] && eval "exec ${ERR_FD[$c]}<&-" 2>/dev/null
      unset "ERR_FD[$c]"
      ERR_PID[$c]=$pid
      ERR_COUNT[$c]=0
      ERR_LINES[$c]=""
      ERR_PARTIAL[$c]=""
    fi
    first=0
    if [ -z "${ERR_FD[$c]:-}" ]; then
      # NO trailing `2>/dev/null` here. `exec` with no command applies EVERY
      # redirection to the shell itself and keeps them — so that innocuous
      # looking suppressor permanently sent this process's stderr to /dev/null,
      # hiding every subsequent error message from every part of the tool.
      # The `-r` test in the todo loop above is the guard instead.
      [ -r "$f" ] || continue
      exec {fd}<"$f"
      ERR_FD[$c]=$fd
      first=1
    fi
    fd=${ERR_FD[$c]}

    prev=${ERR_PARTIAL[$c]:-}; ERR_PARTIAL[$c]=""
    NEW=()
    if [ $first -eq 1 ]; then
      # First open: drain everything already in the file in one bulk read, but
      # only seed the count from its tail. That leaves the fd at EOF for the
      # incremental reads below, and matches the old behaviour, which only ever
      # looked at the last 150 lines.
      mapfile NEW <&"$fd"
      [ ${#NEW[@]} -gt 200 ] && NEW=("${NEW[@]: -200}")
    else
      mapfile -n "$PITCREW_ERROR_SCAN_MAX" NEW <&"$fd"
    fi
    cnt=${#NEW[@]}
    [ $cnt -eq 0 ] && { ERR_PARTIAL[$c]=$prev; continue; }

    # mapfile WITHOUT -t keeps the trailing newline, so an element that lacks
    # one is a line the writer hasn't finished yet. Hold it back and prepend it
    # next frame rather than counting half a line as a whole one.
    last=${NEW[cnt-1]}
    if [ "${last: -1}" != $'\n' ]; then
      unset "NEW[$((cnt - 1))]"
      if [ $cnt -eq 1 ]; then ERR_PARTIAL[$c]="$prev$last"; continue; fi
      ERR_PARTIAL[$c]=$last
    fi

    n=${ERR_COUNT[$c]:-0}
    i=0
    for line in "${NEW[@]}"; do
      line=${line%$'\n'}
      if [ $i -eq 0 ]; then line="$prev$line"; i=1; fi
      if [[ $line =~ $PITCREW_ERROR_PATTERN ]]; then
        n=$((n + 1))
        ERR_LINES[$c]+="${line}"$'\n'
      fi
    done
    [ ${#ERR_LINES[$c]} -gt 8000 ] && ERR_LINES[$c]=${ERR_LINES[$c]: -8000}
    ERR_COUNT[$c]=$n
  done
  return 0
}

err_close() { # release the log fds (on leaving a dashboard)
  local c
  for c in "${!ERR_FD[@]}"; do
    eval "exec ${ERR_FD[$c]}<&-" 2>/dev/null
    unset "ERR_FD[$c]"
  done
  return 0
}
