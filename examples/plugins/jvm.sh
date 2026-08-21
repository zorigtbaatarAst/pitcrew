#!/usr/bin/env bash
# examples/plugins/jvm.sh — a pitcrew plugin, and the worked example of one.
#
# Install:  cp examples/plugins/jvm.sh ~/.config/pitcrew/plugins/
# Check it: pitcrew plugins
# Use it:   pitcrew diagnose
#
# ── what it is for ──────────────────────────────────────────────────────────
#
# pitcrew knows something no JVM knows: the RAM cap it launched that JVM under.
# The JVM knows something pitcrew does not: what -Xmx it settled on. Neither
# half is interesting alone, and together they catch the single most confusing
# failure in a containerised or cgroup-capped dev stack —
#
#     the heap is allowed to grow past the cap, so the process is killed by the
#     kernel long before the JVM would ever have run a full GC
#
# which presents as "my service just disappears under load, with nothing in the
# log". No stack trace, because there was no exception; the process was shot.
#
# ── what it demonstrates ────────────────────────────────────────────────────
#
# This file touches nothing private. It reads the same SNAP_* arrays every
# built-in check reads, calls the same `diag_add`, and registers through the
# same `diag_register`. It is marked `slow`, so it may fork — and is therefore
# never run from the dashboard's frame loop, only by `pitcrew diagnose`.
#
# The parsers are separate, pure functions taking text on stdin, so they can be
# tested against captured output on a machine with no JVM on it at all. That is
# the same trick lib/00-platform.sh uses for `vm_stat`, and for the same
# reason: the alternative is a check nobody can verify.

# How much non-heap a JVM needs on top of -Xmx before the cap starts to bite:
# thread stacks, code cache, GC structures, direct buffers, the JVM itself.
# Metaspace is measured separately and added to this when it can be read.
PITCREW_JVM_NATIVE_MB="${PITCREW_JVM_NATIVE_MB:-320}"
PITCREW_JVM_HEAP_WARN_PCT="${PITCREW_JVM_HEAP_WARN_PCT:-90}"

# `jcmd <pid> GC.heap_info` on stdin → "usedK metaspaceCommittedK" on stdout.
#
#   garbage-first heap   total 2097152K, used 1048576K [0x...
#   Metaspace       used 45678K, committed 46000K, reserved 1114112K
#
# The collector name differs (garbage-first / PSYoungGen / def new generation), so
# match on the fields rather than on which GC is in use. Everything is printed
# in K by every JVM that implements this command.
_jvm_heap_parse() {
  awk '
    # Metaspace and class space are NOT heap. They also print a "used" field,
    # so they have to be taken out of the running before the generic rule below
    # sees them — otherwise a service reads as using 45M more heap than it is.
    /^ *Metaspace/ {
      for (i = 1; i <= NF; i++)
        if ($i == "committed" && $(i+1) ~ /^[0-9]+K,?/) { m = $(i+1); gsub(/[K,]/, "", m); meta = m }
      next
    }
    /^ *class space/ { next }
    # Everything else that reports "used NNNNNK" is a heap region. G1 prints one
    # such line; ParallelGC prints PSYoungGen and ParOldGen separately and
    # SerialGC prints def new / tenured — so they are summed rather than taken
    # from whichever line happened to match first.
    /used [0-9]+K/ {
      for (i = 1; i <= NF; i++)
        if ($i == "used" && $(i+1) ~ /^[0-9]+K,?/) { u = $(i+1); gsub(/[K,]/, "", u); used += u }
    }
    END { printf "%d %d", used, meta }'
}

# `jcmd <pid> VM.flags` on stdin → MaxHeapSize in bytes, or 0.
#   -XX:MaxHeapSize=2147483648
_jvm_xmx_parse() {
  awk '{ for (i = 1; i <= NF; i++)
           if ($i ~ /^-XX:MaxHeapSize=[0-9]+$/) { sub(/.*=/, "", $i); print $i; exit } }
       END { }' | head -1
}

# The java processes inside one component's tree. A gradle bootRun is a gradle
# wrapper that forks a daemon that forks the application, so the pid pitcrew
# launched is almost never the JVM you care about.
_jvm_pids() { # $1 comp → the java pids in its tree, one per line
  local p
  for p in ${SNAP_PIDS[$1]:-}; do
    case "${SNAP_PROC_CMD[$p]:-}" in java|*/java) printf '%s\n' "$p" ;; esac
  done
}

jvm_check() {
  command -v jcmd >/dev/null 2>&1 || return 0

  local c pid heap meta xmx used_pct cap need
  for c in "${PITCREW_COMPS[@]}"; do
    [ "${SNAP_STATE[$c]:-}" = up ] || continue
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue

      # A JVM that is busy, or refusing attach, must produce no finding at all.
      # A plugin that guesses when it cannot measure is worse than one that is
      # quiet: every check here competes for the one line someone will read.
      local info flags
      info=$(jcmd "$pid" GC.heap_info 2>/dev/null) || continue
      read -r heap meta < <(printf '%s\n' "$info" | _jvm_heap_parse)
      [ "${heap:-0}" -gt 0 ] 2>/dev/null || continue

      flags=$(jcmd "$pid" VM.flags 2>/dev/null) || flags=""
      xmx=$(printf '%s\n' "$flags" | _jvm_xmx_parse)
      case "${xmx:-}" in ''|*[!0-9]*) xmx=0 ;; esac

      # ── the heap against its own ceiling ──
      if [ "$xmx" -gt 0 ]; then
        used_pct=$(( heap * 1024 * 100 / xmx ))
        if [ "$used_pct" -ge "$PITCREW_JVM_HEAP_WARN_PCT" ]; then
          human $(( heap * 1024 )); local uh=$HUMAN
          human "$xmx";             local xh=$HUMAN
          diag_add warn jvm-heap "$c is at ${used_pct}% of its JVM heap" \
            "$uh of $xh — past here it spends more time collecting than running" \
            "pitcrew logs $c" "$c"
        fi
      fi

      # ── the heap against the cap PITCREW set ──
      # This is the one only pitcrew can see, and the reason this plugin exists.
      cap=${COMP_MAX_B[$c]:-0}
      if [ "$xmx" -gt 0 ] && [ "$cap" -gt 0 ]; then
        need=$(( xmx + meta * 1024 + PITCREW_JVM_NATIVE_MB * 1024 * 1024 ))
        if [ "$need" -gt "$cap" ]; then
          human "$need"; local nh=$HUMAN
          human "$cap";  local ch=$HUMAN
          human "$xmx";  local xh=$HUMAN
          diag_add crit jvm-cap "$c can outgrow its RAM cap before its heap fills" \
            "-Xmx $xh plus native needs about $nh, the cap is $ch — the kernel kills it first, with no stack trace" \
            "pitcrew limit $c $nh" "$c"
        fi
      fi
    done < <(_jvm_pids "$c")
  done
  return 0
}

# `slow`, because it forks a jcmd per JVM. That keeps it out of the dashboard's
# frame loop entirely — it runs when someone asks `pitcrew diagnose`.
diag_register jvm_check slow
