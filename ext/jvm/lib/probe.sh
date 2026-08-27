#!/usr/bin/env bash
# ext/jvm/lib/probe.sh — the only file here that forks, and the only one that
# knows which OS it is running on.
#
# That split is deliberate and copied from pitcrew itself (constraint 5 in
# AGENTS.md): every native output is handed straight to a pure function in
# parse.sh, so the interpretation is testable on a machine that has never seen
# that JDK. Nothing in this file decides what a number MEANS.

PITCREW_JVM_TIMEOUT="${PITCREW_JVM_TIMEOUT:-5}"

# ── bounded execution ───────────────────────────────────────────────────────
#
# jcmd attaches to a live JVM and waits for it to reach a safepoint. A JVM in a
# long full GC, hitting swap, or stopped at a breakpoint will not answer — and
# jcmd waits forever, not for a while. Unbounded, one sick JVM hangs
# `pitcrew diagnose` (and the desktop app behind it) with no way out.
#
# There is no portable `timeout`: it is GNU coreutils, absent on a stock macOS,
# and AGENTS.md forbids assuming it. So this is the bound, in shell.
#
# Fractional sleep is not in POSIX but IS in GNU, BSD/macOS and MSYS sleep, and
# a whole-second poll would make the common case (a healthy JVM answering in
# ~40ms) cost a second per command per JVM.
_jvm_run() { # $@ = command -> its stdout; 1 on failure OR timeout
  local out pid rc ticks=0 limit=$(( PITCREW_JVM_TIMEOUT * 10 ))
  out=$(mktemp) || return 1
  "$@" >"$out" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      # TERM first so the JVM side of the attach handshake gets to clean up;
      # KILL only if it is genuinely wedged.
      kill -TERM "$pid" 2>/dev/null
      sleep 0.3
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$out"
      return 1
    fi
    sleep 0.1
    ticks=$(( ticks + 1 ))
  done
  wait "$pid"; rc=$?
  cat "$out"
  rm -f "$out"
  return $rc
}

# jcmd prints the pid on its own first line before the answer. Every parser
# tolerates it, but dropping it here keeps the fixtures honest — what is
# captured to test/fixtures is what the parsers actually receive.
_jvm_cmd() { # $1 pid, rest = jcmd arguments
  local pid=$1; shift
  _jvm_run jcmd "$pid" "$@" | tail -n +2
}

# ── discovery ───────────────────────────────────────────────────────────────
#
# `jps` rather than `pgrep java`, and the difference is not cosmetic: pgrep -f
# matches the whole command line, so it happily returns the shell that is
# RUNNING the search, and any editor with the word java in its arguments. jps
# reads the JVM perf files, so what it returns is by construction a JVM.
#
# It only sees JVMs owned by this user, which is the right default for a
# developer tool and is stated in the README rather than worked around.
jvm_discover() { # -> "pid<TAB>label" per JVM
  command -v jps >/dev/null 2>&1 || { _jvm_discover_ps; return $?; }
  _jvm_run jps -l | awk '
    NF == 0 { next }
    $1 !~ /^[0-9]+$/ { next }
    # jps reports itself. Nobody wants to diagnose the tool doing the asking.
    $2 ~ /sun\.tools\.jps\.Jps/ { next }
    {
      name = (NF >= 2 ? $2 : "")
      if (name == "") { print $1 "\t" "java[" $1 "]"; next }
      # A main class is fully qualified and a jar is a path; both are far too
      # long for a table column, and the tail is the identifying part of each.
      n = split(name, seg, /[\/.]/)
      short = seg[n]
      if (short == "jar" && n >= 2) short = seg[n-1]
      if (short == "") short = name
      print $1 "\t" short
    }'
}

# Where jps is missing (a JRE-only install, or a distro that splits the JDK
# tools out) fall back to the process table. Matched on the EXECUTABLE name,
# never the full command line, for the reason above.
_jvm_discover_ps() {
  ps -e -o pid=,comm= 2>/dev/null | awk '
    { cmd = $2
      n = split(cmd, seg, "/")
      if (seg[n] != "java") next
      print $1 "\t" "java[" $1 "]" }'
}

# ── the memory cap this process actually runs under ─────────────────────────
#
# The cap is the whole point of the cap check, and it has two possible sources.
# pitcrew passes its own (it launched the process under a systemd scope); on a
# bare box or in a container it has to be read from the cgroup.
#
# Both cgroup versions are handled. v2 is one unified path in /proc/PID/cgroup;
# v1 is a per-controller line. Neither existing means no cap, which is -1 and
# not 0 — a cap of zero would make every JVM instantly over it.
jvm_cgroup_cap() { # $1 pid -> bytes on stdout, -1 when unlimited or unknown
  local pid=$1 path file
  [ -r "/proc/$pid/cgroup" ] || { printf '%s\n' -1; return 0; }

  # v2: a single "0::/the/path" line.
  path=$(awk -F: '$1 == "0" && $2 == "" { print $3; exit }' "/proc/$pid/cgroup" 2>/dev/null)
  if [ -n "$path" ]; then
    file="/sys/fs/cgroup${path}/memory.max"
    if [ -r "$file" ]; then jvm_parse_cgroup_max < "$file"; return 0; fi
  fi

  # v1: the memory controller has its own line and its own mount.
  path=$(awk -F: '$2 ~ /(^|,)memory(,|$)/ { print $3; exit }' "/proc/$pid/cgroup" 2>/dev/null)
  if [ -n "$path" ]; then
    file="/sys/fs/cgroup/memory${path}/memory.limit_in_bytes"
    if [ -r "$file" ]; then jvm_parse_cgroup_max < "$file"; return 0; fi
  fi
  printf '%s\n' -1
  return 0
}

# ── resident size, threads, uptime ──────────────────────────────────────────
#
# Linux answers all three out of /proc with no fork at all. Everything else
# pays one ps. This is the only place in the tool that branches on the OS.
_jvm_proc_facts() { # $1 pid -> sets JVMF_RSS_K JVMF_SWAP_K JVMF_THREADS
  local pid=$1
  JVMF_RSS_K=-1; JVMF_SWAP_K=-1; JVMF_THREADS=-1
  if [ -r "/proc/$pid/status" ]; then
    read -r JVMF_RSS_K JVMF_SWAP_K JVMF_THREADS \
      < <(jvm_parse_proc_status < "/proc/$pid/status")
    return 0
  fi
  # macOS / BSD: rss is in KB here too. No swap-per-process figure exists, and
  # reporting 0 would be a claim; -1 says it was not measured.
  local rss
  rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$rss" in ''|*[!0-9]*) rss=-1 ;; esac
  JVMF_RSS_K=$rss
  return 0
}

# Seconds since the process started, or -1.
_jvm_uptime() { # $1 pid -> seconds on stdout
  local pid=$1 start clk btime now
  if [ -r "/proc/$pid/stat" ] && [ -r /proc/uptime ]; then
    # Field 22 is starttime in clock ticks since boot. The comm field (2) can
    # contain spaces and parentheses, so everything is taken AFTER the last ')'
    # rather than by field number from the start.
    start=$(awk '{ p = index($0, ")"); for (i = length($0); i > 0; i--) if (substr($0, i, 1) == ")") { p = i; break }
                  n = split(substr($0, p + 1), f, " "); print f[20] }' "/proc/$pid/stat" 2>/dev/null)
    case "$start" in ''|*[!0-9]*) printf '%s\n' -1; return 0 ;; esac
    clk=$(getconf CLK_TCK 2>/dev/null); case "$clk" in ''|*[!0-9]*) clk=100 ;; esac
    now=$(awk '{ print int($1) }' /proc/uptime 2>/dev/null)
    case "$now" in ''|*[!0-9]*) printf '%s\n' -1; return 0 ;; esac
    printf '%s\n' $(( now - start / clk ))
    return 0
  fi
  # [[dd-]hh:]mm:ss from ps. `etimes` would be one number but is procps-only.
  local et
  et=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -n "$et" ] || { printf '%s\n' -1; return 0; }
  printf '%s\n' "$et" | awk -F'[-:]' '
    { if (NF == 4)      print (($1 * 24 + $2) * 60 + $3) * 60 + $4
      else if (NF == 3) print ($1 * 60 + $2) * 60 + $3
      else if (NF == 2) print $1 * 60 + $2
      else print -1 }'
}

# ── one JVM, every fact ─────────────────────────────────────────────────────
#
# Six forks per JVM at most, all bounded, all only on the `slow` path. Fills
# JVMF_* and nothing else; every judgement about the numbers is in rules.sh.
jvm_probe() { # $1 pid, [$2 label], [$3 cap_bytes], [$4 cap_source]
  local pid=$1 label=${2:-} cap=${3:--1} capsrc=${4:-}

  JVMF_PID=$pid
  JVMF_LABEL=${label:-"java[$pid]"}
  JVMF_HEAP_USED_K=-1; JVMF_HEAP_COMMIT_K=-1; JVMF_HEAP_RESERVED_K=-1; JVMF_HEAP_MAX_K=-1
  JVMF_META_USED_K=-1; JVMF_META_COMMIT_K=-1; JVMF_META_MAX_K=-1; JVMF_CLASS_COMMIT_K=-1
  JVMF_CC_SIZE_K=-1; JVMF_CC_USED_K=-1; JVMF_CC_FULL=-1
  JVMF_STACK_K=-1; JVMF_CONTAINER=-1; JVMF_RAMPCT=""
  JVMF_NMT=0; JVMF_NMT_TOTAL_K=-1; JVMF_NMT_HEAP_K=-1; JVMF_NMT_THREAD_K=-1
  JVMF_NMT_CODE_K=-1; JVMF_NMT_CLASS_K=-1; JVMF_NMT_GC_K=-1
  JVMF_UPTIME=-1; JVMF_ATTACHED=0
  JVMF_CAP_SOURCE=$capsrc

  _jvm_proc_facts "$pid"
  JVMF_UPTIME=$(_jvm_uptime "$pid")

  # A cap handed in by a supervisor wins: it is the ceiling that will actually
  # be enforced on this process, and it can be tighter than the cgroup one.
  if jvm_known "$cap" && [ "$cap" -gt 0 ] 2>/dev/null; then
    JVMF_CAP_B=$cap
    [ -n "$JVMF_CAP_SOURCE" ] || JVMF_CAP_SOURCE=supplied
  else
    JVMF_CAP_B=$(jvm_cgroup_cap "$pid")
    [ "$JVMF_CAP_B" -gt 0 ] 2>/dev/null && JVMF_CAP_SOURCE=cgroup || JVMF_CAP_SOURCE=none
  fi

  command -v jcmd >/dev/null 2>&1 || return 0

  local heap meta cc flags nmt
  heap=$(_jvm_cmd "$pid" GC.heap_info) || heap=""
  [ -n "$heap" ] && {
    JVMF_ATTACHED=1
    read -r JVMF_HEAP_USED_K JVMF_HEAP_COMMIT_K JVMF_HEAP_RESERVED_K JVMF_HEAP_MAX_K \
      < <(printf '%s\n' "$heap" | jvm_parse_heap)
  }

  # Metaspace moved OUT of GC.heap_info after JDK 11 and into its own command.
  # Both are read, newest source first, because a tool that only knew one of
  # them is exactly the bug this replaces.
  meta=$(_jvm_cmd "$pid" VM.metaspace) || meta=""
  [ -n "$meta" ] || meta=$heap
  [ -n "$meta" ] && read -r JVMF_META_USED_K JVMF_META_COMMIT_K _ JVMF_CLASS_COMMIT_K \
    < <(printf '%s\n' "$meta" | jvm_parse_metaspace)

  cc=$(_jvm_cmd "$pid" Compiler.codecache) || cc=""
  [ -n "$cc" ] && read -r JVMF_CC_SIZE_K JVMF_CC_USED_K JVMF_CC_FULL \
    < <(printf '%s\n' "$cc" | jvm_parse_codecache)

  # -all, not the short form: half the rules are about a DEFAULT, and the short
  # form prints only what was set explicitly or by ergonomics.
  flags=$(_jvm_cmd "$pid" VM.flags -all) || flags=""
  if [ -n "$flags" ]; then
    local parsed v
    parsed=$(printf '%s\n' "$flags" | jvm_parse_flags_all)
    v=$(printf '%s\n' "$parsed" | jvm_flag MaxHeapSize)
    jvm_known "${v:--1}" && [ "${v:-0}" -gt 0 ] 2>/dev/null && JVMF_HEAP_MAX_K=$(( v / 1024 ))
    v=$(printf '%s\n' "$parsed" | jvm_flag MaxMetaspaceSize)
    jvm_known "${v:--1}" && [ "${v:-0}" -gt 0 ] 2>/dev/null && JVMF_META_MAX_K=$(( v / 1024 ))
    # ThreadStackSize is already in KB, unlike every other size flag.
    v=$(printf '%s\n' "$parsed" | jvm_flag ThreadStackSize)
    jvm_known "${v:--1}" && [ "${v:-0}" -gt 0 ] 2>/dev/null && JVMF_STACK_K=$v
    v=$(printf '%s\n' "$parsed" | jvm_flag UseContainerSupport)
    case "$v" in 0|1) JVMF_CONTAINER=$v ;; esac
    JVMF_RAMPCT=$(printf '%s\n' "$parsed" | jvm_flag MaxRAMPercentage)
  fi

  # NMT is off unless the JVM was started with it, and when it is off this
  # command answers with a refusal rather than an error — so presence of the
  # header, not the exit status, is what says the data is real.
  nmt=$(_jvm_cmd "$pid" VM.native_memory summary) || nmt=""
  case "$nmt" in
    *"Native Memory Tracking:"*)
      JVMF_NMT=1
      local cats
      cats=$(printf '%s\n' "$nmt" | jvm_parse_nmt)
      JVMF_NMT_TOTAL_K=$(printf '%s\n' "$cats" | jvm_nmt_committed "Total")
      JVMF_NMT_HEAP_K=$(printf '%s\n' "$cats" | jvm_nmt_committed "Java Heap")
      JVMF_NMT_THREAD_K=$(printf '%s\n' "$cats" | jvm_nmt_committed "Thread")
      JVMF_NMT_CODE_K=$(printf '%s\n' "$cats" | jvm_nmt_committed "Code")
      JVMF_NMT_CLASS_K=$(printf '%s\n' "$cats" | jvm_nmt_committed "Class")
      JVMF_NMT_GC_K=$(printf '%s\n' "$cats" | jvm_nmt_committed "GC")
      ;;
  esac
  return 0
}
