#!/usr/bin/env bash
# lib/00-platform.sh — the only file that knows which OS it's running on.
# Linux is the primary, fully-tested target. macOS gets the same features
# through portable (ps/lsof/vm_stat) equivalents of the Linux-only bits
# (systemd cgroups, /proc). Native Windows isn't supported — run inside
# WSL2, where pitcrew sees a normal Linux userland (including systemd on
# modern WSL2 distros) and needs nothing special.

case "$(uname -s)" in
  Linux)  PITCREW_OS=linux ;;
  Darwin) PITCREW_OS=macos ;;
  *)      PITCREW_OS=other ;;
esac

HAS_SYSTEMD=0
if [ "$PITCREW_OS" = linux ] && command -v systemctl >/dev/null 2>&1 \
   && systemctl --user status >/dev/null 2>&1; then
  HAS_SYSTEMD=1
fi

# ── port → pid (lsof is the portable choice; ss as a Linux fallback) ────────
port_pid() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1
  elif command -v ss >/dev/null 2>&1; then
    ss -tlnpH "sport = :$1" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1
  fi
}

# ── process tree helpers (used for RAM/CPU meters and for killing a whole
#    process group when there's no systemd scope to stop cleanly) ──────────
descendant_pids() { # $1 pid → that pid + every descendant, one per line
  local pid=$1 kids k
  echo "$pid"
  kids=$(pgrep -P "$pid" 2>/dev/null) || return 0
  for k in $kids; do descendant_pids "$k"; done
}

# sets PSTREE_RSS_KB / PSTREE_CPU_PCT for $1's whole process tree, or empty
# strings if the root pid is gone. Best-effort: %cpu here is ps's own
# lifetime-average figure, not a live delta — good enough for a glance, not
# a profiler.
proc_tree_stats() {
  local pid=$1 pids csv
  PSTREE_RSS_KB=""; PSTREE_CPU_PCT=""
  kill -0 "$pid" 2>/dev/null || return 0
  pids=$(descendant_pids "$pid" | tr '\n' ',' | sed 's/,$//')
  [ -n "$pids" ] || return 0
  csv=$(ps -o rss=,pcpu= -p "$pids" 2>/dev/null)
  [ -n "$csv" ] || return 0
  PSTREE_RSS_KB=$(awk '{sum+=$1} END{print sum+0}' <<< "$csv")
  PSTREE_CPU_PCT=$(awk '{sum+=$2} END{printf "%.0f", sum}' <<< "$csv")
}

kill_tree() { # $1 pid — TERM then, after a grace period, KILL, whole tree
  local pid=$1 t=0 pids
  kill -0 "$pid" 2>/dev/null || return 0
  pids=$(descendant_pids "$pid")
  kill -TERM $pids 2>/dev/null
  while kill -0 "$pid" 2>/dev/null && [ $t -lt 8 ]; do sleep 1; t=$((t + 1)); done
  kill -0 "$pid" 2>/dev/null && kill -KILL $pids 2>/dev/null
}

# ── system-wide CPU/RAM gauges for the live watch dashboard ────────────────
# Sets SYS_CPU_PCT (0-100 int), SYS_MEM_USED_KB, SYS_MEM_TOTAL_KB. Never
# fails hard — an unreadable gauge just renders as "—", never crashes the
# dashboard.
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

sys_gauges_macos() {
  local line pagesize free spec
  SYS_MEM_TOTAL_KB=$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024))
  line=$(vm_stat 2>/dev/null)
  pagesize=$(grep -oE 'page size of [0-9]+' <<< "$line" | grep -oE '[0-9]+')
  free=$(awk '/Pages free/{gsub("\\.","",$3); print $3}' <<< "$line")
  spec=$(awk '/Pages speculative/{gsub("\\.","",$3); print $3}' <<< "$line")
  if [ -n "$pagesize" ] && [ -n "$free" ] && [ "$SYS_MEM_TOTAL_KB" -gt 0 ]; then
    local avail_kb=$(( (free + spec) * pagesize / 1024 ))
    SYS_MEM_USED_KB=$((SYS_MEM_TOTAL_KB - avail_kb))
  fi
  local top_line user sys
  top_line=$(top -l 1 -n 0 2>/dev/null | grep "CPU usage")
  user=$(grep -oE '[0-9.]+% user' <<< "$top_line" | grep -oE '[0-9.]+')
  sys=$(grep -oE '[0-9.]+% sys' <<< "$top_line" | grep -oE '[0-9.]+')
  [ -n "$user" ] && [ -n "$sys" ] && SYS_CPU_PCT=$(awk -v u="$user" -v s="$sys" 'BEGIN{printf "%.0f", u+s}')
}

sys_gauges() {
  SYS_CPU_PCT=${SYS_CPU_PCT:-0}; SYS_MEM_USED_KB=""; SYS_MEM_TOTAL_KB=""
  SYS_P_TOTAL=${SYS_P_TOTAL:-0}; SYS_P_IDLE=${SYS_P_IDLE:-0}
  case "$PITCREW_OS" in
    linux) sys_gauges_linux 2>/dev/null ;;
    macos) sys_gauges_macos 2>/dev/null ;;
  esac
}

# ── which collector the dashboard uses (see lib/03a-snapshot.sh) ────────────
# "proc" reads everything out of /proc with bash builtins — zero forks per
# frame. "ps" is the portable fallback: one `ps` + one port listing per frame.
# The fallback is also what Linux gets if /proc is somehow unreadable, so the
# tool degrades instead of breaking.
if [ "$PITCREW_OS" = linux ] && [ -r /proc/net/tcp ] && [ -r /proc/self/stat ]; then
  PITCREW_COLLECTOR=proc
else
  PITCREW_COLLECTOR=ps
fi
