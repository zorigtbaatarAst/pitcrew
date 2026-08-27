#!/usr/bin/env bash
# ext/jvm/lib/util.sh — formatting and arithmetic shared by the rules and the
# renderer. Nothing here forks or looks at the machine.
#
# The functions SET A GLOBAL rather than printing, which is pitcrew's own
# convention (`human`, `dur_human`, `bar` in lib/01-core.sh) and exists for the
# same reason: a caller reaching for `$(jvm_human ...)` pays a fork per value,
# and this tool formats a couple of dozen values per JVM per frame in --watch.

# Everything internal is KB, because that is what every jcmd command reports.
# Bytes appear only at the two edges: cgroup limits and the caps pitcrew passes in.
JVM_H=""
jvm_human() { # $1 kilobytes -> JVM_H
  local k=$1
  if [ "$k" -lt 0 ] 2>/dev/null; then JVM_H="?"; return 0; fi
  if [ "$k" -lt 1024 ]; then JVM_H="${k}K"; return 0; fi
  if [ "$k" -lt 1048576 ]; then
    # One decimal below 10 units, none above: 1.4G reads, 1434M does not, and
    # 972M is more use than 0.9G.
    local m=$(( k / 1024 )) frac=$(( (k % 1024) * 10 / 1024 ))
    if [ "$m" -lt 10 ]; then JVM_H="${m}.${frac}M"; else JVM_H="${m}M"; fi
    return 0
  fi
  local g=$(( k / 1048576 )) frac=$(( (k % 1048576) * 10 / 1048576 ))
  if [ "$g" -lt 10 ]; then JVM_H="${g}.${frac}G"; else JVM_H="${g}G"; fi
  return 0
}

jvm_human_b() { # $1 bytes -> JVM_H
  local b=$1
  if [ "$b" -lt 0 ] 2>/dev/null; then JVM_H="?"; return 0; fi
  jvm_human $(( b / 1024 ))
}

# A value is KNOWN when it is not the -1 the parsers use for "could not
# measure". Every rule guards on this: treating unknown as zero is exactly the
# bug that made the plugin this tool replaces under-report an OOM risk.
jvm_known() { [ -n "${1:-}" ] && [ "$1" -ge 0 ] 2>/dev/null; }

# Integer percent of $1 over $2, or -1 when either side is unknown or the
# denominator is zero. Guarding here keeps a division-by-zero out of every rule.
JVM_PCT=-1
jvm_pct() { # $1 part, $2 whole -> JVM_PCT
  JVM_PCT=-1
  jvm_known "${1:-}" || return 0
  jvm_known "${2:-}" || return 0
  [ "$2" -gt 0 ] || return 0
  JVM_PCT=$(( $1 * 100 / $2 ))
  return 0
}

# Seconds -> "3h20m". Only ever used for uptime, so days are the largest unit
# anyone needs and seconds stop mattering after a minute.
JVM_DUR=""
jvm_dur() { # $1 seconds -> JVM_DUR
  local s=$1
  if [ "$s" -lt 0 ] 2>/dev/null; then JVM_DUR="?"; return 0; fi
  if [ "$s" -lt 60 ]; then JVM_DUR="${s}s"; return 0; fi
  if [ "$s" -lt 3600 ]; then JVM_DUR="$(( s / 60 ))m"; return 0; fi
  if [ "$s" -lt 86400 ]; then JVM_DUR="$(( s / 3600 ))h$(( (s % 3600) / 60 ))m"; return 0; fi
  JVM_DUR="$(( s / 86400 ))d$(( (s % 86400) / 3600 ))h"
  return 0
}

# Two sizes that a reader has to be able to tell APART -> JVM_H1, JVM_H2.
#
# jvm_human rounds, so 1571M and 1536M both render "1.5G" — and a critical
# finding then reads "needs 1.5G, the cap is 1.5G", which is the evidence
# undermining its own claim. Where two figures are being compared IN ONE
# SENTENCE they are dropped to a finer unit until they differ.
#
# Genuinely equal values still render equal, which is correct: this sharpens
# the rendering, it does not invent a difference.
JVM_H1=""; JVM_H2=""
jvm_human2() { # $1 kb, $2 kb -> JVM_H1, JVM_H2
  jvm_human "$1"; JVM_H1=$JVM_H
  jvm_human "$2"; JVM_H2=$JVM_H
  [ "$JVM_H1" = "$JVM_H2" ] || return 0
  [ "$1" -ge 0 ] 2>/dev/null && [ "$2" -ge 0 ] 2>/dev/null || return 0
  JVM_H1="$(( $1 / 1024 ))M"; JVM_H2="$(( $2 / 1024 ))M"
  return 0
}

# Like jvm_human but for a figure that can legitimately be below zero, which
# among everything here is only the accounted-versus-resident difference. The
# plain jvm_human renders anything negative as "?", because everywhere ELSE a
# negative means the parsers could not read it.
jvm_human_signed() { # $1 kilobytes -> JVM_H
  if [ "${1:-0}" -lt 0 ] 2>/dev/null; then
    jvm_human $(( -1 * $1 )); JVM_H="-$JVM_H"; return 0
  fi
  jvm_human "$1"
}
