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

PITCREW_GRAPH="${PITCREW_GRAPH:-block}"           # block | braille
PITCREW_HISTORY="${PITCREW_HISTORY:-240}"         # samples kept per component
PITCREW_ERROR_PATTERN="${PITCREW_ERROR_PATTERN:-ERROR|FATAL|Exception|UnhandledRejection}"
PITCREW_ERROR_SCAN_MAX="${PITCREW_ERROR_SCAN_MAX:-2000}"   # lines/frame/component ceiling

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
  a=(${HIST_MEM[$c]:-} "${m:-0}")
  [ ${#a[@]} -gt "$PITCREW_HISTORY" ] && a=("${a[@]: -$PITCREW_HISTORY}")
  HIST_MEM[$c]="${a[*]}"
  a=(${HIST_CPU[$c]:-} "${p:-0}")
  [ ${#a[@]} -gt "$PITCREW_HISTORY" ] && a=("${a[@]: -$PITCREW_HISTORY}")
  HIST_CPU[$c]="${a[*]}"
  return 0
}

HIST_SYS_CPU=""
HIST_SYS_MEM=""
hist_push_sys() { # $1 cpu pct, $2 mem used kB
  local -a a
  a=(${HIST_SYS_CPU} "${1:-0}")
  [ ${#a[@]} -gt "$PITCREW_HISTORY" ] && a=("${a[@]: -$PITCREW_HISTORY}")
  HIST_SYS_CPU="${a[*]}"
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

spark() { # $1 history, $2 width in cells, $3 scale floor → R
  #
  # Auto-scaling: the graph is scaled to the maximum of exactly the window it
  # draws, not to the component's configured RAM cap. Scaling to the cap is
  # what made every graph a flat line — a backend using 1.0G of an 8G cap sits
  # at 12%, so every sample lands on level 1 and renders as "▁▁▁▁…".
  #
  # The floor keeps an idle service from being amplified into noise, and it
  # doubles as a fixed scale: pass a floor the data never exceeds (100 for a
  # percentage, total RAM for the system gauge) and the graph is absolute.
  #
  # Colour comes from each cell's own HEIGHT, not from the series' current
  # value — the ramp runs cool at the bottom to hot at the top, so a climb is
  # legible before you read a single number. The newest sample is emboldened so
  # "now" is distinct from history, and the run-in before the data starts is a
  # faint baseline rather than blank space, which makes the column read as a
  # chart area instead of a gap.
  local hist=$1 w=$2 mx=${3:-1}
  local -a s=($hist)
  local n=${#s[@]} need start i a b l r v from lvl
  if [ "$PITCREW_GRAPH" = braille ]; then need=$((w * 2)); else need=$w; fi
  start=$(( n - need ))
  from=$start; [ $from -lt 0 ] && from=0
  for ((i = from; i < n; i++)); do v=${s[i]}; [ "$v" -gt "$mx" ] && mx=$v; done

  R=""
  if [ "$PITCREW_GRAPH" = braille ]; then
    _braille_init
    for ((i = 0; i < need; i += 2)); do
      a=$(( start + i )); b=$(( a + 1 ))
      # a negative index would silently mean "from the end" in bash — guard it
      if [ $a -ge 0 ]; then _level "${s[a]}" "$mx" 4; l=$LVL; else l=0; fi
      if [ $b -ge 0 ]; then _level "${s[b]}" "$mx" 4; r=$LVL; else r=0; fi
      if [ $b -lt 0 ]; then R+="${C_FAINT}▁"; continue; fi
      lvl=$l; [ $r -gt $lvl ] && lvl=$r
      R+="${GRAMP[$(( lvl * 4 / 5 ))]}"
      [ $(( i + 2 )) -ge "$need" ] && R+="$BOLD"
      R+="${BRAILLE[$(( _BRAILLE_LMASK[l] + _BRAILLE_RMASK[r] ))]}"
    done
  else
    for ((i = 0; i < w; i++)); do
      a=$(( start + i ))
      if [ $a -ge 0 ]; then
        _level "${s[a]}" "$mx" 7
        R+="${GRAMP[$(( LVL / 2 ))]}"
        [ $(( i + 1 )) -eq "$w" ] && R+="$BOLD"
        R+="${BARS[$LVL]}"
      else
        R+="${C_FAINT}▁"
      fi
    done
  fi
  R+="$RESET"
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
