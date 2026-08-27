#!/usr/bin/env bash
# ext/jvm/lib/render.sh — turning facts and findings into something to read.
#
# Four outputs, one set of numbers: a list row, a full breakdown, JSON, and the
# tab-separated findings the pitcrew adapter consumes. None of them re-derive
# anything — if a figure is not in JVMF_*/JVMA_*/JVMR_*, it does not get shown.

# ── colour ──────────────────────────────────────────────────────────────────
# Honour NO_COLOR, and never emit escapes into a pipe: this tool is meant to be
# grepped and redirected on a server, and a log full of SGR is worse than a
# plain one. Same defaulting pitcrew uses.
jvm_colors_init() {
  local on=1
  [ -n "${NO_COLOR:-}" ] && on=0
  [ -t 1 ] || on=0
  case "${PITCREW_JVM_COLOR:-}" in always) on=1 ;; never) on=0 ;; esac
  if [ "$on" = 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_CRIT=$'\033[31m'; C_WARN=$'\033[33m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'
  else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_CRIT=""; C_WARN=""; C_INFO=""; C_OK=""
  fi
}

# The worst severity present, as a glyph. Severity is the only thing a glance
# is allowed to convey, so there is exactly one ramp: crit, warn, info, ok.
jvm_glyph() { # -> JVM_GLYPH
  if [ "${JVMR_CRIT:-0}" -gt 0 ]; then JVM_GLYPH="${C_CRIT}✗${C_RESET}"
  elif [ "${JVMR_WARN:-0}" -gt 0 ]; then JVM_GLYPH="${C_WARN}⚠${C_RESET}"
  elif [ "${JVMR_INFO:-0}" -gt 0 ]; then JVM_GLYPH="${C_INFO}∙${C_RESET}"
  else JVM_GLYPH="${C_OK}●${C_RESET}"; fi
}

jvm_render_header() {
  printf '%s  %-18s %-8s %-7s %-8s %-13s %-9s %-8s%s\n' \
    "$C_DIM" LABEL PID UP RSS "HEAP used/max" NON-HEAP CAP "$C_RESET"
}

# One JVM, one line. Every column is a measurement or a dash; "?" means the
# tool could not read it, which is a different statement from zero.
jvm_render_row() {
  local rss heap hmax nonheap cap
  jvm_human "${JVMF_RSS_K}";        rss=$JVM_H
  jvm_human "${JVMF_HEAP_USED_K}";  heap=$JVM_H
  jvm_human "${JVMF_HEAP_MAX_K}";   hmax=$JVM_H
  jvm_human "${JVMA_NONHEAP_K}";    nonheap=$JVM_H
  if jvm_known "${JVMF_CAP_B}" && [ "${JVMF_CAP_B}" -gt 0 ]; then
    jvm_human_b "${JVMF_CAP_B}"; cap=$JVM_H
  else cap="-"; fi
  jvm_dur "${JVMF_UPTIME}"
  jvm_glyph
  printf '%s %-18s %-8s %-7s %-8s %-13s %-9s %-8s\n' \
    "$JVM_GLYPH" "${JVMF_LABEL}" "${JVMF_PID}" "$JVM_DUR" "$rss" \
    "$heap/$hmax" "$nonheap" "$cap"
}

_jvm_line() { printf '  %s%s%s\n' "$C_DIM" "────────────────────────────────────────────────" "$C_RESET"; }

# One row of the breakdown table. A dash where a figure does not apply, "?"
# where it could not be read.
_jvm_brk() { # $1 label, $2 committed_k, $3 used_k, $4 max_k, [$5 note]
  local c u m
  jvm_human "$2"; c=$JVM_H; [ "$2" = "-1" ] && c="?"
  if [ "${3:--1}" = "-1" ]; then u="-"; else jvm_human "$3"; u=$JVM_H; fi
  if [ "${4:--1}" = "-1" ]; then m="-"; else jvm_human "$4"; m=$JVM_H; fi
  printf '  %-16s %10s %10s %10s   %s%s%s\n' "$1" "$c" "$u" "$m" "$C_DIM" "${5:-}" "$C_RESET"
}

# The full picture for one JVM: where the memory went, and against what ceiling.
jvm_render_detail() {
  local note
  jvm_dur "${JVMF_UPTIME}"
  printf '\n%s%s%s  %spid %s · up %s%s\n\n' \
    "$C_BOLD" "${JVMF_LABEL}" "$C_RESET" "$C_DIM" "${JVMF_PID}" "$JVM_DUR" "$C_RESET"

  if [ "${JVMF_ATTACHED:-0}" != 1 ]; then
    printf '  %sthe JVM did not answer — it may be mid-GC, refusing attach, or owned by another user%s\n\n' \
      "$C_WARN" "$C_RESET"
  fi

  printf '  %s%-16s %10s %10s %10s%s\n' "$C_DIM" "" committed used max "$C_RESET"
  _jvm_brk "heap"        "${JVMF_HEAP_COMMIT_K}" "${JVMF_HEAP_USED_K}" "${JVMF_HEAP_MAX_K}"
  _jvm_brk "metaspace"   "${JVMF_META_COMMIT_K}" "${JVMF_META_USED_K}" "${JVMF_META_MAX_K}"
  note=""
  [ "${JVMF_CC_FULL:--1}" -gt 0 ] 2>/dev/null && note="filled ${JVMF_CC_FULL}× — JIT stopped"
  _jvm_brk "code cache"  "${JVMF_CC_SIZE_K}" "${JVMF_CC_USED_K}" -1 "$note"

  if [ "${JVMF_NMT:-0}" = 1 ]; then
    _jvm_brk "GC structures" "${JVMF_NMT_GC_K}" -1 -1
    _jvm_brk "thread stacks" "${JVMF_NMT_THREAD_K}" -1 -1 "${JVMF_THREADS} threads"
  elif jvm_known "${JVMA_STACKS_K}"; then
    # Reserved, not committed — said outright, because the number is several
    # times what the process is actually holding and looks alarming otherwise.
    _jvm_brk "thread stacks" "${JVMA_STACKS_K}" -1 -1 \
      "${JVMF_THREADS} × ${JVMF_STACK_K}K reserved, not committed"
  fi

  _jvm_line
  local a r u
  jvm_human "${JVMA_ACCOUNTED_K}"; a=$JVM_H
  jvm_human "${JVMF_RSS_K}";       r=$JVM_H
  if [ "${JVMA_MEASURED}" = 1 ]; then note="measured by NMT"
  else note="a floor: GC structures and direct buffers cannot be read"; fi
  printf '  %-16s %10s   %s%s%s\n' "accounted" "$a" "$C_DIM" "$note" "$C_RESET"
  printf '  %-16s %10s   %sresident pages; committed is normally higher%s\n' \
    "resident (RSS)" "$r" "$C_DIM" "$C_RESET"
  if [ "${JVMA_UNACCOUNTED_KNOWN:-0}" = 1 ] && [ "${JVMA_UNACCOUNTED_K}" -gt 0 ]; then
    jvm_human_signed "${JVMA_UNACCOUNTED_K}"; u=$JVM_H
    printf '  %-16s %10s   %s%snot accounted for by the JVM%s\n' \
      "unaccounted" "$u" "$C_WARN" "" "$C_RESET"
  fi
  if jvm_known "${JVMF_CAP_B}" && [ "${JVMF_CAP_B}" -gt 0 ]; then
    jvm_human_b "${JVMF_CAP_B}"
    printf '  %-16s %10s   %sfrom %s%s\n' "cap" "$JVM_H" "$C_DIM" "${JVMF_CAP_SOURCE}" "$C_RESET"
  fi
  printf '\n'
}

jvm_render_findings() {
  local i sev icon shown=0
  for sev in crit warn info; do
    for i in "${!JVMR_SEV[@]}"; do
      [ "${JVMR_SEV[i]}" = "$sev" ] || continue
      shown=1
      case "$sev" in
        crit) icon="${C_CRIT}✗${C_RESET}" ;;
        warn) icon="${C_WARN}⚠${C_RESET}" ;;
        *)    icon="${C_INFO}∙${C_RESET}" ;;
      esac
      printf '  %s %s%s%s\n' "$icon" "$C_BOLD" "${JVMR_TITLE[i]}" "$C_RESET"
      printf '    %s%s%s\n' "$C_DIM" "${JVMR_DETAIL[i]}" "$C_RESET"
      [ -n "${JVMR_FIX[i]}" ] && printf '    %s→ %s%s\n' "$C_DIM" "${JVMR_FIX[i]}" "$C_RESET"
    done
  done
  [ "$shown" = 1 ] && printf '\n'
  return 0
}

# ── the pitcrew adapter's channel ───────────────────────────────────────────
#
# Tab-separated, one finding per line, in exactly DIAG_* order. Deliberately
# NOT json: the consumer is a bash plugin, and asking it to parse JSON would
# either add a dependency or invite a regex that breaks on the first title
# containing a brace.
#
# Tabs and newlines are stripped from the fields rather than escaped, because a
# finding is one line of prose by construction and a delimiter appearing inside
# one is a bug in the rule, not something to encode around.
jvm_render_tsv() {
  local i
  for i in "${!JVMR_SEV[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${JVMR_SEV[i]}" "${JVMR_ID[i]}" \
      "${JVMR_TITLE[i]//[$'\t\n']/ }" "${JVMR_DETAIL[i]//[$'\t\n']/ }" \
      "${JVMR_FIX[i]//[$'\t\n']/ }" "${JVMR_SCOPE[i]//[$'\t\n']/ }"
  done
}

# ── JSON ────────────────────────────────────────────────────────────────────
# The encoders SET A GLOBAL and print nothing, which is pitcrew's convention
# (constraint 7) and here saves a fork per field in `--watch`.
JSTR=""
_jvm_jstr() { # $1 -> JSTR, quoted and escaped
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}
  JSTR="\"$s\""
}
JNUM=""
_jvm_jnum() { # $1 -> JNUM; the -1 sentinel becomes null, not -1
  if [ "${1:--1}" = "-1" ]; then JNUM=null; else JNUM=$1; fi
}

_jvm_json_findings() {
  local i first=1
  printf '['
  for i in "${!JVMR_SEV[@]}"; do
    [ $first = 1 ] || printf ','
    first=0
    printf '{'
    _jvm_jstr "${JVMR_SEV[i]}";    printf '"severity":%s,' "$JSTR"
    _jvm_jstr "${JVMR_ID[i]}";     printf '"id":%s,' "$JSTR"
    _jvm_jstr "${JVMR_TITLE[i]}";  printf '"title":%s,' "$JSTR"
    _jvm_jstr "${JVMR_DETAIL[i]}"; printf '"detail":%s,' "$JSTR"
    _jvm_jstr "${JVMR_FIX[i]}";    printf '"fix":%s,' "$JSTR"
    _jvm_jstr "${JVMR_SCOPE[i]}";  printf '"scope":%s' "$JSTR"
    printf '}'
  done
  printf ']'
}

jvm_render_json_one() {
  printf '{'
  _jvm_jnum "${JVMF_PID}";     printf '"pid":%s,' "$JNUM"
  _jvm_jstr "${JVMF_LABEL}";   printf '"label":%s,' "$JSTR"
  _jvm_jnum "${JVMF_UPTIME}";  printf '"uptime_s":%s,' "$JNUM"
  printf '"attached":%s,' "$([ "${JVMF_ATTACHED:-0}" = 1 ] && printf true || printf false)"
  _jvm_jnum "${JVMF_RSS_K}";   printf '"rss_kb":%s,' "$JNUM"
  _jvm_jnum "${JVMF_SWAP_K}";  printf '"swap_kb":%s,' "$JNUM"
  _jvm_jnum "${JVMF_THREADS}"; printf '"threads":%s,' "$JNUM"

  printf '"heap":{'
  _jvm_jnum "${JVMF_HEAP_USED_K}";   printf '"used_kb":%s,' "$JNUM"
  _jvm_jnum "${JVMF_HEAP_COMMIT_K}"; printf '"committed_kb":%s,' "$JNUM"
  _jvm_jnum "${JVMF_HEAP_MAX_K}";    printf '"max_kb":%s},' "$JNUM"

  printf '"metaspace":{'
  _jvm_jnum "${JVMF_META_USED_K}";   printf '"used_kb":%s,' "$JNUM"
  _jvm_jnum "${JVMF_META_COMMIT_K}"; printf '"committed_kb":%s,' "$JNUM"
  _jvm_jnum "${JVMF_META_MAX_K}";    printf '"max_kb":%s},' "$JNUM"

  printf '"codecache":{'
  _jvm_jnum "${JVMF_CC_SIZE_K}"; printf '"size_kb":%s,' "$JNUM"
  _jvm_jnum "${JVMF_CC_USED_K}"; printf '"used_kb":%s,' "$JNUM"
  _jvm_jnum "${JVMF_CC_FULL}";   printf '"full_count":%s},' "$JNUM"

  printf '"nmt":{"enabled":%s,' "$([ "${JVMF_NMT:-0}" = 1 ] && printf true || printf false)"
  _jvm_jnum "${JVMF_NMT_TOTAL_K}";  printf '"total_committed_kb":%s,' "$JNUM"
  _jvm_jnum "${JVMF_NMT_THREAD_K}"; printf '"thread_committed_kb":%s,' "$JNUM"
  _jvm_jnum "${JVMF_NMT_GC_K}";     printf '"gc_committed_kb":%s},' "$JNUM"

  printf '"cap":{'
  _jvm_jnum "${JVMF_CAP_B}";   printf '"bytes":%s,' "$JNUM"
  _jvm_jstr "${JVMF_CAP_SOURCE}"; printf '"source":%s},' "$JSTR"

  printf '"accounting":{'
  _jvm_jnum "${JVMA_NONHEAP_K}";   printf '"nonheap_kb":%s,' "$JNUM"
  _jvm_jnum "${JVMA_ACCOUNTED_K}"; printf '"accounted_kb":%s,' "$JNUM"
  # Legitimately negative, so it is emitted as a number or as null via its own
  # flag — never through the -1 sentinel, which here would be a real value.
  if [ "${JVMA_UNACCOUNTED_KNOWN:-0}" = 1 ]; then
    printf '"unaccounted_kb":%s,' "${JVMA_UNACCOUNTED_K}"
  else
    printf '"unaccounted_kb":null,'
  fi
  _jvm_jnum "${JVMA_NEED_K}"; printf '"need_kb":%s,' "$JNUM"
  printf '"measured":%s},' "$([ "${JVMA_MEASURED}" = 1 ] && printf true || printf false)"

  printf '"findings":'
  _jvm_json_findings
  printf '}'
}
