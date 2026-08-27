#!/usr/bin/env bash
# ext/jvm/lib/rules.sh — measured facts in, findings out. Pure: no forks, no
# jcmd, no /proc. Everything it reads was put in JVMF_* by probe.sh, which
# means a rule can be tested by assigning those variables directly, with no JVM
# anywhere near the machine.
#
# Findings land in JVMR_* parallel arrays with exactly the shape pitcrew's
# DIAG_* arrays use, so the plugin adapter is a copy rather than a translation.
#
# ── the one honesty rule everything here obeys ──────────────────────────────
#
# A fact that could not be measured is -1, never 0, and every rule guards with
# jvm_known before using it. The plugin this replaces did not, and so read a
# JDK 17 metaspace it could not find as "0 KB of metaspace" — which made the
# OOM prediction smaller, in the safe-looking direction, silently.

PITCREW_JVM_HEAP_WARN_PCT="${PITCREW_JVM_HEAP_WARN_PCT:-90}"
PITCREW_JVM_META_WARN_PCT="${PITCREW_JVM_META_WARN_PCT:-90}"
PITCREW_JVM_CC_WARN_PCT="${PITCREW_JVM_CC_WARN_PCT:-90}"
PITCREW_JVM_STACK_SHARE_PCT="${PITCREW_JVM_STACK_SHARE_PCT:-20}"
PITCREW_JVM_UNACCOUNTED_PCT="${PITCREW_JVM_UNACCOUNTED_PCT:-150}"
PITCREW_JVM_UNACCOUNTED_MB="${PITCREW_JVM_UNACCOUNTED_MB:-256}"

# What the JVM needs beyond heap, metaspace and code cache: GC structures,
# thread stacks, direct buffers, malloc arenas, the JVM binary itself. Used
# ONLY when NMT is off and the real figure cannot be read.
#
# It is called a FLOOR rather than an estimate, and that word carries the whole
# design of the cap check below. See jvm_account.
PITCREW_JVM_NATIVE_FLOOR_MB="${PITCREW_JVM_NATIVE_FLOOR_MB:-128}"

JVMR_SEV=(); JVMR_ID=(); JVMR_TITLE=(); JVMR_DETAIL=(); JVMR_FIX=(); JVMR_SCOPE=()
JVMR_N=0; JVMR_CRIT=0; JVMR_WARN=0; JVMR_INFO=0

jvm_finding_reset() {
  JVMR_SEV=(); JVMR_ID=(); JVMR_TITLE=(); JVMR_DETAIL=(); JVMR_FIX=(); JVMR_SCOPE=()
  JVMR_N=0; JVMR_CRIT=0; JVMR_WARN=0; JVMR_INFO=0
}

jvm_add() { # $1 sev, $2 id, $3 title, $4 detail, [$5 fix], [$6 scope]
  JVMR_SEV+=("$1"); JVMR_ID+=("$2"); JVMR_TITLE+=("$3"); JVMR_DETAIL+=("$4")
  JVMR_FIX+=("${5:-}"); JVMR_SCOPE+=("${6:-}")
  case "$1" in
    crit) JVMR_CRIT=$((JVMR_CRIT + 1)) ;;
    warn) JVMR_WARN=$((JVMR_WARN + 1)) ;;
    *)    JVMR_INFO=$((JVMR_INFO + 1)) ;;
  esac
  JVMR_N=$((JVMR_N + 1))
}

# ── the accounting ──────────────────────────────────────────────────────────
#
# Reconcile what the OS sees (RSS) against what the JVM admits to. Sets JVMA_*.
#
# ── why "committed" and "resident" are not the same number ──
#
# NMT reports COMMITTED address space; /proc reports RESIDENT pages. A JVM that
# has committed 110M may have touched only 41M of it, so accounted-minus-RSS is
# routinely NEGATIVE and that is not a finding — it is the normal state of a
# process that has reserved room it has not used yet. Only the other direction
# means anything, and jvm_check_unaccounted fires on that direction alone.
#
# ── why the non-heap side is a FLOOR ──
#
# With NMT on, non-heap is measured and JVMA_MEASURED is 1.
#
# With NMT off, metaspace and code cache are still real readings, but GC
# structures, thread stacks and direct buffers cannot be seen at all — so what
# is added for them is a deliberate UNDER-estimate, not a guess at the truth.
# That makes JVMA_NEED_K a LOWER BOUND on what this JVM can grow to.
#
# A lower bound is the useful direction: when it already exceeds the cap, the
# conclusion is certain, because the real figure can only be larger. The cost
# is silence in the marginal cases, which is the right way round for a check
# that tells someone their service is going to be killed.
JVMA_NONHEAP_K=-1
JVMA_STACKS_K=-1
JVMA_ACCOUNTED_K=-1
JVMA_UNACCOUNTED_K=-1
# Unaccounted is the one derived figure that can legitimately be NEGATIVE — a
# JVM routinely commits more than it has touched — so -1 cannot double as its
# "not measured" sentinel the way it does everywhere else. It gets a flag.
JVMA_UNACCOUNTED_KNOWN=0
JVMA_NEED_K=-1
JVMA_MEASURED=0

jvm_account() {
  JVMA_NONHEAP_K=-1; JVMA_STACKS_K=-1; JVMA_ACCOUNTED_K=-1
  JVMA_UNACCOUNTED_K=-1; JVMA_UNACCOUNTED_KNOWN=0; JVMA_NEED_K=-1; JVMA_MEASURED=0

  if jvm_known "${JVMF_NMT_TOTAL_K:--1}" && [ "${JVMF_NMT:-0}" = 1 ] \
     && jvm_known "${JVMF_NMT_HEAP_K:--1}"; then
    JVMA_NONHEAP_K=$(( JVMF_NMT_TOTAL_K - JVMF_NMT_HEAP_K ))
    [ "$JVMA_NONHEAP_K" -ge 0 ] || JVMA_NONHEAP_K=0
    JVMA_MEASURED=1
    jvm_known "${JVMF_NMT_THREAD_K:--1}" && JVMA_STACKS_K=$JVMF_NMT_THREAD_K
  else
    # Sum what IS readable, then add the floor for what is not.
    local sum=0 any=0
    jvm_known "${JVMF_META_COMMIT_K:--1}" && { sum=$(( sum + JVMF_META_COMMIT_K )); any=1; }
    jvm_known "${JVMF_CC_USED_K:--1}"     && { sum=$(( sum + JVMF_CC_USED_K )); any=1; }
    if [ "$any" = 1 ]; then
      JVMA_NONHEAP_K=$(( sum + PITCREW_JVM_NATIVE_FLOOR_MB * 1024 ))
    fi
    # Thread stacks are RESERVED per thread and commit lazily, so this is an
    # address-space figure, not a resident one. It is reported as such and kept
    # out of the accounting total, where it would overstate RSS several-fold.
    if jvm_known "${JVMF_THREADS:--1}" && jvm_known "${JVMF_STACK_K:--1}"; then
      JVMA_STACKS_K=$(( JVMF_THREADS * JVMF_STACK_K ))
    fi
  fi

  if jvm_known "${JVMF_HEAP_COMMIT_K:--1}" && jvm_known "$JVMA_NONHEAP_K"; then
    JVMA_ACCOUNTED_K=$(( JVMF_HEAP_COMMIT_K + JVMA_NONHEAP_K ))
    if jvm_known "${JVMF_RSS_K:--1}"; then
      JVMA_UNACCOUNTED_K=$(( JVMF_RSS_K - JVMA_ACCOUNTED_K ))
      JVMA_UNACCOUNTED_KNOWN=1
    fi
  fi

  # What it can grow to: the heap is allowed to reach its max, and the non-heap
  # side is what it is right now.
  if jvm_known "${JVMF_HEAP_MAX_K:--1}" && jvm_known "$JVMA_NONHEAP_K"; then
    JVMA_NEED_K=$(( JVMF_HEAP_MAX_K + JVMA_NONHEAP_K ))
  fi
  return 0
}

# ── the checks ──────────────────────────────────────────────────────────────

# The one only a supervisor can see, and the reason this tool exists.
#
# pitcrew (or the container runtime) knows the ceiling the process runs under.
# The JVM knows the -Xmx it settled on. Neither half is interesting alone;
# together they catch a process that is killed by the kernel long before its
# heap would ever have filled — which presents as "the service just disappears
# under load, with nothing in the log", because there was no exception.
jvm_check_cap() {
  local cap_k
  jvm_known "${JVMF_CAP_B:--1}" || return 0
  [ "${JVMF_CAP_B}" -gt 0 ] || return 0
  jvm_known "$JVMA_NEED_K" || return 0
  cap_k=$(( JVMF_CAP_B / 1024 ))
  [ "$JVMA_NEED_K" -gt "$cap_k" ] || return 0

  local nh xh nd cd title detail fix=""
  jvm_human "$JVMA_NONHEAP_K";      nh=$JVM_H
  jvm_human "${JVMF_HEAP_MAX_K}";   xh=$JVM_H
  # These two appear in the same sentence and the claim IS the gap between
  # them, so they must not round to the same string.
  jvm_human2 "$JVMA_NEED_K" "$cap_k"; nd=$JVM_H1; cd=$JVM_H2

  printf -v title '%s can outgrow its memory cap before its heap fills' "${JVMF_LABEL}"
  # The wording changes with the evidence: "at least" is the honest verb when
  # the non-heap side is a floor rather than a measurement.
  if [ "$JVMA_MEASURED" = 1 ]; then
    printf -v detail -- '-Xmx %s plus %s of measured non-heap needs %s, the cap is %s — the kernel kills it first, with no stack trace' \
      "$xh" "$nh" "$nd" "$cd"
  else
    printf -v detail -- '-Xmx %s plus at least %s of non-heap needs %s or more, the cap is %s — the kernel kills it first, with no stack trace' \
      "$xh" "$nh" "$nd" "$cd"
  fi
  # `pitcrew limit` is deliberately not in the desktop app's runnable-verb list,
  # so this renders as selectable text rather than a button. Changing a memory
  # cap is a decision, not a one-click repair.
  [ "${JVMF_CAP_SOURCE:-}" = pitcrew ] && printf -v fix 'pitcrew limit %s %s' "${JVMF_LABEL}" "$nd"
  jvm_add crit jvm-cap "$title" "$detail" "$fix" "${JVMF_LABEL}"
}

# A heap at its own ceiling spends more time collecting than running. This one
# the JVM could tell you itself; it is here because nothing asks it.
jvm_check_heap() {
  jvm_pct "${JVMF_HEAP_USED_K:--1}" "${JVMF_HEAP_MAX_K:--1}"
  [ "$JVM_PCT" -ge "$PITCREW_JVM_HEAP_WARN_PCT" ] 2>/dev/null || return 0
  local uh xh title detail
  jvm_human "${JVMF_HEAP_USED_K}"; uh=$JVM_H
  jvm_human "${JVMF_HEAP_MAX_K}";  xh=$JVM_H
  printf -v title '%s is at %s%% of its JVM heap' "${JVMF_LABEL}" "$JVM_PCT"
  printf -v detail '%s of %s — past here it spends more time collecting than running' "$uh" "$xh"
  jvm_add warn jvm-heap "$title" "$detail" "" "${JVMF_LABEL}"
}

# The most valuable finding here and the one nothing else reports.
#
# When the code cache fills, the JIT STOPS COMPILING — permanently, for the life
# of the process. Everything already compiled keeps running fast and everything
# new runs interpreted, so the service gets tens of times slower at whatever it
# has not warmed up yet. There is no exception, no log line, and no recovery
# short of a restart. `full_count` is the JVM counting how many times it
# happened, which is why the check is on that and not on a percentage.
jvm_check_codecache() {
  local title detail uh sh
  if jvm_known "${JVMF_CC_FULL:--1}" && [ "${JVMF_CC_FULL}" -gt 0 ]; then
    local times="times"; [ "${JVMF_CC_FULL}" = 1 ] && times="time"
    printf -v title '%s has filled its JIT code cache' "${JVMF_LABEL}"
    printf -v detail 'the cache filled %s %s — the JIT has stopped compiling and new code paths now run interpreted, with nothing in the log' \
      "${JVMF_CC_FULL}" "$times"
    jvm_add crit jvm-codecache "$title" "$detail" "" "${JVMF_LABEL}"
    return 0
  fi
  # Not yet full, but close enough that it will be.
  jvm_pct "${JVMF_CC_USED_K:--1}" "${JVMF_CC_SIZE_K:--1}"
  [ "$JVM_PCT" -ge "$PITCREW_JVM_CC_WARN_PCT" ] 2>/dev/null || return 0
  jvm_human "${JVMF_CC_USED_K}"; uh=$JVM_H
  jvm_human "${JVMF_CC_SIZE_K}"; sh=$JVM_H
  printf -v title '%s is at %s%% of its JIT code cache' "${JVMF_LABEL}" "$JVM_PCT"
  printf -v detail '%s of %s — when it fills, the JIT stops compiling and stays stopped' "$uh" "$sh"
  jvm_add warn jvm-codecache "$title" "$detail" "" "${JVMF_LABEL}"
}

# Metaspace has no ceiling by default, so this fires only where one was set.
# An unbounded metaspace that is merely large is not news; one approaching a
# limit someone chose is a classloader leak about to become an OutOfMemoryError.
jvm_check_metaspace() {
  jvm_known "${JVMF_META_MAX_K:--1}" || return 0
  [ "${JVMF_META_MAX_K}" -gt 0 ] || return 0
  jvm_pct "${JVMF_META_USED_K:--1}" "${JVMF_META_MAX_K}"
  [ "$JVM_PCT" -ge "$PITCREW_JVM_META_WARN_PCT" ] 2>/dev/null || return 0
  local uh xh title detail
  jvm_human "${JVMF_META_USED_K}"; uh=$JVM_H
  jvm_human "${JVMF_META_MAX_K}";  xh=$JVM_H
  printf -v title '%s is at %s%% of MaxMetaspaceSize' "${JVMF_LABEL}" "$JVM_PCT"
  printf -v detail '%s of %s — metaspace grows with loaded classes, so this is usually a classloader leak' "$uh" "$xh"
  jvm_add warn jvm-metaspace "$title" "$detail" "" "${JVMF_LABEL}"
}

# A JVM that cannot see its own cgroup sizes its heap from the HOST's RAM. On a
# 64G build machine with a 2G container limit that is a default heap of 16G, and
# the process is killed the first time it tries to use a fraction of it.
jvm_check_container() {
  jvm_known "${JVMF_CAP_B:--1}" || return 0
  [ "${JVMF_CAP_B}" -gt 0 ] || return 0
  jvm_known "${JVMF_CONTAINER:--1}" || return 0
  [ "${JVMF_CONTAINER}" = 0 ] || return 0
  local ch title detail
  jvm_human_b "${JVMF_CAP_B}"; ch=$JVM_H
  printf -v title '%s runs under a %s cap it cannot see' "${JVMF_LABEL}" "$ch"
  detail='UseContainerSupport is off, so the JVM sized its heap from the whole machine instead of the cap'
  jvm_add warn jvm-container "$title" "$detail" "" "${JVMF_LABEL}"
}

# RSS well above everything the JVM admits to. Usually a native allocation the
# JVM does not track — a JNI library, a leaking direct buffer, glibc malloc
# arenas — and it is invisible to every heap tool there is.
#
# Only ever fires when RSS EXCEEDS the accounting. The other direction is normal
# (see jvm_account) and reporting it would make the tool look broken.
jvm_check_unaccounted() {
  [ "$JVMA_UNACCOUNTED_KNOWN" = 1 ] || return 0
  jvm_known "$JVMA_ACCOUNTED_K" || return 0
  [ "$JVMA_UNACCOUNTED_K" -gt $(( PITCREW_JVM_UNACCOUNTED_MB * 1024 )) ] || return 0
  jvm_pct "${JVMF_RSS_K}" "$JVMA_ACCOUNTED_K"
  [ "$JVM_PCT" -ge "$PITCREW_JVM_UNACCOUNTED_PCT" ] 2>/dev/null || return 0
  local rh ah uh title detail
  jvm_human "${JVMF_RSS_K}";     rh=$JVM_H
  jvm_human "$JVMA_ACCOUNTED_K"; ah=$JVM_H
  jvm_human "$JVMA_UNACCOUNTED_K"; uh=$JVM_H
  printf -v title '%s holds %s the JVM does not account for' "${JVMF_LABEL}" "$uh"
  if [ "$JVMA_MEASURED" = 1 ]; then
    printf -v detail 'RSS %s against %s tracked by NMT — the difference is native memory the JVM did not allocate itself' "$rh" "$ah"
  else
    printf -v detail 'RSS %s against %s of heap and non-heap — start it with -XX:NativeMemoryTracking=summary to see where the rest went' "$rh" "$ah"
  fi
  jvm_add warn jvm-unaccounted "$title" "$detail" "" "${JVMF_LABEL}"
}

# Thread stacks reserve address space per thread. A service that has quietly
# grown to several hundred threads can be reserving a material share of its own
# cap before it allocates a single object.
jvm_check_threads() {
  jvm_known "${JVMA_STACKS_K}" || return 0
  jvm_known "${JVMF_CAP_B:--1}" || return 0
  [ "${JVMF_CAP_B}" -gt 0 ] || return 0
  local cap_k=$(( JVMF_CAP_B / 1024 ))
  jvm_pct "$JVMA_STACKS_K" "$cap_k"
  [ "$JVM_PCT" -ge "$PITCREW_JVM_STACK_SHARE_PCT" ] 2>/dev/null || return 0
  local sh ch title detail
  jvm_human "$JVMA_STACKS_K"; sh=$JVM_H
  jvm_human "$cap_k";         ch=$JVM_H
  printf -v title '%s reserves %s of its cap for thread stacks' "${JVMF_LABEL}" "${JVM_PCT}%"
  printf -v detail '%s threads at %sK each is %s of a %s cap — before a single object is allocated' \
    "${JVMF_THREADS}" "${JVMF_STACK_K}" "$sh" "$ch"
  jvm_add info jvm-threads "$title" "$detail" "" "${JVMF_LABEL}"
}

# Say what could not be measured, and ONLY where it changes an answer.
#
# The first version of this fired on every capped JVM with NMT off, which is
# almost all of them — so a service with nothing wrong carried a finding, and
# every check here competes for the one line someone will actually read.
#
# It now fires only when the floor is close enough to the cap that the
# unmeasured part could decide the outcome. Comfortably under the cap, the fact
# that non-heap is a floor rather than a measurement changes nothing worth
# saying; at or over it, this is the context for the jvm-cap finding above.
PITCREW_JVM_NMT_HINT_PCT="${PITCREW_JVM_NMT_HINT_PCT:-70}"
jvm_check_nmt() {
  [ "${JVMF_NMT:-0}" = 1 ] && return 0
  jvm_known "${JVMF_CAP_B:--1}" || return 0
  [ "${JVMF_CAP_B}" -gt 0 ] || return 0
  jvm_known "$JVMA_NEED_K" || return 0
  jvm_pct "$JVMA_NEED_K" $(( JVMF_CAP_B / 1024 ))
  [ "$JVM_PCT" -ge "$PITCREW_JVM_NMT_HINT_PCT" ] 2>/dev/null || return 0
  local title detail
  printf -v title '%s has native memory tracking off' "${JVMF_LABEL}"
  detail='GC structures, thread stacks and direct buffers cannot be read, so the non-heap figure is a floor — restart with -XX:NativeMemoryTracking=summary to measure it'
  jvm_add info jvm-nmt "$title" "$detail" "" "${JVMF_LABEL}"
}

# Run every check against the facts currently in JVMF_*. Order is severity-
# neutral: the caller sorts, so this stays the order someone would read them in.
jvm_rules() {
  jvm_account
  jvm_check_cap
  jvm_check_codecache
  jvm_check_heap
  jvm_check_metaspace
  jvm_check_container
  jvm_check_unaccounted
  jvm_check_threads
  jvm_check_nmt
  return 0
}
