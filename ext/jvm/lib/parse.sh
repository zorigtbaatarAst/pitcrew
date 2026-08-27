#!/usr/bin/env bash
# ext/jvm/lib/parse.sh — captured JVM tool output on stdin, fields on stdout.
#
# Every function here is PURE: text in, numbers out, no forks of its own, no
# knowledge of which machine it is on. That is the whole reason this file is
# separate from probe.sh, and it is the same trick lib/00-platform.sh uses for
# `vm_stat` — the alternative is a parser nobody can verify without the exact
# JDK that produced the output.
#
# It matters more here than it looks. The plugin this tool replaces was written
# against one JDK's `GC.heap_info` and silently returned metaspace=0 from JDK 17
# onward, because the line it was reading had been REMOVED from that command.
# Nothing failed; the number that predicts an OOM kill just quietly got smaller.
# So: every shape below is pinned by a fixture in test/fixtures, captured from a
# real JDK, and a shape that is not recognised returns -1 rather than 0.
#
# ── the sentinel ────────────────────────────────────────────────────────────
#
#   -1  we could not measure this
#    0  we measured it and it is zero
#
# Callers must branch on that. A check that treats "unknown" as "zero" is how
# the bug above stayed invisible for two JDK releases.

# Memory sizes appear as 524288K, 30720KB, 100M, 2G or a bare number, sometimes
# with a trailing comma or bracket. Everything internal is KB.
_JVM_TOK2K='
function tok2k(s,   n, u, l) {
  gsub(/[,\]\[()]/, "", s)
  sub(/[Bb]$/, "", s)                      # 245764Kb -> 245764K
  if (s !~ /^[0-9]+[KkMmGg]?$/) return -1
  l = length(s); u = substr(s, l, 1)
  n = s + 0
  if (u == "M" || u == "m") return n * 1024
  if (u == "G" || u == "g") return n * 1024 * 1024
  return n
}'

# `jcmd <pid> GC.heap_info` on stdin -> "used_k committed_k reserved_k max_k"
#
# Four collectors spell this four ways and G1 changed its spelling mid-life, so
# this matches on the KEYWORDS rather than on the collector name:
#
#   JDK<=11 G1  garbage-first heap   total 2097152K, used 1048576K
#   JDK 17+ G1  garbage-first heap   total reserved 524288K, committed 30720K, used 11594K
#   Parallel    PSYoungGen total 305664K, used 100000K   (+ ParOldGen, summed)
#   Serial      def new generation total ..., used ...   (+ tenured generation)
#   ZGC         ZHeap  used 100M, capacity 1000M, max capacity 2048M
#   Shenandoah  2048M total, 1024M committed, 512M used  (value BEFORE keyword)
#
# The generational collectors print one line per generation, so values are
# SUMMED — taking the first match reports a two-generation heap as its young
# half. Metaspace is excluded here even where it appears (it is not heap, and it
# also reports a `used` field); VM.metaspace is its source.
jvm_parse_heap() {
  awk "$_JVM_TOK2K"'
    /^ *Metaspace/    { next }
    /^ *class space/  { next }
    # Percent-of-space lines ("eden space 262144K, 38% used [0x...") carry a
    # `used` whose value is an address, not a size. tok2k rejects those, so
    # they cost nothing — but the region line is noise either way.
    /^ *region size/  { next }
    /Shenandoah/      { shen = 1 }
    {
      if (shen) {
        # value-then-keyword: "2048M total, 1024M committed, 512M used".
        # The keyword carries the separator here ("total," not "total"), unlike
        # every other collector where the comma trails the VALUE and tok2k eats
        # it — so the key is stripped before it is compared, or only the last
        # field on the line ever matches.
        for (i = 2; i <= NF; i++) {
          v = tok2k($(i-1)); if (v < 0) continue
          k = $i; gsub(/[,:]/, "", k)
          # For Shenandoah "total" is the ceiling rather than a reservation:
          # it is the figure -Xmx set, so it belongs where the heap check
          # looks for a max.
          if (k == "total")     { M += v;  sawM = 1 }
          if (k == "committed") { C2 += v; sawC2 = 1 }
          if (k == "used")      { U += v;  sawU = 1 }
        }
        next
      }
      for (i = 1; i < NF; i++) {
        # Two-word keys first, or "max capacity 2048M" is read as "capacity".
        if ($i == "total" && $(i+1) == "reserved") {
          v = tok2k($(i+2)); if (v >= 0) { R += v; sawR = 1 } ; i += 2; continue }
        if ($i == "max" && $(i+1) == "capacity") {
          v = tok2k($(i+2)); if (v >= 0) { M += v; sawM = 1 } ; i += 2; continue }
        v = tok2k($(i+1)); if (v < 0) continue
        # Old G1/Parallel/Serial call the committed capacity "total"; the newer
        # spellings say "committed" or "capacity" outright. Prefer the explicit
        # word when both are present (JDK 17+ G1 prints total reserved AND
        # committed, and reading "total" there would report the RESERVED size
        # as committed — a 512M heap looking like it holds 512M when it holds 30M).
        if ($i == "total")     { C += v;  sawC = 1;  continue }
        if ($i == "committed") { C2 += v; sawC2 = 1; continue }
        if ($i == "capacity")  { C2 += v; sawC2 = 1; continue }
        if ($i == "used")      { U += v;  sawU = 1;  continue }
        if ($i == "reserved")  { R += v;  sawR = 1;  continue }
      }
    }
    END {
      printf "%d %d %d %d\n",
        (sawU  ? U  : -1),
        (sawC2 ? C2 : (sawC ? C : -1)),
        (sawR  ? R  : -1),
        (sawM  ? M  : -1)
    }'
}

# `jcmd <pid> VM.metaspace` on stdin -> "used_k committed_k reserved_k class_committed_k"
#
#   Metaspace        used 9460K, committed 9664K, reserved 1114112K
#    class space     used 1147K, committed 1280K, reserved 1048576K
#
# The same two lines used to appear in GC.heap_info and no longer do, which is
# the regression this file exists to stop repeating — so this parser is pointed
# at both, and a fixture pins each.
#
# Class space is a SUBSET of metaspace, reported separately because it is
# capped separately (CompressedClassSpaceSize). It is returned alongside rather
# than added, or it would be counted twice.
jvm_parse_metaspace() {
  awk "$_JVM_TOK2K"'
    /^ *class space/ {
      for (i = 1; i < NF; i++) {
        v = tok2k($(i+1)); if (v < 0) continue
        if ($i == "committed") { cc = v; sawcc = 1 }
      }
      next
    }
    /^ *Metaspace/ {
      for (i = 1; i < NF; i++) {
        v = tok2k($(i+1)); if (v < 0) continue
        if ($i == "used")      { u = v; sawu = 1 }
        if ($i == "committed") { c = v; sawc = 1 }
        if ($i == "reserved")  { r = v; sawr = 1 }
      }
    }
    END {
      printf "%d %d %d %d\n",
        (sawu ? u : -1), (sawc ? c : -1), (sawr ? r : -1), (sawcc ? cc : -1)
    }'
}

# `jcmd <pid> Compiler.codecache` on stdin -> "size_k used_k full_count"
#
#   CodeCache: size=245764Kb, used=3838Kb, max_used=5559Kb, free=241923Kb
#    total_blobs=1960, nmethods=1504, adapters=361, full_count=0
#
# With SegmentedCodeCache (the default since JDK 9) there are also three
# per-heap lines; the aggregate `CodeCache:` line is the one that matters and
# the segments would double-count it.
#
# `full_count` is the interesting field and the reason this parser exists: it
# counts the times the cache filled up. Past zero the JIT STOPS COMPILING and
# the service runs interpreted — an order of magnitude slower, with nothing in
# any log. Older JDKs do not print it, so absent is -1, never 0: "it has never
# filled" and "we cannot tell" must not render as the same claim.
jvm_parse_codecache() {
  awk "$_JVM_TOK2K"'
    # Fields are key=value here rather than key value, and the aggregate line
    # is the only one without a quoted heap name.
    /^ *CodeCache:/ {
      n = split($0, f, /[ ,]+/)
      for (i = 1; i <= n; i++) {
        if (split(f[i], kv, "=") != 2) continue
        v = tok2k(kv[2]); if (v < 0) continue
        if (kv[1] == "size") { sz = v; sawsz = 1 }
        if (kv[1] == "used") { us = v; sawus = 1 }
      }
      next
    }
    /full_count=/ {
      n = split($0, f, /[ ,]+/)
      for (i = 1; i <= n; i++) {
        if (split(f[i], kv, "=") != 2) continue
        if (kv[1] == "full_count" && kv[2] ~ /^[0-9]+$/) { fc = kv[2] + 0; sawfc = 1 }
      }
    }
    END {
      printf "%d %d %d\n",
        (sawsz ? sz : -1), (sawus ? us : -1), (sawfc ? fc : -1)
    }'
}

# `jcmd <pid> VM.flags` on stdin -> "NAME value" lines, one per flag.
#
#   -XX:MaxHeapSize=536870912   ->  MaxHeapSize 536870912
#   -XX:+UseG1GC                ->  UseG1GC 1
#   -XX:-THPStackMitigation     ->  THPStackMitigation 0
#
# Emitting every flag rather than grepping for one means the caller reads the
# list once instead of forking a jcmd per question, and a flag that is absent
# is absent from the output — which is how the caller tells "the JVM did not
# set this" from "it set it to zero".
jvm_parse_flags() {
  awk '
    {
      for (i = 1; i <= NF; i++) {
        t = $i
        if (t !~ /^-XX:/) continue
        sub(/^-XX:/, "", t)
        if (substr(t, 1, 1) == "+") { print substr(t, 2) " 1"; continue }
        if (substr(t, 1, 1) == "-") { print substr(t, 2) " 0"; continue }
        p = index(t, "=")
        if (p > 1) print substr(t, 1, p - 1) " " substr(t, p + 1)
      }
    }'
}

# Look one flag up out of jvm_parse_flags output on stdin. Prints nothing when
# the flag was not set, so `[ -n "$x" ]` is the "did the JVM say" test.
jvm_flag() { # $1 flag name
  awk -v want="$1" '$1 == want { print $2; exit }'
}

# `jcmd <pid> VM.native_memory summary` on stdin -> "Category reserved_k committed_k" lines.
#
#   Total: reserved=2021813KB, committed=145393KB
#   -                 Java Heap (reserved=524288KB, committed=30720KB)
#   -                    Thread (reserved=26712KB, committed=808KB)
#
# NMT is the only source that MEASURES the native side instead of estimating
# it, and it is off unless the JVM was started with -XX:NativeMemoryTracking.
# When it is on this replaces every estimate below it; when it is off the
# caller says so rather than presenting an estimate as a measurement.
#
# Category names contain spaces ("Java Heap", "GC Cardtable"), so the name is
# everything between the leading "-" and the "(", trimmed.
jvm_parse_nmt() {
  awk '
    function kb(s) { sub(/KB$/, "", s); return (s ~ /^[0-9]+$/) ? s + 0 : -1 }
    /^Total:/ {
      r = -1; c = -1
      n = split($0, f, /[ ,]+/)
      for (i = 1; i <= n; i++) {
        if (split(f[i], kv, "=") != 2) continue
        if (kv[1] == "reserved")  r = kb(kv[2])
        if (kv[1] == "committed") c = kb(kv[2])
      }
      print "Total " r " " c
      next
    }
    /^- +.*\(reserved=/ {
      p = index($0, "(")
      name = substr($0, 2, p - 2)
      gsub(/^ +| +$/, "", name)
      body = substr($0, p + 1)
      r = -1; c = -1
      n = split(body, f, /[ ,)]+/)
      for (i = 1; i <= n; i++) {
        if (split(f[i], kv, "=") != 2) continue
        if (kv[1] == "reserved")  r = kb(kv[2])
        if (kv[1] == "committed") c = kb(kv[2])
      }
      print name " " r " " c
    }'
}

# One NMT category out of jvm_parse_nmt output on stdin -> committed KB, or -1.
jvm_nmt_committed() { # $1 category name
  awk -v want="$1" '
    { name = $0
      sub(/ -?[0-9]+ -?[0-9]+$/, "", name)
      if (name == want) { print $NF; found = 1; exit } }
    END { if (!found) print -1 }'
}

# /proc/<pid>/status on stdin -> "rss_kb swap_kb threads"
#
# Linux only; probe.sh supplies the ps-based equivalent elsewhere. RSS is the
# number the OOM killer and the cgroup actually act on, which is why the whole
# tool reconciles against it rather than against the JVM's own totals.
jvm_parse_proc_status() {
  awk '
    $1 == "VmRSS:"   { rss = $2;  sawr = 1 }
    $1 == "VmSwap:"  { swp = $2;  saws = 1 }
    $1 == "Threads:" { thr = $2;  sawt = 1 }
    END {
      printf "%d %d %d\n",
        (sawr ? rss : -1), (saws ? swp : -1), (sawt ? thr : -1)
    }'
}

# A cgroup memory limit file on stdin -> bytes, or -1 for "no limit".
#
# cgroup v2 writes the literal "max"; v1 writes a number so large it means the
# same thing. Both must read as "unlimited" rather than as a cap of 8 exabytes
# that every JVM is comfortably under.
jvm_parse_cgroup_max() {
  awk '
    NR == 1 {
      if ($1 == "max") { print -1; done = 1; exit }
      if ($1 !~ /^[0-9]+$/) { print -1; done = 1; exit }
      # v1 unlimited is PAGE_COUNTER_MAX rounded to the page size; anything
      # above a petabyte is not a limit anyone configured.
      if ($1 + 0 >= 1125899906842624) { print -1; done = 1; exit }
      print $1
      done = 1
    }
    END { if (!done) print -1 }'
}

# `jcmd <pid> VM.flags -all` on stdin -> the same "NAME value" lines.
#
#   size_t MaxMetaspaceSize   = 18446744073709551615   {product} {default}
#     bool UseContainerSupport = true                  {product} {default}
#     intx ThreadStackSize     = 1024                  {pd product} {default}
#
# A DIFFERENT format from plain VM.flags, and worth the extra fork: the short
# form prints only flags that were set on the command line or by ergonomics, so
# every default reads as absent. Half the rules here are about a default —
# whether the JVM is container-aware, what a thread stack reserves — and
# "absent" would silently disable them.
#
# ── the overflow ────────────────────────────────────────────────────────────
#
# "unlimited" is spelled 18446744073709551615 (UINT64_MAX). That is wider than
# a signed 64-bit integer, so the SHELL does not reject it — it truncates it to
# 1844674407370955161 and carries on. A cap comparison against that number is
# always false, so an unlimited metaspace would read as a 1.6-exabyte ceiling
# nothing ever approaches, and the metaspace check would never fire.
#
# It is clamped to -1 HERE, in awk, before a digit of it can reach bash
# arithmetic. Same treatment as the cgroup "max" above, for the same reason.
jvm_parse_flags_all() {
  awk '
    {
      # <type> <NAME> = <value> {attrs}
      if (NF < 4 || $3 != "=") next
      name = $2; val = $4
      if (val == "true")  { print name " 1"; next }
      if (val == "false") { print name " 0"; next }
      # Doubles (MaxRAMPercentage = 25.000000) keep their point; the caller
      # compares them as text or truncates deliberately.
      if (val ~ /^[0-9]+\.[0-9]+$/) { print name " " val; next }
      if (val !~ /^[0-9]+$/) next
      # Anything at or above 2^62 is a sentinel, not a size. Clamping here is
      # what keeps it out of shell arithmetic.
      if (length(val) >= 19 || val + 0 >= 4611686018427387904) { print name " -1"; next }
      print name " " val
    }'
}
