#!/usr/bin/env bash
# lib/03a-snapshot.sh — one cheap pass per frame that answers every question
# the dashboard asks: which ports are listening, what each component's process
# tree costs in RAM/CPU, and what state each component is in.
#
# Why this file exists: every displayed value used to come from its own `$( )`
# — port checks forked `timeout bash -c /dev/tcp` per component, RAM/CPU
# forked a `pgrep` per process-tree node plus a `ps`, and comp_state was
# recomputed two or three times per component per frame. One frame of the
# 6-app autoland config cost 431 forks / 337ms, which is why the refresh rate
# was pinned at 2s.
#
# On Linux everything here is read straight out of /proc with the `read`
# builtin: zero forks. macOS has no /proc, so it uses ONE `ps` and ONE port
# listing per frame (~2 forks) instead of ~430 — the same arrays, the same
# meaning, the same per-interval CPU deltas.
#
# Contract: snapshot() fills the SNAP_* globals below. comp_state() and the
# meters are then pure array lookups. Anything that loops over components must
# call snapshot() first — it is deliberately NOT called implicitly, so it's
# always obvious where a frame's data comes from.

# Resolved once per process, not per frame.
PITCREW_PAGESIZE=$(getconf PAGESIZE 2>/dev/null || echo 4096)
PITCREW_CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
PITCREW_HEALTH_INTERVAL="${PITCREW_HEALTH_INTERVAL:-5}"
PITCREW_DEP_INTERVAL="${PITCREW_DEP_INTERVAL:-10}"

declare -gA SNAP_PORT_OPEN=()          # port          -> 1 if listening on loopback
declare -gA SNAP_STATE=()              # comp          -> up|starting|crashed|down
declare -gA SNAP_PID=()                # comp          -> pid from its pidfile ("" if none)
declare -gA SNAP_RSS=()                # comp          -> bytes, whole process tree
declare -gA SNAP_CPU=()                # comp          -> integer %, per-core-summed
declare -gA SNAP_PIDS=()               # comp          -> "pid pid pid" (tree, root first)
declare -gA SNAP_PROC_RSS=()           # pid           -> bytes
declare -gA SNAP_PROC_CPU=()           # pid           -> integer %
declare -gA SNAP_PROC_CMD=()           # pid           -> comm
declare -gA SNAP_HEALTH=()             # app           -> UP|DOWN
declare -gA SNAP_HEALTH_AT=()          # app           -> epoch secs of last probe
declare -gA SNAP_DEP=()                # dep container -> up|down
declare -gA SNAP_EXIT=()               # comp -> exit status of the last run
declare -gA SNAP_EXIT_AT=()            # comp -> epoch seconds it ended
declare -gA _JIFF_PREV=()              # pid           -> CPU-time counter at previous sample
declare -gA _JIFF_TREE_PREV=()         # comp          -> summed tree CPU time, previous sample
declare -gA _JIFF_TREE_NOW=()          # comp          -> summed tree CPU time, this sample
# The counter's UNIT depends on the collector — jiffies from /proc, centiseconds
# from `ps -o time`. Only one collector runs per process, and every use is a
# delta divided by a wall-clock figure in the same unit, so they never mix.
_ALL_CS_PREV=0                         # every process's CPU time, previous sample (ps collector)
declare -gA _PS_KIDS=()                # ppid          -> "pid pid" (fallback collector only)
SNAP_AT_US=0
SNAP_NOW_S=0

# ── time, without forking `date` ────────────────────────────────────────────
# $EPOCHREALTIME is a bash-5 builtin ("1755600000.123456"). It honors
# LC_NUMERIC, so a comma decimal separator is a real possibility — normalize.
_now_us() {
  local er=${EPOCHREALTIME/,/.}
  NOW_US=$(( ${er%.*} * 1000000 + 10#${er#*.} ))
  SNAP_NOW_S=${er%.*}
}

# ── pidfiles ────────────────────────────────────────────────────────────────
# A pidfile written before the current boot cannot describe a live process:
# the pid it names either no longer exists or now belongs to something
# unrelated. Reporting that as "crashed" is not just wrong, it is sticky — the
# file survives reboots, so the component stays red forever.
#
# lib/00-platform.sh provides a file whose mtime IS the boot instant (/proc/1
# on Linux, one it stamps from kern.boottime on macOS), so `-nt` answers "was
# this written during the current boot" with a builtin and no fork. Where no
# such marker could be established the pidfile is trusted, which is the
# behaviour that was there before.
_read_pidfile() { # $1 comp → PIDF ("" when absent, empty, or pre-boot)
  local f="$LOG_DIR/$1.pid"
  PIDF=""
  [ -r "$f" ] || return 0
  read -r PIDF < "$f" 2>/dev/null
  [ -n "$PIDF" ] || return 0
  kill -0 "$PIDF" 2>/dev/null && return 0          # alive → certainly ours
  if [ -n "$PITCREW_BOOT_MARKER" ] && [ -e "$PITCREW_BOOT_MARKER" ] \
     && [ ! "$f" -nt "$PITCREW_BOOT_MARKER" ]; then
    PIDF=""                                        # leftover from a previous boot
  fi
  return 0
}

# ── is this local address reachable as 127.0.0.1? ───────────────────────────
# /proc/net/tcp writes each 32-bit word little-endian, so 127.0.0.1 is
# 0100007F. The old check literally opened /dev/tcp/127.0.0.1/<port>, so
# matching only loopback-reachable binds keeps "up" meaning what it meant.
_addr_is_local() {
  case "$1" in
    00000000|0100007F|0100007f)                       return 0 ;;  # 0.0.0.0 / 127.0.0.1
    00000000000000000000000000000000)                 return 0 ;;  # ::
    00000000000000000000000001000000)                 return 0 ;;  # ::1
    *FFFF00000100007F|*ffff00000100007f)              return 0 ;;  # ::ffff:127.0.0.1
    *FFFF000000000000|*ffff000000000000)              return 0 ;;  # ::ffff:0.0.0.0
  esac
  return 1
}

# NOTE: slurp with mapfile, do NOT loop `read` over these files. bash's read
# builtin cannot buffer on /proc (it must not over-consume a shared fd), so it
# falls back to one syscall PER BYTE — a 58-line /proc/net/tcp measured 21.7ms
# through a read loop versus 1.3ms through mapfile. That one difference was
# ~90% of a frame.
_scan_ports_proc() {
  local f l la addr
  local -a lines
  SNAP_PORT_OPEN=()
  for f in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$f" ] || continue
    mapfile -t lines < "$f" 2>/dev/null || continue
    for l in "${lines[@]}"; do
      # "  sl: local_address rem_address st ..." — only LISTEN rows matter, and
      # the cheap glob rejects the header and every established socket first.
      [[ $l == *" 0A "* ]] || continue
      l=${l#*: }                                       # drop the "  N: " index
      la=${l%% *}
      addr=${la%%:*}
      _addr_is_local "$addr" || continue
      SNAP_PORT_OPEN[$((16#${la##*:}))]=1
    done
  done
  return 0
}

# ── process tree walk, fork-free ────────────────────────────────────────────
# /proc/<pid>/task/<tid>/children is a single space-separated line per thread.
# This replaces descendant_pids(), which forked a `pgrep` for every node.
_walk_tree() {
  local pid=$1 f kids k
  _TREE+=("$pid")
  for f in "/proc/$pid/task"/*/children; do
    [ -r "$f" ] || continue
    kids=""
    # NOTE: this file has NO trailing newline, so `read` reports failure even
    # when it successfully filled the variable. Test the content, never the
    # exit status, or every child process is silently dropped.
    read -r kids < "$f" 2>/dev/null
    [ -n "$kids" ] || continue
    for k in $kids; do _walk_tree "$k"; done
  done
}

# Sets _P_RSS (bytes), _P_JIFF (utime+stime), _P_CMD. Returns 1 if the pid is gone.
#
# /proc/<pid>/stat field 2 is the comm, which may itself contain spaces and
# parentheses — so split on the LAST ") ", never on whitespace. After that cut
# the remainder starts at field 3, so utime (14) is index 11 and stime (15) is
# index 12.
#
# RSS comes from statm, not from stat's field 24: statm's resident count is the
# same number `ps -o rss` reports (verified identical to the page), while
# stat's own rss field runs a little low. One extra single-line read per pid is
# worth reporting the same figure the user would get from ps.
_pid_stat() {
  local pid=$1 line rest
  _P_RSS=""; _P_JIFF=""; _P_CMD=""
  read -r line < "/proc/$pid/stat" 2>/dev/null || return 1
  _P_CMD=${line#*(}; _P_CMD=${_P_CMD%)*}
  rest=${line##*') '}
  local -a f=($rest)
  [ ${#f[@]} -ge 13 ] || return 1
  _P_JIFF=$(( ${f[11]} + ${f[12]} ))
  local sz res
  read -r sz res _ < "/proc/$pid/statm" 2>/dev/null
  [ -n "${res:-}" ] || return 0
  _P_RSS=$(( res * PITCREW_PAGESIZE ))
  return 0
}

_snapshot_proc() {
  local prev_us=$SNAP_AT_US
  _now_us; SNAP_AT_US=$NOW_US

  _scan_ports_proc

  # wall-clock jiffies since the previous sample — the denominator for CPU%.
  # Zero on the first frame, which correctly yields 0% rather than a spike.
  local wall_jiff=0
  [ "$prev_us" -gt 0 ] && wall_jiff=$(( (SNAP_AT_US - prev_us) * PITCREW_CLK_TCK / 1000000 ))

  local -A jiff_now=()
  local c app role pid p rss_sum jiff_sum

  SNAP_PROC_RSS=(); SNAP_PROC_CPU=(); SNAP_PROC_CMD=()
  for c in "${PITCREW_COMPS[@]}"; do
    _read_pidfile "$c"; pid=$PIDF
    SNAP_PID[$c]=$pid
    SNAP_RSS[$c]=""; SNAP_CPU[$c]=""; SNAP_PIDS[$c]=""
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue

    _TREE=()
    _walk_tree "$pid"
    SNAP_PIDS[$c]="${_TREE[*]}"

    rss_sum=0; jiff_sum=0
    for p in "${_TREE[@]}"; do
      _pid_stat "$p" || continue
      rss_sum=$(( rss_sum + _P_RSS ))
      jiff_sum=$(( jiff_sum + _P_JIFF ))
      jiff_now[$p]=$_P_JIFF
      SNAP_PROC_RSS[$p]=$_P_RSS
      SNAP_PROC_CMD[$p]=$_P_CMD
      if [ "$wall_jiff" -gt 0 ] && [ -n "${_JIFF_PREV[$p]:-}" ]; then
        SNAP_PROC_CPU[$p]=$(( (_P_JIFF - ${_JIFF_PREV[$p]}) * 100 / wall_jiff ))
      else
        SNAP_PROC_CPU[$p]=0
      fi
    done
    SNAP_RSS[$c]=$rss_sum

    # A real utime+stime delta over the sampling window — where the old
    # `ps -o pcpu` was a lifetime average that barely moves once a JVM has
    # been up for an hour.
    if [ "$wall_jiff" -gt 0 ] && [ -n "${_JIFF_TREE_PREV[$c]:-}" ]; then
      local d=$(( (jiff_sum - ${_JIFF_TREE_PREV[$c]}) * 100 / wall_jiff ))
      [ $d -lt 0 ] && d=0                     # a restarted tree can go backwards
      SNAP_CPU[$c]=$d
    else
      SNAP_CPU[$c]=0
    fi
    _JIFF_TREE_NOW[$c]=$jiff_sum
  done

  # Rebuild rather than update, so pids from stopped components don't
  # accumulate across a long session.
  unset _JIFF_PREV; declare -gA _JIFF_PREV=()
  for p in "${!jiff_now[@]}"; do _JIFF_PREV[$p]=${jiff_now[$p]}; done
  unset _JIFF_TREE_PREV; declare -gA _JIFF_TREE_PREV=()
  for c in "${!_JIFF_TREE_NOW[@]}"; do _JIFF_TREE_PREV[$c]=${_JIFF_TREE_NOW[$c]}; done
  unset _JIFF_TREE_NOW; declare -gA _JIFF_TREE_NOW=()

  sys_gauges
}

# ── portable collector (macOS, BSD, or Linux without a readable /proc) ──────
# Same output arrays, built from ONE ps and ONE port listing per frame. This is
# not a degraded mode: it is what every macOS run uses, so it owes the user the
# same numbers the /proc path gives, not rougher ones.

# Is this listening address reachable as 127.0.0.1? The /proc path only counts
# loopback-reachable binds, and "up" has to mean the same thing on both — a
# service bound to the LAN address alone does not serve http://localhost.
_ps_addr_is_local() { # $1 = lsof/ss local-address field
  case "$1" in
    \*:*|0.0.0.0:*|127.*:*|\[::\]:*|\[::1\]:*|\[::ffff:127.*)  return 0 ;;
  esac
  return 1
}

# POSIX ps reports cumulative CPU time as "[[DD-]HH:]MM:SS[.cc]" — and the
# spelling differs per platform (macOS "0:01.23", Linux "00:00:01"). Parsed to
# centiseconds it becomes the same counter /proc/<pid>/stat gives in jiffies,
# which is what makes a REAL per-interval CPU% possible here. `ps -o pcpu` is
# a lifetime average: a JVM that pegged a core during startup and has been idle
# for an hour still reads high, and a service that starts spinning now barely
# moves the number. That is the wrong answer on the one screen whose whole job
# is telling you what is happening right now.
_cputime_cs() { # $1 time field → _CS (centiseconds)
  local t=$1 d=0 h=0 m=0 s=0 fr=""
  _CS=0
  case "$t" in *-*) d=${t%%-*}; t=${t#*-} ;; esac
  case "$t" in *.*) fr=${t##*.}; t=${t%.*} ;; esac
  case "$t" in
    *:*:*) h=${t%%:*}; t=${t#*:}; m=${t%%:*}; s=${t#*:} ;;
    *:*)   m=${t%%:*}; s=${t#*:} ;;
    *)     s=$t ;;
  esac
  fr="${fr}00"; fr=${fr:0:2}
  # A field we cannot parse must yield 0, not a fatal arithmetic error inside
  # the dashboard's frame loop — an invalid integer constant is not a non-zero
  # return, it terminates the shell.
  #
  # Default each field SEPARATELY before the digit check: concatenating first
  # hides an empty one ("" + "0" is still all digits), and `10#` on its own is
  # the exact token that kills the frame.
  d=${d:-0}; h=${h:-0}; m=${m:-0}; s=${s:-0}
  case "$d$h$m$s$fr" in *[!0-9]*) return 0 ;; esac
  _CS=$(( ((10#$d * 24 + 10#$h) * 3600 + 10#$m * 60 + 10#$s) * 100 + 10#$fr ))
  return 0
}

_snapshot_ps() {
  local prev_us=$SNAP_AT_US
  _now_us; SNAP_AT_US=$NOW_US
  SNAP_PORT_OPEN=()
  SNAP_PROC_RSS=(); SNAP_PROC_CPU=(); SNAP_PROC_CMD=()

  local addr port
  if command -v lsof >/dev/null 2>&1; then
    while read -r addr; do
      _ps_addr_is_local "$addr" || continue
      port=${addr##*:}
      [[ $port =~ ^[0-9]+$ ]] && SNAP_PORT_OPEN[$port]=1
    done < <(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}')
  elif command -v ss >/dev/null 2>&1; then
    while read -r addr; do
      _ps_addr_is_local "$addr" || continue
      port=${addr##*:}
      [[ $port =~ ^[0-9]+$ ]] && SNAP_PORT_OPEN[$port]=1
    done < <(ss -tlnH 2>/dev/null | awk '{print $4}')
  fi

  # Elapsed centiseconds — the denominator for every CPU% below. Zero on the
  # first frame, which correctly yields 0% rather than a spike.
  local wall_cs=0
  [ "$prev_us" -gt 0 ] && wall_cs=$(( (SNAP_AT_US - prev_us) / 10000 ))

  local -A rss=() cs=() comm=()
  local -A cs_now=()
  _PS_KIDS=()
  local pid ppid r tm cm all_cs=0
  while read -r pid ppid r tm cm; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    _PS_KIDS[$ppid]+="$pid "
    rss[$pid]=$(( r * 1024 ))
    _cputime_cs "$tm"
    cs[$pid]=$_CS
    all_cs=$(( all_cs + _CS ))
    # macOS prints comm as the full executable path; the dashboard has one
    # narrow column for it, so show what the Linux path shows.
    comm[$pid]=${cm##*/}
  done < <("${PITCREW_PS[@]}" -e -o pid=,ppid=,rss=,time=,comm= 2>/dev/null)

  local c p rss_sum cs_sum d
  for c in "${PITCREW_COMPS[@]}"; do
    _read_pidfile "$c"; pid=$PIDF
    SNAP_PID[$c]=$pid
    SNAP_RSS[$c]=""; SNAP_CPU[$c]=""; SNAP_PIDS[$c]=""
    [ -n "$pid" ] && [ -n "${rss[$pid]:-}" ] || continue

    _TREE=(); _walk_ps_tree "$pid"
    SNAP_PIDS[$c]="${_TREE[*]}"
    rss_sum=0; cs_sum=0
    for p in "${_TREE[@]}"; do
      rss_sum=$(( rss_sum + ${rss[$p]:-0} ))
      cs_sum=$(( cs_sum + ${cs[$p]:-0} ))
      SNAP_PROC_RSS[$p]=${rss[$p]:-0}
      SNAP_PROC_CMD[$p]=${comm[$p]:-?}
      cs_now[$p]=${cs[$p]:-0}
      if [ "$wall_cs" -gt 0 ] && [ -n "${_JIFF_PREV[$p]:-}" ]; then
        d=$(( (${cs[$p]:-0} - ${_JIFF_PREV[$p]}) * 100 / wall_cs ))
        [ $d -lt 0 ] && d=0
        SNAP_PROC_CPU[$p]=$d
      else
        SNAP_PROC_CPU[$p]=0
      fi
    done
    SNAP_RSS[$c]=$rss_sum

    if [ "$wall_cs" -gt 0 ] && [ -n "${_JIFF_TREE_PREV[$c]:-}" ]; then
      d=$(( (cs_sum - ${_JIFF_TREE_PREV[$c]}) * 100 / wall_cs ))
      [ $d -lt 0 ] && d=0                     # a restarted tree can go backwards
      SNAP_CPU[$c]=$d
    else
      SNAP_CPU[$c]=0
    fi
    _JIFF_TREE_NOW[$c]=$cs_sum
  done

  # Rebuild rather than update, so pids from stopped components don't
  # accumulate across a long session.
  unset _JIFF_PREV; declare -gA _JIFF_PREV=()
  for p in "${!cs_now[@]}"; do _JIFF_PREV[$p]=${cs_now[$p]}; done
  unset _JIFF_TREE_PREV; declare -gA _JIFF_TREE_PREV=()
  for c in "${!_JIFF_TREE_NOW[@]}"; do _JIFF_TREE_PREV[$c]=${_JIFF_TREE_NOW[$c]}; done
  unset _JIFF_TREE_NOW; declare -gA _JIFF_TREE_NOW=()

  sys_gauges
  # Where the platform layer cannot measure system CPU cheaply (macOS: only
  # `top -l 1`, ~200ms a frame and wrong on its first sample), derive it from
  # the CPU-time totals we just summed over EVERY process. Same ps output, no
  # extra fork, and it is a true delta over the sampling window.
  if [ "$PITCREW_SYS_CPU_SELF" = 0 ] && [ "$wall_cs" -gt 0 ] && [ "${_ALL_CS_PREV:-0}" -gt 0 ]; then
    d=$(( (all_cs - _ALL_CS_PREV) * 100 / (wall_cs * PITCREW_NCPU) ))
    [ $d -lt 0 ] && d=0
    [ $d -gt 100 ] && d=100
    SYS_CPU_PCT=$d
  fi
  _ALL_CS_PREV=$all_cs
}

# tree walk over the ps-derived children map (fallback path only)
_walk_ps_tree() {
  local pid=$1 k
  _TREE+=("$pid")
  for k in ${_PS_KIDS[$pid]:-}; do _walk_ps_tree "$k"; done
}

# ── health probes, off the frame's critical path ────────────────────────────
# A booting Spring Boot actuator can take seconds to answer. Probing inline
# once per frame (what be_health used to do) would stall every repaint, so
# probes run in the background and each frame just reads the last result.
_health_poll() {
  local app path port f r iv
  for app in "${PITCREW_APPS[@]}"; do
    path=${PITCREW_BE_HEALTH_PATH[$app]:-}
    port=${PITCREW_BE_PORT[$app]:-}
    if [ -z "$path" ] || [ -z "$port" ]; then
      SNAP_HEALTH[$app]=UP                      # nothing configured → open port is enough
      continue
    fi
    f="$LOG_DIR/.health-$app"
    if [ -r "$f" ]; then
      r=""; read -r r < "$f" 2>/dev/null
      SNAP_HEALTH[$app]=${r:-DOWN}
    else
      SNAP_HEALTH[$app]=DOWN
    fi
    # No point probing a port nothing is listening on.
    [ -n "${SNAP_PORT_OPEN[$port]:-}" ] || continue
    iv=$PITCREW_HEALTH_INTERVAL
    [ "${SNAP_HEALTH[$app]}" = UP ] && iv=$(( iv * 3 ))   # only interesting while booting
    if [ $(( SNAP_NOW_S - ${SNAP_HEALTH_AT[$app]:-0} )) -ge "$iv" ]; then
      SNAP_HEALTH_AT[$app]=$SNAP_NOW_S
      { curl -sf -m 2 "http://127.0.0.1:${port}${path}" 2>/dev/null | grep -q '"UP"' \
          && echo UP > "$f" || echo DOWN > "$f"; } >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
  done
}

# `docker inspect` is by far the most expensive thing the dashboard can touch:
# the CLI is a Go binary, so one invocation costs ~100ms and shows up as
# dozens of clones. comp_state used to call it once per dep PER FRAME. Now
# it's one batched call for all deps, on its own slow interval.
_dep_poll() {
  local dep name state line
  [ ${#PITCREW_DEPS[@]} -eq 0 ] && return 0
  [ $(( SNAP_NOW_S - ${SNAP_DEP_AT:-0} )) -ge "$PITCREW_DEP_INTERVAL" ] || return 0
  SNAP_DEP_AT=$SNAP_NOW_S
  for dep in "${PITCREW_DEPS[@]}"; do SNAP_DEP[$dep]=down; done
  # One `docker inspect` for every dep at once. A container that doesn't exist
  # is simply absent from the output, which leaves it at the "down" default.
  while IFS= read -r line; do
    name=${line%%=*}; state=${line#*=}
    name=${name#/}
    [ "$state" = true ] && SNAP_DEP[$name]=up
  done < <(docker inspect -f '{{.Name}}={{.State.Running}}' "${PITCREW_DEPS[@]}" 2>/dev/null)
  return 0
}

# ── component states, derived from the arrays above ─────────────────────────
_snapshot_states() {
  local c app role port pid st
  for c in "${PITCREW_COMPS[@]}"; do
    app=${c#??-}; role=${c:0:2}
    if [ "$role" = be ]; then port=${PITCREW_BE_PORT[$app]:-}; else port=${PITCREW_FE_PORT[$app]:-}; fi
    pid=${SNAP_PID[$c]:-}
    if [ -n "$port" ] && [ -n "${SNAP_PORT_OPEN[$port]:-}" ]; then
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        if [ "$role" = be ] && [ "${SNAP_HEALTH[$app]:-UP}" != UP ]; then st=starting; else st=up; fi
      else
        # Something is listening, but it is not ours. Reporting that as "up"
        # is how a project can appear to be running when it is not: two
        # projects that share a port (and they do — 8080 and 3000 are hardly
        # unique) each see the other's service and count it as their own.
        st=external
      fi
    elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      st=starting                                # alive, port not open yet — still booting
    elif [ -n "$pid" ]; then
      st=crashed                                 # pidfile recorded, process gone
    else
      st=down
    fi
    SNAP_STATE[$c]=$st

    # "crashed" on its own tells you nothing actionable. The wrapper in
    # launch_process records how the run ended, so say so.
    unset "SNAP_EXIT[$c]" "SNAP_EXIT_AT[$c]"
    if [ "$st" = crashed ] && [ -r "$LOG_DIR/$c.exit" ]; then
      local code when
      read -r code when < "$LOG_DIR/$c.exit" 2>/dev/null
      [ -n "${code:-}" ] && { SNAP_EXIT[$c]=$code; SNAP_EXIT_AT[$c]=${when:-0}; }
    fi
  done
}

snapshot() {
  case "$PITCREW_COLLECTOR" in
    proc) _snapshot_proc ;;
    *)    _snapshot_ps ;;
  esac
  _health_poll
  _dep_poll
  _snapshot_states
  SNAP_READY=1
}
