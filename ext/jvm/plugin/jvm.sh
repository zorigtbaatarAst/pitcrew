#!/usr/bin/env bash
# ext/jvm/plugin/jvm.sh — the pitcrew end of pitcrew-jvm.
#
# Install:  ext/jvm/install.sh          (or copy this to ~/.config/pitcrew/plugins/)
# Check it: pitcrew plugins
# Use it:   pitcrew diagnose
#
# ── what this file is, and what it deliberately is not ──────────────────────
#
# It is an ADAPTER, about forty lines of it. Every parser, threshold and
# judgement lives in pitcrew-jvm, which knows nothing about pitcrew and runs
# perfectly well over ssh on a box that has never heard of it.
#
# The split is not tidiness. The plugin this replaces carried its own `jcmd`
# parsers, and they were written against one JDK — so when `GC.heap_info`
# stopped printing a Metaspace line after JDK 11, the check went on reporting
# metaspace as zero and quietly UNDER-stated the risk it exists to catch.
# Parsers that are pinned by fixtures across five JDK generations are too big
# to carry in a plugin, and duplicating them here would just recreate the
# problem one directory over.
#
# What pitcrew contributes is the one fact the tool cannot work out for itself:
# the RAM cap it launched each component under. That is passed in per target,
# and it is the entire basis of the jvm-cap finding.

# Found on PATH, or wherever the installer put it. Absent is not an error: a
# plugin that cannot work should register nothing and say nothing, per
# pitcrew's "degrade with a message rather than an error" convention.
_jvm_bin() { # -> the tool, or empty
  if [ -n "${PITCREW_JVM_BIN:-}" ] && [ -x "${PITCREW_JVM_BIN}" ]; then
    printf '%s' "${PITCREW_JVM_BIN}"; return 0
  fi
  local p
  p=$(command -v pitcrew-jvm 2>/dev/null) && { printf '%s' "$p"; return 0; }
  for p in "$HOME/.local/share/pitcrew-jvm/bin/pitcrew-jvm" \
           "$HOME/.local/bin/pitcrew-jvm"; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# The java processes inside one component's tree.
#
# A `gradle bootRun` or a `mvn spring-boot:run` is a wrapper that forks a
# daemon that forks the application, so the pid pitcrew launched is almost
# never the JVM anyone cares about. Matched on the executable name that
# snapshot() already recorded — never on a full command line, which matches
# editors and the search itself.
_jvm_comp_pids() { # $1 comp -> java pids in its tree, one per line
  local p
  for p in ${SNAP_PIDS[$1]:-}; do
    case "${SNAP_PROC_CMD[$p]:-}" in java|*/java) printf '%s\n' "$p" ;; esac
  done
}

# "label<TAB>pid<TAB>cap_bytes<TAB>pitcrew" for every JVM in every running
# component. Where a component holds more than one JVM the label carries the
# pid, or two findings about one component would be indistinguishable.
_jvm_targets() {
  local c pid n
  for c in "${PITCREW_COMPS[@]}"; do
    [ "${SNAP_STATE[$c]:-}" = up ] || continue
    n=0
    while IFS= read -r pid; do
      [ -n "$pid" ] && n=$((n + 1))
    done < <(_jvm_comp_pids "$c")
    [ "$n" -gt 0 ] || continue
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      if [ "$n" -gt 1 ]; then
        printf '%s[%s]\t%s\t%s\tpitcrew\n' "$c" "$pid" "$pid" "${COMP_MAX_B[$c]:-0}"
      else
        printf '%s\t%s\t%s\tpitcrew\n' "$c" "$pid" "${COMP_MAX_B[$c]:-0}"
      fi
    done < <(_jvm_comp_pids "$c")
  done
}

# Split one line on TABS, keeping empty fields -> _JVM_F.
#
# `IFS=$'\t' read -r a b c` looks like it does this and does not: bash treats
# TAB as IFS *whitespace*, so a run of them collapses and leading ones are
# stripped. One empty field therefore shifts every column after it — a finding
# with no fix command arrived with its SCOPE in the fix slot and no scope at
# all, which silently detached it from the component row it belongs to.
#
# Splitting by hand is the fix; the format is fine, the reader was wrong.
_JVM_F=()
_jvm_split() { # $1 line
  _JVM_F=()
  local rest=$1
  while :; do
    case "$rest" in
      *$'\t'*) _JVM_F+=("${rest%%$'\t'*}"); rest=${rest#*$'\t'} ;;
      *)        _JVM_F+=("$rest"); break ;;
    esac
  done
}

jvm_check() {
  local bin line
  bin=$(_jvm_bin) || return 0

  # report-tsv rather than tsv: one invocation yields the findings AND the
  # memory table. Asking twice would cost ten jcmd forks per JVM instead of
  # five, and this runs once per component.
  #
  # The tool exits 1 when it found something critical. That is its verdict, not
  # a failure, so the status is ignored and the output is read either way.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _jvm_split "$line"
    case "${_JVM_F[0]:-}" in
      finding)
        case "${_JVM_F[1]:-}" in crit|warn|info) ;; *) continue ;; esac
        diag_add "${_JVM_F[1]}" "${_JVM_F[2]:-}" "${_JVM_F[3]:-}" \
                 "${_JVM_F[4]:-}" "${_JVM_F[5]:-}" "${_JVM_F[6]:-}"
        ;;
      report)
        diag_report_open "${_JVM_F[1]:-jvm}" "${_JVM_F[2]:-}" "${_JVM_F[3]:-}"
        ;;
      row)
        diag_report_row "${_JVM_F[1]:-}" "${_JVM_F[2]:-}" "${_JVM_F[3]:-}"
        ;;
    esac
  done < <(_jvm_targets | "$bin" --check --format report-tsv --targets - 2>/dev/null)
  return 0
}

# `slow`, because it forks a pitcrew-jvm which forks a jcmd per JVM. That keeps
# it out of the dashboard frame loop structurally rather than by convention —
# it runs when someone asks `pitcrew diagnose`.
diag_register jvm_check slow
