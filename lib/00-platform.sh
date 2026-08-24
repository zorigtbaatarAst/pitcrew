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
#   windows  native, under Git Bash or MSYS2 — see the block near the bottom of
#            this file. The shell is real bash 5; what is missing is the POSIX
#            userland underneath it, so the process table comes from wmic or
#            PowerShell, listening ports from netstat, and RAM caps do not
#            exist at all. WSL2 remains the better experience and says "linux"
#            like any other box.
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
#
# An ARRAY, not a string, and the first word is resolved by bash the normal
# way — so on Windows it can be the name of a shell FUNCTION that produces the
# same columns from a native process table. The portable collector then works
# there unchanged, which is the whole reason it is written against a column
# layout rather than against `ps` itself.
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

# ── is this file something we can run? ──────────────────────────────────────
# `[ -x ]` answers this everywhere but Windows, where there is no execute
# permission at all: NTFS has no such bit and MSYS synthesises one from the
# file extension, so a shebang script like `gradlew` or `mvnw` reads as NOT
# executable even though bash runs it perfectly. `pitcrew init` therefore wrote
# `cd $ROOT/x && gradle bootRun` for a repo that ships a wrapper — pointing at
# a system gradle the machine may not even have.
pf_runnable() { # $1 path
  [ -f "$1" ] || return 1
  [ "$PITCREW_OS" = windows ] && return 0
  [ -x "$1" ]
}

# ── listening ports ─────────────────────────────────────────────────────────
# Every locally-reachable listening port, one per line, as `addr:port`. Lifted
# out of the collector so that "how do I see a listening socket" is answered
# once, here, by the file that is allowed to know what OS this is.
pf_listening() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}'
  elif command -v ss >/dev/null 2>&1; then
    ss -tlnH 2>/dev/null | awk '{print $4}'
  fi
}

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

# ── a pid, as the native tools understand it ────────────────────────────────
# Everywhere but Windows a pid is a pid. There, the pidfile holds an MSYS pid
# (so `kill` and kill_tree keep working) while wmic and netstat only know the
# Windows one, so the two have to be told apart at exactly the boundary where
# one becomes the other — and nowhere else.
pf_pid_native() { NATIVE_PID=$1; }

# Parent→child links the process table does not contain, added to the map the
# portable collector just built (see _snapshot_ps). Nothing to add anywhere but
# Windows, where a POSIX tree and the Windows one are genuinely two different
# shapes — see _pf_win_msys_kids.
pf_extra_kids() { :; }

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
    windows)   sys_gauges_windows 2>/dev/null ;;
  esac
  return 0
}

# ── Windows, natively ───────────────────────────────────────────────────────
#
# Under Git Bash or MSYS2 the SHELL is real bash 5 — that part was never the
# problem. What is missing is everything underneath it: no /proc, no POSIX ps,
# no lsof, no cgroups. So each of those is answered by a native tool instead,
# and the rest of pitcrew does not find out.
#
#   process table   wmic, else PowerShell — reshaped into the exact columns the
#                   portable collector already parses (see pf_ps_win)
#   ports           netstat -ano, which gives port AND owning pid in one call
#   liveness/kill   MSYS pids in the pidfiles, so `kill` and kill_tree keep
#                   working; translated to Windows pids only where a native
#                   tool needs one
#   RAM caps        NOT ENFORCEABLE. Windows has Job Objects but no command
#                   that puts a process in one, so the caps are budgets the
#                   meters measure against — the same honest degradation macOS
#                   gets, and doctor says so rather than letting the identical
#                   meters imply otherwise.
#
# Cost: a frame here is one process-table call plus one netstat, against zero
# forks on Linux and two on macOS. wmic is ~80ms, PowerShell ~300ms, so the
# default refresh is slower here and doctor explains why.

# WMI reports CPU time in 100-nanosecond ticks and memory in bytes; the
# collector wants centisecond-ish "[[dd-]hh:]mm:ss.cc" and kilobytes. Kept as a
# pure filter over captured output so it can be tested on a machine that has
# never seen Windows — the same bargain _vm_stat_avail_kb strikes for macOS.
#
# Input is wmic's CSV: Node,CreationDate,KernelModeTime,Name,ParentProcessId,ProcessId,UserModeTime,WorkingSetSize
# Days since 1970-01-01 for a civil date, by arithmetic alone.
#
# NOT awk's mktime(): that is a GNU extension. BSD awk does not merely return
# zero for it, it refuses to run the program at all — so on macOS the whole
# parser produced nothing and every field came out empty. "No GNU-only tools"
# is a rule this project holds everywhere else, and awk is not exempt.
#
# Howard Hinnant's days_from_civil. March-based years put the leap day at the
# end, which is what removes every special case.
_PF_DAYS_FROM_CIVIL='
function days_from_civil(y, m, d,    era, yoe, doy, doe) {
  if (m <= 2) y--
  era = int(y / 400)
  yoe = y - era * 400
  doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}'

_wmic_ps_parse() { # $1 = epoch seconds now; wmic CSV on stdin → ps-shaped columns
  awk -F, -v now="$1" "$_PF_DAYS_FROM_CIVIL"'
    NR == 1 || NF < 8 { next }
    {
      # WMI CreationDate is yyyymmddHHMMSS.ffffff±MMM, where the suffix is
      # minutes east of UTC. Parsed rather than assumed to cancel: computing the
      # epoch by hand gives a UTC instant, so the offset has to come off it.
      created = substr($2, 1, 14)
      elapsed = 0
      if (created ~ /^[0-9]{14}$/) {
        offset = 0
        if (match($2, /[+-][0-9]+$/)) offset = substr($2, RSTART, RLENGTH) + 0
        birth = days_from_civil(substr(created,1,4) + 0, substr(created,5,2) + 0,
                                substr(created,7,2) + 0) * 86400 \
              + substr(created,9,2) * 3600 + substr(created,11,2) * 60 \
              + substr(created,13,2) - offset * 60
        if (birth > 0 && now > birth) elapsed = now - birth
      }
      cs   = int(($3 + $7) / 100000)          # 100ns ticks -> centiseconds
      rss  = int($8 / 1024)                   # bytes -> KiB
      printf "%d %d %d %d:%02d.%02d %02d:%02d:%02d %s\n",
             $6, $5, rss,
             int(cs/6000), int(cs/100) % 60, cs % 100,
             int(elapsed/3600), int(elapsed/60) % 60, elapsed % 60,
             $4
    }'
}

# PowerShell is the durable route — wmic is deprecated and gone from recent
# Windows 11 — but it costs a few hundred milliseconds to start, so it is the
# fallback rather than the default. Asked for the same fields in the same order
# so ONE parser serves both.
_pf_ps_win_powershell() {
  powershell.exe -NoProfile -NonInteractive -Command \
    "Get-CimInstance Win32_Process | ForEach-Object { \
       'x,' + \$_.CreationDate.ToString('yyyyMMddHHmmss') + ',' + \$_.KernelModeTime + ',' + \
       \$_.Name + ',' + \$_.ParentProcessId + ',' + \$_.ProcessId + ',' + \
       \$_.UserModeTime + ',' + \$_.WorkingSetSize }" 2>/dev/null | tr -d '\r'
}

_pf_ps_win_wmic() {
  wmic process get CreationDate,KernelModeTime,Name,ParentProcessId,ProcessId,UserModeTime,WorkingSetSize \
    /format:csv 2>/dev/null | tr -d '\r'
}

# The shim PITCREW_PS points at. Its arguments are the POSIX `ps` flags the
# collector passes; they are ignored, because the columns they ask for are
# exactly what this produces.
pf_ps_win() {
  local now
  printf -v now '%(%s)T' -1
  "$PITCREW_WIN_PS_SOURCE" | _wmic_ps_parse "$now"
}

# netstat -ano, which is on every Windows and needs no install:
#   Proto  Local Address    Foreign Address  State       PID
#   TCP    0.0.0.0:8080     0.0.0.0:0        LISTENING   1234
# Only the local address is wanted here; the pid column is what pf_port_pid_win
# uses, from the same output.
_netstat_listening_parse() {
  awk '$1 ~ /^TCP/ && $4 == "LISTENING" { print $2 }'
}

_netstat_port_pid_parse() { # $1 = port; netstat -ano on stdin -> owning pid
  awk -v want=":" -v port="$1" '
    $1 ~ /^TCP/ && $4 == "LISTENING" {
      addr = $2
      n = split(addr, part, ":")
      if (part[n] == port) { print $5; exit }
    }'
}

# An MSYS/Cygwin pid is not a Windows pid, and netstat and wmic only know the
# latter. The mapping is published for free at /proc/<pid>/winpid — one builtin
# read, no fork — so pidfiles keep holding MSYS pids (which is what `kill` and
# kill_tree need) and the translation happens only where a native tool is on
# the other end.
_pf_read_winpid() { # $1 msys pid -> WINPID, or "" when there is no mapping
  WINPID=""
  [ -r "/proc/$1/winpid" ] && read -r WINPID < "/proc/$1/winpid" 2>/dev/null
  case "$WINPID" in *[!0-9]*) WINPID="" ;; esac
}

pf_winpid() { # $1 msys pid -> WINPID, or the input unchanged if unmappable
  _pf_read_winpid "$1"
  [ -n "$WINPID" ] || WINPID=$1
}

# The POSIX process tree, which the WINDOWS process table does not contain.
#
# Cygwin (and so MSYS2, and so Git Bash) has no exec: it implements one by
# creating a NEW Windows process for the program being exec'd. So a child that
# forks and then execs leaves the Windows table saying its parent is a process
# that has already gone, and the link back to the real parent is lost.
#
# That is not a corner case here — it is every service pitcrew starts.
# launch_process wraps each one in a subshell that runs `bash -c <cmd>`, and
# the pidfile holds the wrapper. Walking the Windows table alone found the
# wrapper and nothing beneath it, so every component on Windows reported the
# wrapper's few MB and none of the JVM or node process actually doing the work.
#
# MSYS keeps the answer in its own /proc, where ppid and winpid are both plain
# one-line reads — so this costs no fork, only the builtin reads, and only for
# the handful of MSYS processes on the box.
#
# The link is ADDED to what the Windows table said rather than replacing it: a
# native child of a native process — a JVM's own workers — is only in that one.

# Adding one link, split out because it is the half of this that can be checked
# on a machine with no /proc/<pid>/winpid to read (test/snapshot_test.sh).
_pf_kid_link() { # $1 child pid, $2 parent pid — as the process table spells them
  [ "$1" != "$2" ] || return 0                 # a self-link is a walk that never ends
  case " ${_PS_KIDS[$2]:-} " in *" $1 "*) return 0 ;; esac
  _PS_KIDS[$2]+="$1 "
}

# And reading them, which needs the real thing.
_pf_win_msys_kids() {
  local d pid ppid child parent
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ -r "$d/ppid" ] || continue
    read -r ppid < "$d/ppid" 2>/dev/null
    case "$ppid" in ''|0|*[!0-9]*) continue ;; esac
    # Both ends must really map. pf_winpid falls back to the pid it was given,
    # and an MSYS pid used as a Windows one is some unrelated process.
    _pf_read_winpid "$pid";  child=$WINPID;  [ -n "$child" ]  || continue
    _pf_read_winpid "$ppid"; parent=$WINPID; [ -n "$parent" ] || continue
    _pf_kid_link "$child" "$parent"
  done
}

_pf_windows_init() {
  # Which process table this box can actually produce. Resolved once: probing
  # per frame would cost more than the call it is choosing between.
  PITCREW_WIN_PS_SOURCE=""
  if command -v wmic >/dev/null 2>&1 && wmic os get Caption /format:csv >/dev/null 2>&1; then
    PITCREW_WIN_PS_SOURCE=_pf_ps_win_wmic
  elif command -v powershell.exe >/dev/null 2>&1; then
    PITCREW_WIN_PS_SOURCE=_pf_ps_win_powershell
  fi
  [ -n "$PITCREW_WIN_PS_SOURCE" ] && PITCREW_PS=(pf_ps_win)

  pf_pid_native() { pf_winpid "$1"; NATIVE_PID=$WINPID; }
  pf_extra_kids() { _pf_win_msys_kids; }
  pf_listening() { netstat -ano 2>/dev/null | tr -d '\r' | _netstat_listening_parse; }
  port_pid() { netstat -ano 2>/dev/null | tr -d '\r' | _netstat_port_pid_parse "$1"; }

  # Total RAM is NOT resolved here. See _pf_win_mem_total_once: where wmic is
  # gone it costs a PowerShell start, and `pitcrew stop` should not pay a third
  # of a second for a number it never reads.
}

# One PowerShell expression, its answer trimmed. Every whitespace byte goes,
# the \r a Windows tool leaves included, because every caller here wants a bare
# integer.
_pf_win_ps() { # $1 = expression
  powershell.exe -NoProfile -NonInteractive -Command "$1" 2>/dev/null | tr -d ' \t\r\n'
}

_pf_win_mem_total_kb() { # → total physical RAM in KiB, or failure
  local bytes=""
  case "${PITCREW_WIN_PS_SOURCE:-}" in
    _pf_ps_win_wmic)
      bytes=$(wmic computersystem get TotalPhysicalMemory /value 2>/dev/null | tr -d '\r' |
              sed -n 's/^TotalPhysicalMemory=//p') ;;
    _pf_ps_win_powershell)
      bytes=$(_pf_win_ps '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory') ;;
  esac
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' $(( bytes / 1024 ))
}

# Already KILOBYTES in both sources — the one WMI counter that is not in bytes.
_pf_win_mem_free_kb() { # → free physical RAM in KiB, or failure
  local free=""
  case "${PITCREW_WIN_PS_SOURCE:-}" in
    _pf_ps_win_wmic)
      free=$(wmic os get FreePhysicalMemory /value 2>/dev/null | tr -d '\r' |
             sed -n 's/^FreePhysicalMemory=//p') ;;
    _pf_ps_win_powershell)
      free=$(_pf_win_ps '(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory') ;;
  esac
  case "$free" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$free"
}

# Free memory has to be sampled, not resolved once — but where wmic is gone,
# sampling it costs a whole PowerShell start (a few hundred ms), which is more
# than the process table the frame is already paying for. So it is sampled on
# its OWN slow interval and held in between, exactly the deal sys_swap strikes:
# RAM does not move fast enough for one frame to care.
PITCREW_WIN_MEM_INTERVAL=${PITCREW_WIN_MEM_INTERVAL:-5}
_PF_WIN_MEM_AT=0
_PF_WIN_MEM_FREE_KB=""
_PF_WIN_MEM_TOTAL_DONE=0

# Physical RAM does not change while we run, so it is asked once — but on the
# first frame that wants it, not at startup. Asking only wmic for it is how the
# gauge came to read "unavailable on this OS" on every recent Windows 11: wmic
# is deprecated and gone from the current images, the process table had already
# fallen back to PowerShell, and this had not. The machine gauge and the RAM
# preflight went dead together.
_pf_win_mem_total_once() {
  [ "$_PF_WIN_MEM_TOTAL_DONE" = 1 ] && return 0
  _PF_WIN_MEM_TOTAL_DONE=1
  PITCREW_MEM_TOTAL_KB=$(_pf_win_mem_total_kb) || PITCREW_MEM_TOTAL_KB=0
  return 0
}

sys_gauges_windows() {
  _pf_win_mem_total_once
  SYS_MEM_TOTAL_KB=$PITCREW_MEM_TOTAL_KB
  [ "${SYS_MEM_TOTAL_KB:-0}" -gt 0 ] || return 0
  local now; printf -v now '%(%s)T' -1
  if [ -z "$_PF_WIN_MEM_FREE_KB" ] ||
     [ $(( now - _PF_WIN_MEM_AT )) -ge "$PITCREW_WIN_MEM_INTERVAL" ]; then
    _PF_WIN_MEM_FREE_KB=$(_pf_win_mem_free_kb) || _PF_WIN_MEM_FREE_KB=""
    _PF_WIN_MEM_AT=$now
  fi
  local free=$_PF_WIN_MEM_FREE_KB
  case "$free" in ''|*[!0-9]*) return 0 ;; esac
  [ "$free" -le "$SYS_MEM_TOTAL_KB" ] || free=$SYS_MEM_TOTAL_KB
  SYS_MEM_USED_KB=$(( SYS_MEM_TOTAL_KB - free ))
}

[ "$PITCREW_OS" = windows ] && _pf_windows_init

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
