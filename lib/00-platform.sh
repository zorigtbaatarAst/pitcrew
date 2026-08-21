#!/usr/bin/env bash
# lib/00-platform.sh — the only file that knows which OS it is running on.
#
# Linux and macOS are both first-class targets: same features, same numbers on
# screen, different plumbing underneath. Every OS-specific decision lives here
# so the rest of the tool can be written once — a `Darwin` case or a /proc read
# anywhere outside this file is a bug.
#
#   linux    /proc + systemd cgroups   fork-free meters, ENFORCED RAM caps
#   macos    ps/lsof/sysctl/vm_stat    same meters, no cap enforcement (there is
#                                      no cgroup equivalent — see doctor)
#   bsd      same portable path as macOS, minus the sysctl/vm_stat gauges
#   windows  not native: no bash 5, no /dev/tcp, no POSIX ps. Run under WSL2,
#            where pitcrew sees a normal Linux userland and this file says
#            "linux" like it would on any other box.
#
# The portable path is not a degraded mode kept alive out of politeness — it is
# what macOS runs every day, so PITCREW_COLLECTOR=ps can be forced on Linux to
# exercise it (test/platform_test.sh does exactly that).

case "$(uname -s)" in
  Linux)                   PITCREW_OS=linux ;;
  Darwin)                  PITCREW_OS=macos ;;
  FreeBSD|OpenBSD|NetBSD|DragonFly) PITCREW_OS=bsd ;;
  MINGW*|MSYS*|CYGWIN*)    PITCREW_OS=windows ;;
  *)                       PITCREW_OS=other ;;
esac

HAS_SYSTEMD=0
if [ "$PITCREW_OS" = linux ] && command -v systemctl >/dev/null 2>&1 \
   && systemctl --user status >/dev/null 2>&1; then
  HAS_SYSTEMD=1
fi

# Cores, for turning per-core-summed CPU time into a 0-100 system gauge.
# `getconf _NPROCESSORS_ONLN` is the one spelling both Linux and macOS answer.
PITCREW_NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
[ "$PITCREW_NCPU" -ge 1 ] 2>/dev/null || PITCREW_NCPU=1

# `ps` truncates its output to the terminal width on BSD/macOS, which silently
# cuts the command column mid-parse. -ww turns that off; GNU ps accepts it too,
# so there is one spelling rather than two code paths.
PITCREW_PS=(ps -ww)

# ── run a command with a deadline ───────────────────────────────────────────
# GNU coreutils' `timeout` is not on a stock macOS; Homebrew's coreutils
# installs it prefixed as `gtimeout`. With neither, run the command in the
# background and shoot it if it overstays. The fallback costs two extra
# processes, so it is the last resort and not the default.
if command -v timeout >/dev/null 2>&1; then
  pf_timeout() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  pf_timeout() { gtimeout "$@"; }
else
  pf_timeout() { # $1 seconds, $2... command
    local secs=$1 rc=0 pid killer
    shift
    "$@" & pid=$!
    { sleep "$secs"; kill -TERM "$pid"; } 2>/dev/null & killer=$!
    wait "$pid" 2>/dev/null || rc=$?
    kill -TERM "$killer" 2>/dev/null
    wait "$killer" 2>/dev/null
    return $rc
  }
fi

# ── boot-time marker ────────────────────────────────────────────────────────
# A pidfile written before the current boot cannot describe a live process: the
# pid it names is either gone or now belongs to something unrelated. The check
# runs per component per frame, so it has to be a `-nt` test against a file
# whose mtime IS the boot instant — a builtin, no fork.
#
# Linux publishes one for free: /proc/1's mtime is the boot instant. macOS has
# no such file, so stamp one, once per process, from kern.boottime. Anywhere
# else PITCREW_BOOT_MARKER stays empty and pidfiles are trusted as they were
# before — degraded, but never wrong in the other direction.
PITCREW_BOOT_MARKER=""

_boot_marker_stamp() { # $1 = boot epoch seconds → marker path, or failure
  local sec=$1 stamp marker="${TMPDIR:-/tmp}/pitcrew-boot-${UID}"
  case "$sec" in ''|*[!0-9]*) return 1 ;; esac
  printf -v stamp '%(%Y%m%d%H%M.%S)T' "$sec"       # touch -t's CCYYMMDDhhmm.SS
  # Rewritten every run on purpose: a marker left over from a PREVIOUS boot
  # carries the previous boot's mtime, which would make every stale pidfile
  # look current — the exact bug this marker exists to prevent.
  : > "$marker" 2>/dev/null || return 1
  touch -t "$stamp" "$marker" 2>/dev/null || return 1
  PITCREW_BOOT_MARKER=$marker
}

case "$PITCREW_OS" in
  linux) [ -d /proc/1 ] && PITCREW_BOOT_MARKER=/proc/1 ;;
  macos|bsd)
    # "{ sec = 1755600000, usec = 0 } Tue Aug 19 17:20:00 2026"
    _pf_bt=$(sysctl -n kern.boottime 2>/dev/null)
    _pf_bt=${_pf_bt#*sec = }; _pf_bt=${_pf_bt%%,*}; _pf_bt=${_pf_bt// /}
    _boot_marker_stamp "$_pf_bt" || PITCREW_BOOT_MARKER=""
    unset _pf_bt
    ;;
esac

# ── port → pid ──────────────────────────────────────────────────────────────
# lsof is the portable choice and the only one macOS has; ss is the Linux
# fallback for boxes without lsof. Parsing ss with sed rather than `grep -oP`
# keeps this working under BSD grep, which has no -P.
port_pid() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1
  elif command -v ss >/dev/null 2>&1; then
    ss -tlnpH "sport = :$1" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1
  fi
}

# ── process trees ───────────────────────────────────────────────────────────
# Only the stop path uses these — the dashboard walks trees inside the snapshot
# collector, without forking. `pgrep -P` means the same thing on Linux and BSD.
descendant_pids() { # $1 pid → that pid + every descendant, one per line
  local pid=$1 kids k
  echo "$pid"
  kids=$(pgrep -P "$pid" 2>/dev/null) || return 0
  for k in $kids; do descendant_pids "$k"; done
}

kill_tree() { # $1 pid — TERM then, after a grace period, KILL, whole tree
  local pid=$1 t=0 pids
  kill -0 "$pid" 2>/dev/null || return 0
  pids=$(descendant_pids "$pid")
  kill -TERM $pids 2>/dev/null
  while kill -0 "$pid" 2>/dev/null && [ $t -lt 8 ]; do sleep 1; t=$((t + 1)); done
  kill -0 "$pid" 2>/dev/null && kill -KILL $pids 2>/dev/null
}

# ── system-wide CPU/RAM gauges for the live dashboard ───────────────────────
# Sets SYS_CPU_PCT (0-100 int), SYS_MEM_USED_KB, SYS_MEM_TOTAL_KB. Never fails
# hard — an unreadable gauge renders as "—", it does not crash the dashboard.
#
# PITCREW_SYS_CPU_SELF says whether this file can measure system CPU at all.
# Linux can, from /proc/stat. macOS cannot cheaply: the usual answer is
# `top -l 1`, which costs ~200ms per frame AND reports usage since boot on its
# first sample — slow and wrong. So on macOS the snapshot collector derives it
# from the per-process CPU-time deltas it is already collecting, for no extra
# fork at all, and this file leaves SYS_CPU_PCT alone.
PITCREW_SYS_CPU_SELF=0
[ "$PITCREW_OS" = linux ] && PITCREW_SYS_CPU_SELF=1

sys_gauges_linux() {
  local total idle d_total d_idle u n s i iow irq sirq steal
  read -r _ u n s i iow irq sirq steal _ < /proc/stat
  total=$((u + n + s + i + iow + irq + sirq + steal)); idle=$((i + iow))
  d_total=$((total - SYS_P_TOTAL)); d_idle=$((idle - SYS_P_IDLE))
  [ $d_total -gt 0 ] && SYS_CPU_PCT=$(( (d_total - d_idle) * 100 / d_total ))
  SYS_P_TOTAL=$total; SYS_P_IDLE=$idle
  # /proc/meminfo with the read builtin — this used to be two awks, i.e. four
  # forks on every single frame. MemAvailable sits within the first few lines,
  # so the loop bails as soon as it has both numbers.
  # mapfile, not a read loop — see the note in lib/03a-snapshot.sh about read's
  # byte-at-a-time behaviour on /proc. MemTotal/MemFree/MemAvailable are the
  # first three lines.
  local k v avail=0
  local -a mi
  SYS_MEM_TOTAL_KB=0
  mapfile -t -n 3 mi < /proc/meminfo
  for k in "${mi[@]}"; do
    v=${k#*:}; v=${v% kB}; v=${v// /}     # "MemTotal:   32525836 kB" -> "32525836"
    case "${k%%:*}" in
      MemTotal)     SYS_MEM_TOTAL_KB=$v ;;
      MemAvailable) avail=$v ;;
    esac
  done
  SYS_MEM_USED_KB=$((SYS_MEM_TOTAL_KB - avail))
}

# Physical RAM never changes while we run, so ask exactly once.
PITCREW_MEM_TOTAL_KB=0
case "$PITCREW_OS" in
  macos|bsd) PITCREW_MEM_TOTAL_KB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 )) ;;
esac

# macOS "used" is not "total minus free": free is always near zero because the
# kernel keeps every spare page as cache. Reclaimable = free + speculative +
# purgeable + file-backed, which is what Activity Monitor effectively treats as
# available — counting only free pages reports a 32G Mac as permanently full
# and makes the RAM preflight useless.
# Split out from sys_gauges_macos so it can be fed captured vm_stat output on a
# machine that has no vm_stat — see test/platform_test.sh. Page counts carry a
# trailing period ("Pages free:  123456."), the page size is only stated in the
# header line, and older releases omit "File-backed pages" entirely (awk reads
# an absent variable as 0, which is the right answer).
_vm_stat_avail_kb() { # vm_stat output on stdin → available KiB on stdout
  awk '
    /page size of/     { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) ps = $i }
    /Pages free/       { gsub(/\./, "", $NF); f = $NF }
    /Pages speculative/{ gsub(/\./, "", $NF); s = $NF }
    /Pages purgeable/  { gsub(/\./, "", $NF); p = $NF }
    /File-backed pages/{ gsub(/\./, "", $NF); b = $NF }
    END { if (ps > 0) printf "%d", (f + s + p + b) * ps / 1024 }'
}

sys_gauges_macos() {
  SYS_MEM_TOTAL_KB=$PITCREW_MEM_TOTAL_KB
  [ "$SYS_MEM_TOTAL_KB" -gt 0 ] || return 0
  local avail_kb
  avail_kb=$(vm_stat 2>/dev/null | _vm_stat_avail_kb)
  case "$avail_kb" in
    ''|*[!0-9]*) return 0 ;;                       # unparseable → leave it unknown
  esac
  [ "$avail_kb" -le "$SYS_MEM_TOTAL_KB" ] || avail_kb=$SYS_MEM_TOTAL_KB
  SYS_MEM_USED_KB=$((SYS_MEM_TOTAL_KB - avail_kb))
}

# ── swap ────────────────────────────────────────────────────────────────────
# Swap is the clearest single signal that a development box is in trouble, and
# the one number none of the other gauges can stand in for: RAM at 96% is
# normal on a machine with a big page cache, RAM at 96% *with swap climbing* is
# a laptop about to stutter for ten minutes. Diagnostics needs it (lib/19-diag)
# and nothing else measures it.
#
# Sampled on its own slow interval rather than per frame. On Linux this is
# fork-free either way; on macOS it costs one `sysctl`, and the frame loop's
# two-fork budget is a promise. Swap does not move fast enough to care.
SYS_SWAP_TOTAL_KB=0
SYS_SWAP_USED_KB=0

sys_swap_linux() {
  # The Swap lines sit well past MemAvailable, so unlike sys_gauges_linux this
  # reads the whole file — still one open/read/close, still no fork.
  local k v total=0 free=0
  local -a mi
  mapfile -t mi < /proc/meminfo 2>/dev/null || return 0
  for k in "${mi[@]}"; do
    case "${k%%:*}" in
      SwapTotal) v=${k#*:}; v=${v% kB}; total=${v// /} ;;
      SwapFree)  v=${k#*:}; v=${v% kB}; free=${v// /}; break ;;   # SwapFree follows SwapTotal
    esac
  done
  case "$total$free" in ''|*[!0-9]*) return 0 ;; esac
  SYS_SWAP_TOTAL_KB=$total
  SYS_SWAP_USED_KB=$(( total - free ))
}

# `sysctl -n vm.swapusage` → "total = 2048.00M  used = 1024.50M  free = ..."
# The suffix is always M on every release that has this key, but read it rather
# than assume it: a number silently off by 1024 is worse than no number.
sys_swap_macos() {
  local line total used
  line=$(sysctl -n vm.swapusage 2>/dev/null) || return 0
  [ -n "$line" ] || return 0
  total=${line#*total = }; total=${total%% *}
  used=${line#*used = };   used=${used%% *}
  _swap_kb "$total"; SYS_SWAP_TOTAL_KB=$SWAP_KB
  _swap_kb "$used";  SYS_SWAP_USED_KB=$SWAP_KB
}

_swap_kb() { # "1024.50M" → SWAP_KB (integer KiB; the fraction is noise here)
  local v=$1 unit=${1: -1}
  SWAP_KB=0
  v=${v%[KMGkmg]}
  v=${v%%.*}
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  case "$unit" in
    K|k) SWAP_KB=$v ;;
    M|m) SWAP_KB=$(( v * 1024 )) ;;
    G|g) SWAP_KB=$(( v * 1024 * 1024 )) ;;
    *)   SWAP_KB=$(( v / 1024 )) ;;               # a bare byte count
  esac
}

sys_swap() {
  case "$PITCREW_OS" in
    linux)     sys_swap_linux 2>/dev/null ;;
    macos|bsd) sys_swap_macos 2>/dev/null ;;
  esac
  return 0
}

sys_gauges() {
  SYS_CPU_PCT=${SYS_CPU_PCT:-0}; SYS_MEM_USED_KB=""; SYS_MEM_TOTAL_KB=""
  SYS_P_TOTAL=${SYS_P_TOTAL:-0}; SYS_P_IDLE=${SYS_P_IDLE:-0}
  case "$PITCREW_OS" in
    linux)     sys_gauges_linux 2>/dev/null ;;
    macos|bsd) sys_gauges_macos 2>/dev/null ;;
  esac
  return 0
}

# ── which collector the dashboard uses (see lib/03a-snapshot.sh) ────────────
# "proc" reads everything out of /proc with bash builtins — zero forks per
# frame. "ps" is the portable path macOS runs on: one `ps` + one port listing
# per frame. Linux falls back to it too if /proc is somehow unreadable, so the
# tool degrades instead of breaking.
if [ "$PITCREW_OS" = linux ] && [ -r /proc/net/tcp ] && [ -r /proc/self/stat ]; then
  # shellcheck disable=SC2209  # the literal string "proc", not the command
  PITCREW_COLLECTOR=proc
else
  # shellcheck disable=SC2209  # the literal string "ps", not the command
  PITCREW_COLLECTOR=ps
fi
# Escape hatch for exercising the portable path on a Linux box.
# shellcheck disable=SC2209  # the literal string "ps", not the command
[ "${PITCREW_FORCE_COLLECTOR:-}" = ps ] && PITCREW_COLLECTOR=ps
