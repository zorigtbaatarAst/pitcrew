#!/usr/bin/env bash
# lib/16-output.sh — machine-readable output and scripting entry points.
#
# The dashboard is for looking at. These are for everything else: a tmux or
# waybar status line, a CI job that has to know whether the stack came up, a
# shell script that wants to block until it did. Without them pitcrew can only
# be used by a human watching it, which is a low ceiling for a tool this
# opinionated about being correct.

PITCREW_JSON_SCHEMA=1

_json_str() { # $1 → a JSON string literal, with the two characters that matter escaped
  local v=${1//\\/\\\\}
  printf '"%s"' "${v//\"/\\\"}"
}

_json_num() { # a number, or null when we genuinely do not know
  case "${1:-}" in ''|*[!0-9-]*) printf 'null' ;; *) printf '%s' "$1" ;; esac
}

_json_cpu() { # SNAP_CPU is meaningless without a previous sample — say null, not 0
  [ "${SNAP_CPU_OK:-0}" = 1 ] || { printf 'null'; return; }
  _json_num "${1:-}"
}

cmd_json() {
  snapshot
  err_scan
  diag_run
  local c app role port first=1 up=0 starting=0 crashed=0 external=0 down=0 st
  printf '{'
  # A version, because this object has consumers now: the desktop app, status
  # lines, CI gates. Bump it when a field is REMOVED or changes meaning; adding
  # one is backwards compatible and does not. test/output_test.sh pins the whole
  # key set, so neither can happen by accident.
  printf '"schema":%s,' "$PITCREW_JSON_SCHEMA"
  printf '"project":%s,' "$(_json_str "${PITCREW_PROJECT_NAME:-}")"
  printf '"root":%s,' "$(_json_str "$ROOT")"
  printf '"collector":%s,' "$(_json_str "$PITCREW_COLLECTOR")"
  # Where the logs are and what counts as an error line, so a reader can show
  # the same lines the dashboard counts without knowing pitcrew's layout or
  # re-inventing the pattern.
  printf '"logDir":%s,' "$(_json_str "$LOG_DIR")"
  printf '"profileDir":%s,' "$(_json_str "$PROFILE_DIR")"
  printf '"errorPattern":%s,' "$(_json_str "$PITCREW_ERROR_PATTERN")"
  # The machine itself. A reader plotting RAM against a per-component cap has no
  # idea whether 18G of caps is generous or suicidal without knowing what the
  # box actually has — and pitcrew already measures this for its own gauges.
  sys_gauges
  printf '"machine":{"memTotal":%s,"memUsed":%s,"cpuPercent":%s,"swapTotal":%s,"swapUsed":%s},' \
    "$(_json_num $(( ${SYS_MEM_TOTAL_KB:-0} * 1024 )))" \
    "$(_json_num $(( ${SYS_MEM_USED_KB:-0} * 1024 )))" \
    "$(_json_num "${SYS_CPU_PCT:-0}")" \
    "$(_json_num $(( ${SYS_SWAP_TOTAL_KB:-0} * 1024 )))" \
    "$(_json_num $(( ${SYS_SWAP_USED_KB:-0} * 1024 )))"
  printf '"at":%s,' "$(_json_num "${SNAP_NOW_S:-0}")"
  printf '"components":['
  for c in "${PITCREW_COMPS[@]}"; do
    app=${c#??-}; role=${c:0:2}
    if [ "$role" = be ]; then port=${PITCREW_BE_PORT[$app]:-}; else port=${PITCREW_FE_PORT[$app]:-}; fi
    st=${SNAP_STATE[$c]:-n/a}
    # Built here because pitcrew is what knows --url-path and --be-health. A
    # reader assembling "http://localhost:$port" itself would be right for a
    # frontend and wrong for every backend behind a path prefix.
    local url="" health=""
    if [ -n "$port" ]; then
      if [ "$role" = be ]; then
        url="http://localhost:$port${PITCREW_URL_PATH[$app]:-}"
        [ -n "${PITCREW_BE_HEALTH_PATH[$app]:-}" ] &&
          health="http://localhost:$port${PITCREW_BE_HEALTH_PATH[$app]}"
      else
        url="http://localhost:$port"
      fi
    fi
    case "$st" in up) up=$((up+1));; starting) starting=$((starting+1));;
                  crashed) crashed=$((crashed+1));; external) external=$((external+1));;
                  down) down=$((down+1));; esac
    [ $first = 1 ] || printf ','
    first=0
    printf '{"name":%s,"app":%s,"role":%s,"state":%s,"port":%s,"pid":%s,"rss":%s,"cpu":%s,"errors":%s,"exit":%s,"limit":%s,"limitSource":%s,"url":%s,"health":%s,"since":%s,"restarts":%s,"idle":%s,"protected":%s}' \
      "$(_json_str "$c")" "$(_json_str "$app")" "$(_json_str "$role")" "$(_json_str "$st")" \
      "$(_json_num "$port")" "$(_json_num "${SNAP_PID[$c]:-}")" \
      "$(_json_num "${SNAP_RSS[$c]:-}")" "$(_json_cpu "${SNAP_CPU[$c]:-}")" \
      "$(_json_num "${ERR_COUNT[$c]:-0}")" "$(_json_num "${SNAP_EXIT[$c]:-}")" \
      "$(_json_num "${COMP_MAX_B[$c]:-}")" "$(_json_str "$(comp_max_source "$c")")" \
      "$(_json_str "$url")" "$(_json_str "$health")" \
      "$(_json_num "${SNAP_SINCE[$c]:-}")" "$(_json_num "${RESTART_N[$c]:-0}")" \
      "$(_json_num "${SNAP_IDLE[$c]:-}")" \
      "$([ -n "${PITCREW_PROTECTED[$c]:-}" ] && printf true || printf false)"
  done
  printf '],"deps":['
  first=1
  local dep
  for dep in "${PITCREW_DEPS[@]:-}"; do
    [ -n "$dep" ] || continue
    [ $first = 1 ] || printf ','
    first=0
    printf '{"name":%s,"state":%s}' "$(_json_str "$dep")" "$(_json_str "${SNAP_DEP[$dep]:-down}")"
  done
  # The verdict, not just the facts. A reader that had to re-derive "is
  # anything wrong" from the component list would be reimplementing
  # lib/19-diag.sh in whatever language it happens to be written in — and would
  # drift from what the dashboard says the moment either side changed.
  printf '],"health":'
  diag_json_health
  printf ',"summary":{"up":%d,"starting":%d,"crashed":%d,"external":%d,"down":%d}}\n' \
    "$up" "$starting" "$crashed" "$external" "$down"
  err_close
  return 0
}

# NDJSON stream: one state object per line, forever, until the reader goes away.
#
# This exists because CPU% is a delta and `status --json` is one-shot, so its
# `cpu` is always null (see _json_cpu). A GUI, a status line or a recorder wants
# real CPU, and the only honest way to get it is to keep ONE process taking
# repeated samples — exactly what the dashboard does. Line-buffered and flushed
# per frame so a reader blocked on read() wakes on every sample.
cmd_json_watch() { # [--interval N]
  local interval=${PITCREW_JSON_INTERVAL:-2}
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) [ $# -ge 2 ] || die "--interval needs a value"; interval=$2; shift 2 ;;
      --interval=*) interval=${1#*=}; shift ;;
      *) die "json --watch: unknown argument [$1]" ;;
    esac
  done
  case "$interval" in ''|*[!0-9]*) die "--interval needs whole seconds, got [$interval]" ;; esac
  [ "$interval" -ge 1 ] || die "--interval must be at least 1 second"

  # SIGPIPE is the normal way this ends (the GUI exits, the pipe closes). Exit
  # quietly on it rather than leaving a bash error on someone's terminal.
  trap 'exit 0' PIPE
  while :; do
    cmd_json || return $?
    sleep "$interval"
  done
}

# Exit codes are the whole point: 0 everything came up, 1 timed out, 2 something
# crashed on the way. A script can act on that; it cannot act on a dashboard.
cmd_wait() { # [--timeout N] [--strict] [targets...]
  local timeout=${PITCREW_WAIT_SECS:-240} strict=0 raw=() w
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; timeout=$2; shift 2 ;;
      --timeout=*) timeout=${1#*=}; shift ;;
      --strict) strict=1; shift ;;
      *) raw+=("$1"); shift ;;
    esac
  done
  [ ${#raw[@]} -eq 0 ] && raw=(all)
  local words; mapfile -t words < <(expand_profiles "${raw[@]}")
  local comps; mapfile -t comps < <(resolve_targets "${words[@]}")
  [ ${#comps[@]} -gt 0 ] || die "nothing to wait for"

  # `external` means the port is being served by something that is not ours.
  # By default that satisfies the wait — a port that answers, answers, and
  # serving a hand-started process is a documented feature. --strict refuses
  # it, which is what a CI job wants when the whole question is whether THIS
  # build came up. Either way it is reported, never silently accepted.
  local t=0 c st pending crashed ext
  while [ "$t" -lt "$timeout" ]; do
    snapshot
    pending=0; crashed=0; ext=0
    for c in "${comps[@]}"; do
      st=${SNAP_STATE[$c]:-n/a}
      case "$st" in
        up|n/a)   ;;
        external) ext=$((ext + 1)); [ "$strict" = 1 ] && pending=$((pending + 1)) ;;
        crashed)  crashed=$((crashed + 1)) ;;
        *)        pending=$((pending + 1)) ;;
      esac
    done
    [ "$crashed" -gt 0 ] && { say "  ${RED}✗${RESET} $crashed component(s) crashed while waiting"; return 2; }
    if [ "$pending" -eq 0 ]; then
      if [ "$ext" -gt 0 ]; then
        say "  ${GREEN}✔${RESET} ${#comps[@]} component(s) up ${YELLOW}($ext served by a process pitcrew did not start)${RESET}"
      else
        say "  ${GREEN}✔${RESET} ${#comps[@]} component(s) up"
      fi
      return 0
    fi
    sleep 1; t=$((t + 1))
  done
  say "  ${YELLOW}⚠${RESET} timed out after ${timeout}s with $pending still not up"
  return 1
}

# Everything running on this machine, across every registered project. Reads
# pidfiles directly rather than loading each config, so it stays cheap however
# many projects are registered.
cmd_ps() {
  local n root f pid comp any=0 live
  say ""
  while IFS= read -r n; do
    root=$(project_root_of "$n") || continue
    [ -n "$root" ] && [ -d "$root/.pitcrew/logs" ] || continue
    live=""
    for f in "$root"/.pitcrew/logs/*.pid; do
      [ -r "$f" ] || continue
      read -r pid < "$f" 2>/dev/null
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
      comp=${f##*/}; comp=${comp%.pid}
      live+="    ${C_OK}●${RESET} ${C_SUBTLE}${comp}${RESET} ${C_MUTED}pid ${pid}${RESET}"$'\n'
    done
    [ -n "$live" ] || continue
    any=1
    say "  ${BOLD}${n}${RESET} ${C_MUTED}${root}${RESET}"
    printf '%b' "$live"
  done < <(project_list)
  [ "$any" = 0 ] && say "  ${C_MUTED}nothing running in any registered project${RESET}"
  say ""
  return 0
}
