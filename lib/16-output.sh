#!/usr/bin/env bash
# lib/16-output.sh — machine-readable output and scripting entry points.
#
# The dashboard is for looking at. These are for everything else: a tmux or
# waybar status line, a CI job that has to know whether the stack came up, a
# shell script that wants to block until it did. Without them pitcrew can only
# be used by a human watching it, which is a low ceiling for a tool this
# opinionated about being correct.

PITCREW_JSON_SCHEMA=1

# Processes per component in the state object. Capped because a JVM tree can be
# dozens of pids and this ships on every frame: the desktop app wants to answer
# "what inside this service is holding the memory", and the biggest handful is
# that answer. Sorted by RSS, so the cap drops the ones nobody was going to
# read. 0 turns the field into an empty list.
PITCREW_JSON_PROCS="${PITCREW_JSON_PROCS:-12}"

# ── encoding, without forking ────────────────────────────────────────────────
#
# These SET A GLOBAL; they do not print. That is the same calling convention
# lib/04-meters.sh uses for the render path (`human` → HUMAN, `bar` → R), and
# for the same reason: a `$(helper)` is a subshell, and this object has one per
# field per component.
#
# It was not a subtle cost. Twelve components came to 295 forks and 176ms an
# object — five times what the whole terminal frame costs — and `json --watch`
# pays it on every interval, forever, so a desktop app that renders a frame in
# 0.4ms sat behind a producer burning ~9% of a core on string escaping. The
# same work through a global is 2ms.
#
# The rule that follows: nothing in this file may be called as `$(...)`.
_json_str() { # $1 → JSTR, a JSON string literal with the two characters that matter escaped
  local v=${1//\\/\\\\}
  JSTR="\"${v//\"/\\\"}\""
}

_json_num() { # $1 → JNUM: a number, or null when we genuinely do not know
  case "${1:-}" in ''|*[!0-9-]*) JNUM=null ;; *) JNUM=$1 ;; esac
}

_json_cpu() { # SNAP_CPU is meaningless without a previous sample — say null, not 0
  if [ "${SNAP_CPU_OK:-0}" = 1 ]; then _json_num "${1:-}"; else JNUM=null; fi
}

# The component's process tree, biggest first. The terminal dashboard has shown
# this behind Enter since the beginning; putting it in the stream is what lets
# the desktop app show the same thing without running its own `ps` — which is
# the one thing the GUI must never do (see AGENTS.md).
_json_processes() { # $1 comp
  printf ',"processes":['
  [ "${PITCREW_JSON_PROCS:-0}" -gt 0 ] || { printf ']'; return 0; }
  local p n=0 first=1
  _tree_sorted "$1"
  for p in "${TREE_SORTED[@]}"; do
    [ -n "$p" ] || continue
    [ "$n" -ge "$PITCREW_JSON_PROCS" ] && break
    n=$((n + 1))
    [ $first = 1 ] || printf ','
    first=0
    local p_pid p_cmd p_rss p_cpu
    _json_num "$p";                        p_pid=$JNUM
    _json_str "${SNAP_PROC_CMD[$p]:-?}";   p_cmd=$JSTR
    _json_num "${SNAP_PROC_RSS[$p]:-}";    p_rss=$JNUM
    _json_cpu "${SNAP_PROC_CPU[$p]:-}";    p_cpu=$JNUM
    printf '{"pid":%s,"cmd":%s,"rss":%s,"cpu":%s}' "$p_pid" "$p_cmd" "$p_rss" "$p_cpu"
  done
  printf ']'
  return 0
}

# A space-separated list as a JSON array of strings, into JWORDS. A global
# rather than stdout for the same reason every other encoder here sets one:
# this runs three times per profile per frame, and a $( ) is a fork.
_json_words() { # $1 words → JWORDS
  local w first=1
  JWORDS='['
  for w in $1; do
    [ $first = 1 ] || JWORDS+=','
    first=0
    _json_str "$w"; JWORDS+=$JSTR
  done
  JWORDS+=']'
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
  _json_str "${PITCREW_PROJECT_NAME:-}"; printf '"project":%s,' "$JSTR"
  _json_str "$ROOT";                        printf '"root":%s,' "$JSTR"
  _json_str "$PITCREW_COLLECTOR";           printf '"collector":%s,' "$JSTR"
  # Where the logs are and what counts as an error line, so a reader can show
  # the same lines the dashboard counts without knowing pitcrew's layout or
  # re-inventing the pattern.
  _json_str "$LOG_DIR";              printf '"logDir":%s,' "$JSTR"
  _json_str "$PROFILE_DIR";          printf '"profileDir":%s,' "$JSTR"
  _json_str "$PITCREW_ERROR_PATTERN"; printf '"errorPattern":%s,' "$JSTR"
  # The names only. A GUI cannot host an interactive psql, but it can tell you
  # this project has one and hand you the exact command — which beats the shells
  # being a feature you only discover by reading the config.
  printf '"shells":['
  local _sh _sfirst=1
  for _sh in "${!PITCREW_SHELLS[@]}"; do
    [ $_sfirst = 1 ] || printf ','
    _sfirst=0
    _json_str "$_sh"; printf '%s' "$JSTR"
  done
  printf '],'
  # The machine itself. A reader plotting RAM against a per-component cap has no
  # idea whether 18G of caps is generous or suicidal without knowing what the
  # box actually has — and pitcrew already measures this for its own gauges.
  #
  # Measures it in `snapshot`, which is the point: both collectors end with a
  # sys_gauges call, so reading them again here was a second measurement of
  # numbers taken microseconds earlier. Free on Linux, where the gauges come
  # out of /proc/meminfo — but macOS has no such file and pays a `vm_stat`
  # fork for each one, so `json --watch` forked FOUR times an object where the
  # frame loop it feeds forks three, and every macOS CI run went red on it.
  local m_total m_used m_cpu m_swaptotal m_swapused m_at
  _json_num $(( ${SYS_MEM_TOTAL_KB:-0} * 1024 ));  m_total=$JNUM
  _json_num $(( ${SYS_MEM_USED_KB:-0} * 1024 ));   m_used=$JNUM
  _json_num "${SYS_CPU_PCT:-0}";                   m_cpu=$JNUM
  _json_num $(( ${SYS_SWAP_TOTAL_KB:-0} * 1024 )); m_swaptotal=$JNUM
  _json_num $(( ${SYS_SWAP_USED_KB:-0} * 1024 ));  m_swapused=$JNUM
  printf '"machine":{"memTotal":%s,"memUsed":%s,"cpuPercent":%s,"swapTotal":%s,"swapUsed":%s},' \
    "$m_total" "$m_used" "$m_cpu" "$m_swaptotal" "$m_swapused"
  _json_num "${SNAP_NOW_S:-0}"; m_at=$JNUM
  printf '"at":%s,' "$m_at"
  printf '"components":['
  for c in "${PITCREW_COMPS[@]}"; do
    app=${c#*-}; role=${c%%-*}
    port=${PITCREW_PORT[$c]:-}
    st=${SNAP_STATE[$c]:-n/a}
    # Built here because pitcrew is what knows --url-path and --be-health. A
    # reader assembling "http://localhost:$port" itself would be right for a
    # frontend and wrong for every backend behind a path prefix.
    local url="" health=""
    if [ -n "$port" ]; then
      # `fe` is the role that serves a page at the root; every other role sits
      # behind the app's url_path, which is what that key has always meant —
      # it just used to be spelled "the backend", back when there were only two.
      if [ "$role" = fe ]; then
        url="http://localhost:$port"
      else
        url="http://localhost:$port${PITCREW_URL_PATH[$app]:-}"
      fi
      [ -n "${PITCREW_HEALTH[$c]:-}" ] &&
        health="http://localhost:$port${PITCREW_HEALTH[$c]}"
    fi
    case "$st" in up) up=$((up+1));; starting) starting=$((starting+1));;
                  crashed) crashed=$((crashed+1));; external) external=$((external+1));;
                  down) down=$((down+1));; esac
    [ $first = 1 ] || printf ','
    first=0
    # Eighteen fields, and every one of them used to be a `$( )`. Encoded into
    # locals first so the printf below stays exactly the object it was.
    local f_name f_app f_role f_state f_port f_pid f_rss f_cpu f_err f_exit
    local f_limit f_limitsrc f_url f_health f_since f_restarts f_idle f_prot f_enabled
    _json_str "$c";                    f_name=$JSTR
    _json_str "$app";                  f_app=$JSTR
    _json_str "$role";                 f_role=$JSTR
    _json_str "$st";                   f_state=$JSTR
    _json_num "$port";                 f_port=$JNUM
    _json_num "${SNAP_PID[$c]:-}";     f_pid=$JNUM
    _json_num "${SNAP_RSS[$c]:-}";     f_rss=$JNUM
    _json_cpu "${SNAP_CPU[$c]:-}";     f_cpu=$JNUM
    _json_num "${ERR_COUNT[$c]:-0}";   f_err=$JNUM
    _json_num "${SNAP_EXIT[$c]:-}";    f_exit=$JNUM
    _json_num "${COMP_MAX_B[$c]:-}";   f_limit=$JNUM
    comp_max_source "$c";              _json_str "$MAXSRC"; f_limitsrc=$JSTR
    _json_str "$url";                  f_url=$JSTR
    _json_str "$health";               f_health=$JSTR
    _json_num "${SNAP_SINCE[$c]:-}";   f_since=$JNUM
    _json_num "${RESTART_N[$c]:-0}";   f_restarts=$JNUM
    _json_num "${SNAP_IDLE[$c]:-}";    f_idle=$JNUM
    f_prot=false; [ -n "${PITCREW_PROTECTED[$c]:-}" ] && f_prot=true
    # A component the config switched off. Reported rather than omitted: a
    # reader that never saw it could not tell "excluded" from "deleted", and
    # the GUI has to draw it greyed out rather than not at all.
    f_enabled=true; [ -n "${PITCREW_DISABLED[$c]:-}" ] && f_enabled=false
    printf '{"name":%s,"app":%s,"role":%s,"state":%s,"port":%s,"pid":%s,"rss":%s,"cpu":%s,"errors":%s,"exit":%s,"limit":%s,"limitSource":%s,"url":%s,"health":%s,"since":%s,"restarts":%s,"idle":%s,"protected":%s,"enabled":%s' \
      "$f_name" "$f_app" "$f_role" "$f_state" \
      "$f_port" "$f_pid" "$f_rss" "$f_cpu" "$f_err" "$f_exit" \
      "$f_limit" "$f_limitsrc" "$f_url" "$f_health" \
      "$f_since" "$f_restarts" "$f_idle" "$f_prot" "$f_enabled"
    _json_processes "$c"
    printf '}'
  done
  printf '],"profiles":['
  # Profiles carry their live state here so the desktop app can show what a
  # profile is DOING without reading pitcrew's directory layout and resolving
  # target words for itself — which is what it used to do, and which cannot
  # know that "sales" now covers a worker too.
  first=1
  local pname
  profile_names_arr
  for pname in "${PROFILE_NAMES[@]}"; do
    profile_stat "$pname"
    [ $first = 1 ] || printf ','
    first=0
    local p_name p_targets p_comps p_missing
    _json_str "$pname";              p_name=$JSTR
    _json_words "$PSTAT_TARGETS";    p_targets=$JWORDS
    _json_words "${PROFILE_COMPS[*]}"; p_comps=$JWORDS
    _json_words "$PSTAT_MISSING";    p_missing=$JWORDS
    printf '{"name":%s,"targets":%s,"components":%s,"missing":%s,"total":%s,"up":%s,"starting":%s,"rss":%s,"limit":%s}' \
      "$p_name" "$p_targets" "$p_comps" "$p_missing" \
      "$PSTAT_TOTAL" "$PSTAT_UP" "$PSTAT_STARTING" "$PSTAT_RSS" "$PSTAT_CAP"
  done
  printf '],"deps":['
  first=1
  local dep
  for dep in "${PITCREW_DEPS[@]:-}"; do
    [ -n "$dep" ] || continue
    [ $first = 1 ] || printf ','
    first=0
    local d_name d_state
    _json_str "$dep";                     d_name=$JSTR
    _json_str "${SNAP_DEP[$dep]:-down}";  d_state=$JSTR
    printf '{"name":%s,"state":%s}' "$d_name" "$d_state"
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

# ── the config, as the editable model ───────────────────────────────────────
# `pitcrew config --json` answers "what does this project's config actually
# say", so an editor never has to parse YAML for itself.
#
# That matters more than it sounds. lib/18-yaml.sh is the ONE definition of the
# subset pitcrew accepts, and a GUI carrying a second parser would sooner or
# later accept a file the tool rejects — or, worse, save one it silently
# misread. The desktop app's form reads this object and writes targeted edits
# back into the text; it never interprets the file itself.
#
# Both halves are reported: `cmd`/`dir`/`root`/`watch` are what the FILE says,
# and `runCmd`/`runDir` are what they resolved to. An editor shows the first
# and a diagnostic wants the second.
cmd_config_json() {
  local app role c first=1 rfirst=1
  printf '{'
  printf '"schema":%s,' "$PITCREW_JSON_SCHEMA"
  _json_str "${CONFIG_FILE:-}";             printf '"file":%s,' "$JSTR"
  _json_str "$ROOT";                        printf '"root":%s,' "$JSTR"
  _json_str "${PITCREW_PROJECT_NAME:-}";    printf '"name":%s,' "$JSTR"
  _json_str "${PITCREW_EMOJI:-}";           printf '"emoji":%s,' "$JSTR"
  printf '"format":%s,' "$(config_is_yaml "${CONFIG_FILE:-}" && echo '"yaml"' || echo '"sh"')"

  printf '"roles":['
  for role in "${PITCREW_ROLES[@]:-}"; do
    [ -n "$role" ] || continue
    [ $rfirst = 1 ] || printf ','
    rfirst=0
    local r_name r_env r_max
    _json_str "$role";                       r_name=$JSTR
    _json_str "${PITCREW_ROLE_ENV[$role]:-}"; r_env=$JSTR
    _json_str "${PITCREW_ROLE_MAX[$role]:-}"; r_max=$JSTR
    printf '{"name":%s,"env":%s,"max":%s}' "$r_name" "$r_env" "$r_max"
  done
  printf '],'

  printf '"apps":['
  for app in "${PITCREW_APPS[@]}"; do
    [ $first = 1 ] || printf ','
    first=0
    local a_name a_url a_root
    _json_str "$app";                          a_name=$JSTR
    _json_str "${PITCREW_URL_PATH[$app]:-}";   a_url=$JSTR
    _json_str "${PITCREW_SRC_ROOT[$app]:-}";   a_root=$JSTR
    printf '{"name":%s,"urlPath":%s,"root":%s,"components":[' "$a_name" "$a_url" "$a_root"
    local cfirst=1
    for role in ${PITCREW_APP_ROLES[$app]:-}; do
      c="$role-$app"
      [ $cfirst = 1 ] || printf ','
      cfirst=0
      local k_name k_role k_cmd k_dir k_root k_watch k_port k_health k_max k_run k_en k_pr
      _json_str "$c";                          k_name=$JSTR
      _json_str "$role";                       k_role=$JSTR
      _json_str "${PITCREW_SRC_CMD[$c]:-}";    k_cmd=$JSTR
      _json_str "${PITCREW_SRC_DIR[$c]:-}";    k_dir=$JSTR
      _json_str "${PITCREW_SRC_ROOT[$c]:-}";   k_root=$JSTR
      _json_str "${PITCREW_SRC_WATCH[$c]:-}";  k_watch=$JSTR
      _json_num "${PITCREW_PORT[$c]:-}";       k_port=$JNUM
      _json_str "${PITCREW_HEALTH[$c]:-}";     k_health=$JSTR
      _json_str "${PITCREW_MAX_COMP[$c]:-}";   k_max=$JSTR
      _json_str "${PITCREW_CMD[$c]:-}";        k_run=$JSTR
      k_en=true;  comp_disabled "$c" && k_en=false
      k_pr=false; [ -n "${PITCREW_PROTECTED[$c]:-}" ] && k_pr=true
      printf '{"name":%s,"role":%s,"cmd":%s,"dir":%s,"root":%s,"watch":%s,"port":%s,"health":%s,"max":%s,"runCmd":%s,"enabled":%s,"protected":%s}' \
        "$k_name" "$k_role" "$k_cmd" "$k_dir" "$k_root" "$k_watch" \
        "$k_port" "$k_health" "$k_max" "$k_run" "$k_en" "$k_pr"
    done
    printf ']}'
  done
  printf '],'

  printf '"deps":['
  first=1
  local dep
  for dep in "${PITCREW_DEPS[@]:-}"; do
    [ -n "$dep" ] || continue
    [ $first = 1 ] || printf ','
    first=0
    _json_str "$dep"; printf '%s' "$JSTR"
  done
  printf ']}'
  printf '\n'
}
