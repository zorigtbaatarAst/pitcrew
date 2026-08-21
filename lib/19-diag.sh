#!/usr/bin/env bash
# lib/19-diag.sh — diagnostics: turning the snapshot into an answer.
#
# Everything else in pitcrew reports FACTS — this state, that many bytes, this
# exit code. Facts are what a monitor owes you and they are not the same thing
# as an answer. "RAM 96%" is a fact; "your machine is swapping because four
# JVMs are up and two of them have been idle for the better part of an hour" is
# what you actually wanted to know, and it is the difference between a
# dashboard and an operations tool.
#
# ── the extension point ────────────────────────────────────────────────────
#
# A check is a function that reads the snapshot and calls `diag_add` for
# anything worth saying. It registers itself with `diag_register`, and the core
# checks below use exactly the same call a plugin would — there is no privileged
# path. That is the whole of the contract:
#
#     my_check() { [ "$SOME_CONDITION" ] && diag_add warn my-id "title" "detail" "fix" "scope"; }
#     diag_register my_check
#
# `diag_run` then executes every registered check in registration order and
# leaves the findings in the DIAG_* arrays, a verdict in DIAG_VERDICT and a
# one-line summary in DIAG_HEADLINE. Everything downstream — the dashboard's
# verdict line, `pitcrew diagnose`, the `health` object in the JSON, and the
# desktop app's Overview — reads those and nothing else, so a check added here
# shows up in all four without touching any of them.
#
# This is deliberately the *only* seam introduced for the eventual plugin
# architecture. Resource intelligence is the thing that most obviously does not
# belong hardcoded in core, and a registry of functions over a shared snapshot
# is the smallest honest version of that boundary. It is not a plugin loader,
# and it should not grow into one until something outside this repository needs
# to register a check.
#
# ── cost ───────────────────────────────────────────────────────────────────
#
# diag_run is called once per dashboard frame, so it obeys the same rule as
# everything else in the render path: no `$( )`, no external commands, no
# forks. It only reads arrays snapshot() has already filled.

DIAG_CHECKS=()
diag_register() { DIAG_CHECKS+=("$1"); }

# Findings, as parallel arrays — bash has no records, and six aligned arrays
# beat one array of delimited strings that every consumer has to re-split.
DIAG_SEV=()      # crit | warn | info
DIAG_ID=()       # stable machine-readable id, for a UI that wants to match on one
DIAG_TITLE=()    # one line: what is wrong
DIAG_DETAIL=()   # one line: the evidence for saying so
DIAG_FIX=()      # the command that addresses it, or "" when there isn't one
DIAG_SCOPE=()    # the component or dep it concerns, or "" for machine-wide

DIAG_VERDICT=ok
DIAG_HEADLINE=""
DIAG_N=0
DIAG_CRIT=0
DIAG_WARN=0
DIAG_INFO=0

diag_add() { # $1 sev, $2 id, $3 title, $4 detail, [$5 fix], [$6 scope]
  DIAG_SEV+=("$1"); DIAG_ID+=("$2"); DIAG_TITLE+=("$3"); DIAG_DETAIL+=("$4")
  DIAG_FIX+=("${5:-}"); DIAG_SCOPE+=("${6:-}")
  case "$1" in
    crit) DIAG_CRIT=$((DIAG_CRIT + 1)) ;;
    warn) DIAG_WARN=$((DIAG_WARN + 1)) ;;
    *)    DIAG_INFO=$((DIAG_INFO + 1)) ;;
  esac
  DIAG_N=$((DIAG_N + 1))
}

# ── thresholds ──────────────────────────────────────────────────────────────
# Named, tunable, and documented, because the alternative is four magic numbers
# buried in four different conditions.
PITCREW_MEM_WARN_PCT="${PITCREW_MEM_WARN_PCT:-85}"    # machine RAM in use
PITCREW_MEM_CRIT_PCT="${PITCREW_MEM_CRIT_PCT:-93}"
PITCREW_CAP_NEAR_PCT="${PITCREW_CAP_NEAR_PCT:-90}"    # a component against its own cap
PITCREW_IDLE_MIN="${PITCREW_IDLE_MIN:-600}"           # seconds before "idle" is worth saying
PITCREW_SLOW_START_MULT="${PITCREW_SLOW_START_MULT:-1}"  # × PITCREW_WAIT_SECS before a boot is "stuck"

# comp_port() prints its answer, so reading it is a `$( )` — a fork, in the
# frame loop. The port cannot change while we run, so resolve the whole map
# once and look it up.
declare -gA DIAG_PORT=()
diag_ports_init() {
  local c app
  DIAG_PORT=()
  for c in "${PITCREW_COMPS[@]}"; do
    app=${c#??-}
    if [ "${c:0:2}" = be ]; then DIAG_PORT[$c]=${PITCREW_BE_PORT[$app]:-}
    else DIAG_PORT[$c]=${PITCREW_FE_PORT[$app]:-}; fi
  done
}

# ── largest consumers, sorted, fork-free ────────────────────────────────────
# An insertion sort over at most a few dozen components. `sort` is a fork, and
# this runs inside the frame loop.
DIAG_TOP=()          # comps, largest RSS first
diag_top_consumers() {
  DIAG_TOP=()
  local c i n rss
  for c in "${PITCREW_COMPS[@]}"; do
    rss=${SNAP_RSS[$c]:-0}
    [ -n "$rss" ] && [ "$rss" -gt 0 ] 2>/dev/null || continue
    n=${#DIAG_TOP[@]}
    DIAG_TOP+=("$c")
    for ((i = n; i > 0; i--)); do
      [ "${SNAP_RSS[${DIAG_TOP[i-1]}]:-0}" -ge "$rss" ] && break
      DIAG_TOP[i]=${DIAG_TOP[i-1]}
      DIAG_TOP[i-1]=$c
    done
  done
  return 0
}

# ── the core checks ─────────────────────────────────────────────────────────

# A crash is the one thing that is always worth interrupting for, and "crashed"
# on its own is not actionable — the exit code and when it happened are.
diag_check_crashed() {
  local c code when detail
  for c in "${PITCREW_COMPS[@]}"; do
    [ "${SNAP_STATE[$c]:-}" = crashed ] || continue
    code=${SNAP_EXIT[$c]:-}
    when=${SNAP_EXIT_AT[$c]:-0}
    if [ -n "$code" ] && [ "$when" -gt 0 ] 2>/dev/null; then
      dur_human $(( SNAP_NOW_S - when ))
      printf -v detail 'exited %s, %s ago' "$code" "${DUR:-just now}"
    elif [ -n "$code" ]; then
      printf -v detail 'exited %s' "$code"
    else
      detail='the process is gone and left no exit status'
    fi
    diag_add crit crashed "$c crashed" "$detail" "pitcrew logs $c" "$c"
  done
}

# A service that has been "starting" for longer than the configured boot
# timeout is not booting, it is stuck — and the dashboard's amber dot looks
# identical at ten seconds and at ten minutes.
diag_check_stuck() {
  local c age limit app
  limit=$(( ${PITCREW_WAIT_SECS:-240} * PITCREW_SLOW_START_MULT ))
  for c in "${PITCREW_COMPS[@]}"; do
    [ "${SNAP_STATE[$c]:-}" = starting ] || continue
    age=${SNAP_SINCE[$c]:-}
    [ -n "$age" ] || continue
    age=$(( SNAP_NOW_S - age ))
    [ "$age" -gt "$limit" ] || continue
    app=${c#??-}
    dur_human "$age"
    if [ "${c:0:2}" = be ] && [ -n "${PITCREW_BE_HEALTH_PATH[$app]:-}" ]; then
      diag_add warn stuck "$c has been starting for $DUR" \
        "its health endpoint has not reported UP yet" "pitcrew logs $c" "$c"
    else
      diag_add warn stuck "$c has been starting for $DUR" \
        "the process is alive but nothing is listening on its port" "pitcrew logs $c" "$c"
    fi
  done
}

# Something else is serving a port this project claims. This is the failure
# that looks most like success: the port answers, so a casual glance says "up".
diag_check_external() {
  local c port
  for c in "${PITCREW_COMPS[@]}"; do
    [ "${SNAP_STATE[$c]:-}" = external ] || continue
    port=${DIAG_PORT[$c]:-}
    diag_add warn external "port $port is not being served by pitcrew" \
      "$c is configured for it, but the listener is a process pitcrew did not start" \
      "pitcrew ports" "$c"
  done
}

# Memory pressure, with the reason attached. The number on its own is the least
# useful half: what matters is who is holding the memory and whether the
# machine has started swapping to cope.
diag_check_memory() {
  local total=${SYS_MEM_TOTAL_KB:-0} used=${SYS_MEM_USED_KB:-0} pct
  [ "$total" -gt 0 ] 2>/dev/null || return 0
  pct=$(( used * 100 / total ))

  local swapping=0
  [ "${SYS_SWAP_USED_KB:-0}" -gt $(( 64 * 1024 )) ] && swapping=1

  [ "$pct" -ge "$PITCREW_MEM_WARN_PCT" ] || [ "$swapping" = 1 ] || return 0

  # Name the three biggest things this project is holding. Not "some process":
  # the whole point is that the user can act on it.
  diag_top_consumers
  local names="" c i=0 share=0
  for c in "${DIAG_TOP[@]}"; do
    [ "$i" -ge 3 ] && break
    human "${SNAP_RSS[$c]:-0}"
    names+="${names:+, }$c ${HUMAN}"
    i=$((i + 1))
  done
  for c in "${PITCREW_COMPS[@]}"; do share=$(( share + ${SNAP_RSS[$c]:-0} )); done

  local detail title sev=warn
  human $(( used * 1024 )); local usedh=$HUMAN
  human $(( total * 1024 )); local totalh=$HUMAN
  human "$share"; local shareh=$HUMAN

  if [ "$swapping" = 1 ]; then
    human $(( SYS_SWAP_USED_KB * 1024 ))
    printf -v title 'memory pressure — %s of swap in use' "$HUMAN"
    sev=crit
  else
    printf -v title 'memory pressure — %s of %s in use (%s%%)' "$usedh" "$totalh" "$pct"
    [ "$pct" -ge "$PITCREW_MEM_CRIT_PCT" ] && sev=crit
  fi
  if [ -n "$names" ]; then
    printf -v detail 'this project holds %s of it — largest: %s' "$shareh" "$names"
  else
    printf -v detail 'this project is holding %s, so the pressure is coming from elsewhere' "$shareh"
  fi
  diag_add "$sev" memory "$title" "$detail" "pitcrew diagnose" ""
}

# A cap that cannot bite is worse than no cap: the OOM killer picks the victim
# instead, and it does not pick the one you would have.
diag_check_caps() {
  local c committed=0 total=$(( ${SYS_MEM_TOTAL_KB:-0} * 1024 ))
  for c in "${PITCREW_COMPS[@]}"; do committed=$(( committed + ${COMP_MAX_B[$c]:-0} )); done
  if [ "$total" -gt 0 ] && [ "$committed" -gt "$total" ]; then
    human "$committed"; local ch=$HUMAN
    human "$total";     local th=$HUMAN
    diag_add warn caps-overcommit "RAM caps commit $ch on a $th machine" \
      "if everything runs at its cap the kernel runs out before any cap applies" \
      "pitcrew limit" ""
  fi
  # And a component actually approaching the cap that will kill it.
  local rss cap pct
  for c in "${PITCREW_COMPS[@]}"; do
    [ "${SNAP_STATE[$c]:-}" = up ] || continue
    rss=${SNAP_RSS[$c]:-0}; cap=${COMP_MAX_B[$c]:-0}
    [ "$cap" -gt 0 ] && [ "$rss" -gt 0 ] || continue
    pct=$(( rss * 100 / cap ))
    [ "$pct" -ge "$PITCREW_CAP_NEAR_PCT" ] || continue
    human "$rss"; local rh=$HUMAN
    human "$cap"; local caph=$HUMAN
    diag_add warn cap-near "$c is at ${pct}% of its RAM cap" \
      "$rh of $caph — at the cap it is killed, not throttled" "pitcrew limit $c" "$c"
  done
}

# A declared dependency that is not running. Everything downstream of it will
# fail in a way that looks like the service's own fault.
diag_check_deps() {
  local dep
  for dep in "${PITCREW_DEPS[@]:-}"; do
    [ -n "$dep" ] || continue
    [ "${SNAP_DEP[$dep]:-down}" = up ] && continue
    diag_add warn dep-down "dependency $dep is not running" \
      "services that need it will fail in ways that look like their own bug" \
      "pitcrew start deps" "$dep"
  done
}

# Errors in a log are not necessarily a problem — but a service that is "up"
# and quietly logging exceptions is exactly the thing nobody notices.
diag_check_errors() {
  local c n
  for c in "${PITCREW_COMPS[@]}"; do
    n=${ERR_COUNT[$c]:-0}
    [ "$n" -gt 0 ] 2>/dev/null || continue
    [ "${SNAP_STATE[$c]:-}" = up ] || continue
    diag_add info log-errors "$c has $n error lines in its log" \
      "it is up and serving, so nothing else is going to tell you" "pitcrew logs $c" "$c"
  done
}

# What could be given back, and at what cost. This is the answer to "what can I
# safely stop", and it is deliberately phrased as an observation with a command
# attached rather than as an offer to kill things: pitcrew proposes, the person
# decides. See cmd_diagnose for the review step.
DIAG_IDLE_COMPS=()
DIAG_IDLE_BYTES=0
declare -gA DIAG_IDLE_WHY=()      # comp -> the evidence, so the UI never has to invent it
diag_check_idle() {
  DIAG_IDLE_COMPS=(); DIAG_IDLE_BYTES=0; DIAG_IDLE_WHY=()
  local c idle rss up

  # Two conditions, and both are things pitcrew actually measured:
  #
  #   quiet   — its process tree has stayed under PITCREW_IDLE_CPU for every
  #             sample since this pitcrew process started watching. That window
  #             is minutes in the dashboard and seconds in a one-shot
  #             `diagnose`, so the number is reported rather than rounded into
  #             a claim it cannot support.
  #   old     — it has been up at least PITCREW_IDLE_MIN. A service you started
  #             ten seconds ago is not a candidate for being stopped no matter
  #             how quiet it is, and uptime is the only "have you touched this
  #             recently" signal available without keeping state between runs.
  #
  # Neither is proof that nothing needs it. That is exactly why this is a
  # suggestion with the evidence attached and not an action.
  for c in "${PITCREW_COMPS[@]}"; do
    [ "${SNAP_STATE[$c]:-}" = up ] || continue
    idle=${SNAP_IDLE[$c]:-}
    [ -n "$idle" ] || continue                 # no CPU baseline yet — say nothing
    up=${SNAP_SINCE[$c]:-}
    [ -n "$up" ] || continue
    up=$(( SNAP_NOW_S - up ))
    [ "$up" -ge "$PITCREW_IDLE_MIN" ] || continue
    rss=${SNAP_RSS[$c]:-0}
    [ "$rss" -gt 0 ] || continue
    dur_human "$idle"; local ih=$DUR
    dur_human "$up"
    DIAG_IDLE_COMPS+=("$c")
    DIAG_IDLE_WHY[$c]="quiet ${ih} · up ${DUR}"
    DIAG_IDLE_BYTES=$(( DIAG_IDLE_BYTES + rss ))
  done
  [ ${#DIAG_IDLE_COMPS[@]} -gt 0 ] || return 0

  # Only worth raising when memory is actually tight. Otherwise a quiet service
  # is just one you are not using this minute, which is fine and not news.
  local total=${SYS_MEM_TOTAL_KB:-0} used=${SYS_MEM_USED_KB:-0} pct=0
  [ "$total" -gt 0 ] && pct=$(( used * 100 / total ))
  [ "$pct" -ge "$PITCREW_MEM_WARN_PCT" ] || [ "${SYS_SWAP_USED_KB:-0}" -gt $(( 64 * 1024 )) ] || return 0

  human "$DIAG_IDLE_BYTES"
  diag_add info recoverable "${#DIAG_IDLE_COMPS[@]} idle services are holding $HUMAN" \
    "no CPU since pitcrew started watching, and up long enough to be forgotten" \
    "pitcrew stop ${DIAG_IDLE_COMPS[*]}" ""
}

diag_register diag_check_crashed
diag_register diag_check_stuck
diag_register diag_check_external
diag_register diag_check_memory
diag_register diag_check_caps
diag_register diag_check_deps
diag_register diag_check_errors
diag_register diag_check_idle

# ── running them ────────────────────────────────────────────────────────────

# Findings are collected in check order, then the verdict is the worst severity
# present and the headline is the first finding at that severity. Deliberately
# not "the most recent" or "the most numerous": when a stack is on fire the
# thing you need on the one line you will actually read is the worst thing.
diag_run() {
  DIAG_SEV=(); DIAG_ID=(); DIAG_TITLE=(); DIAG_DETAIL=(); DIAG_FIX=(); DIAG_SCOPE=()
  DIAG_N=0; DIAG_CRIT=0; DIAG_WARN=0; DIAG_INFO=0
  DIAG_VERDICT=ok; DIAG_HEADLINE=""

  [ ${#DIAG_PORT[@]} -gt 0 ] || diag_ports_init

  local check
  for check in "${DIAG_CHECKS[@]}"; do
    declare -F "$check" >/dev/null && "$check"
  done

  local i
  if [ "$DIAG_CRIT" -gt 0 ]; then DIAG_VERDICT=crit
  elif [ "$DIAG_WARN" -gt 0 ]; then DIAG_VERDICT=warn
  fi
  if [ "$DIAG_VERDICT" != ok ]; then
    for i in "${!DIAG_SEV[@]}"; do
      [ "${DIAG_SEV[i]}" = "$DIAG_VERDICT" ] || continue
      DIAG_HEADLINE=${DIAG_TITLE[i]}
      break
    done
  else
    diag_ok_headline
  fi
  return 0
}

# "ok" still deserves a sentence. A dashboard that says nothing when nothing is
# wrong makes you check whether it is working.
diag_ok_headline() {
  local c up=0 configured=0
  for c in "${PITCREW_COMPS[@]}"; do
    configured=$((configured + 1))
    case "${SNAP_STATE[$c]:-}" in up|external) up=$((up + 1)) ;; esac
  done
  if [ "$up" -eq 0 ]; then
    DIAG_HEADLINE="nothing is running"
  elif [ "$up" -eq "$configured" ]; then
    DIAG_HEADLINE="all $up components healthy"
  else
    DIAG_HEADLINE="$up of $configured components up, no problems found"
  fi
}

# ── `pitcrew diagnose` ──────────────────────────────────────────────────────

diag_icon() { # $1 severity → R
  case "$1" in
    crit) R="${C_CRIT}✗${RESET}" ;;
    warn) R="${C_WARN}⚠${RESET}" ;;
    *)    R="${C_INFO}∙${RESET}" ;;
  esac
}

diag_verdict_line() { # → R: the one line that says whether things are fine
  case "$DIAG_VERDICT" in
    crit) R="${C_CRIT}●${RESET} ${C_CRIT}${BOLD}${DIAG_HEADLINE}${RESET}" ;;
    warn) R="${C_WARN}●${RESET} ${C_TEXT}${DIAG_HEADLINE}${RESET}" ;;
    *)    R="${C_OK}●${RESET} ${C_SUBTLE}${DIAG_HEADLINE}${RESET}" ;;
  esac
}

cmd_diagnose() { # [--json]
  if [ "${1:-}" = --json ]; then diag_json; return $?; fi
  [ $# -eq 0 ] || die "diagnose: unknown argument '$1'"

  banner
  # CPU% — and therefore quietness — is a delta, so one snapshot can only ever
  # report "unknown". Sample across a short window instead: three samples is
  # enough that a service which merely happened to be between requests at the
  # instant we looked does not read as idle.
  local _s
  for _s in 1 2 3; do
    snapshot
    err_scan
    [ "$_s" = 3 ] || sleep 1
  done
  diag_run
  err_close

  diag_verdict_line
  say "  $R"
  say ""

  _diag_machine_block

  if [ "$DIAG_N" -eq 0 ]; then
    say "  ${C_MUTED}no findings${RESET}"
    say ""
    return 0
  fi

  local i sev shown
  for sev in crit warn info; do
    shown=0
    for i in "${!DIAG_SEV[@]}"; do
      [ "${DIAG_SEV[i]}" = "$sev" ] || continue
      [ "$shown" = 0 ] && { say ""; shown=1; }
      diag_icon "$sev"
      say "  $R ${BOLD}${DIAG_TITLE[i]}${RESET}"
      say "    ${C_MUTED}${DIAG_DETAIL[i]}${RESET}"
      [ -n "${DIAG_FIX[i]}" ] && say "    ${C_FAINT}→${RESET} ${C_SUBTLE}${DIAG_FIX[i]}${RESET}"
    done
  done
  say ""

  # ── the review step ──
  # Candidates are shown with what stopping them gives back and the exact
  # command that would do it. pitcrew never stops anything here: an automatic
  # "optimise" button that picks its own victims is precisely the thing a
  # developer cannot trust, and the one command it prints is auditable.
  if [ ${#DIAG_IDLE_COMPS[@]} -gt 0 ]; then
    human "$DIAG_IDLE_BYTES"
    say "  ${BOLD}recoverable${RESET} ${C_MUTED}— idle, and what stopping them returns${RESET}"
    say ""
    local c
    for c in "${DIAG_IDLE_COMPS[@]}"; do
      human "${SNAP_RSS[$c]:-0}"
      printf '    %b%-22s%b %b%7s%b   %b%s%b\n' \
        "$C_TEXT" "$c" "$RESET" "$C_ACCENT" "$HUMAN" "$RESET" \
        "$C_MUTED" "${DIAG_IDLE_WHY[$c]:-}" "$RESET"
    done
    human "$DIAG_IDLE_BYTES"
    say ""
    say "    ${C_MUTED}total${RESET} ${BOLD}${HUMAN}${RESET}"
    say "    ${C_FAINT}→${RESET} ${C_SUBTLE}pitcrew stop ${DIAG_IDLE_COMPS[*]}${RESET}"
    say ""
  fi

  [ "$DIAG_VERDICT" = crit ] && return 1
  return 0
}

_diag_machine_block() {
  local total=${SYS_MEM_TOTAL_KB:-0} used=${SYS_MEM_USED_KB:-0} pct=0 share=0 c
  [ "$total" -gt 0 ] && pct=$(( used * 100 / total ))
  for c in "${PITCREW_COMPS[@]}"; do share=$(( share + ${SNAP_RSS[$c]:-0} )); done

  say "  ${BOLD}machine${RESET}"
  if [ "$total" -gt 0 ]; then
    human $(( used * 1024 )); local usedh=$HUMAN
    human $(( total * 1024 )); local totalh=$HUMAN
    pct_color "$pct"; bar "$pct" 24
    printf '    %bRAM%b  %s %b%s%b %b/ %s%b  %b%s%%%b\n' \
      "$C_MUTED" "$RESET" "$R" "$C_TEXT" "$usedh" "$RESET" "$C_MUTED" "$totalh" "$RESET" \
      "$C_SUBTLE" "$pct" "$RESET"
  fi
  pct_color "${SYS_CPU_PCT:-0}"; bar "${SYS_CPU_PCT:-0}" 24
  printf '    %bCPU%b  %s %b%s%%%b\n' "$C_MUTED" "$RESET" "$R" "$C_SUBTLE" "${SYS_CPU_PCT:-0}" "$RESET"
  if [ "${SYS_SWAP_TOTAL_KB:-0}" -gt 0 ]; then
    human $(( SYS_SWAP_USED_KB * 1024 )); local sh=$HUMAN
    human $(( SYS_SWAP_TOTAL_KB * 1024 )); local sth=$HUMAN
    local spct=$(( SYS_SWAP_USED_KB * 100 / SYS_SWAP_TOTAL_KB ))
    pct_color "$spct"; bar "$spct" 24
    printf '    %bSWP%b  %s %b%s%b %b/ %s%b\n' \
      "$C_MUTED" "$RESET" "$R" "$C_TEXT" "$sh" "$RESET" "$C_MUTED" "$sth" "$RESET"
  fi
  human "$share"
  say "    ${C_MUTED}this project holds${RESET} ${C_TEXT}${HUMAN}${RESET}"
  say ""
}

# The same findings as data. Used by `pitcrew diagnose --json` and embedded in
# the state object by lib/16-output.sh, so the desktop app reads a verdict
# rather than re-deriving one from components it would have to interpret itself.
diag_json() {
  local _s
  for _s in 1 2 3; do
    snapshot
    err_scan
    [ "$_s" = 3 ] || sleep 1
  done
  diag_run
  err_close
  printf '{"schema":%s,' "$PITCREW_JSON_SCHEMA"
  printf '"project":%s,' "$(_json_str "${PITCREW_PROJECT_NAME:-}")"
  printf '"health":'
  diag_json_health
  printf '}\n'
  [ "$DIAG_VERDICT" = crit ] && return 1
  return 0
}

# Just the health object, so cmd_json can embed it without duplicating this.
diag_json_health() {
  local i first=1
  printf '{"verdict":%s,"headline":%s,"counts":{"crit":%d,"warn":%d,"info":%d},"findings":[' \
    "$(_json_str "$DIAG_VERDICT")" "$(_json_str "$DIAG_HEADLINE")" \
    "$DIAG_CRIT" "$DIAG_WARN" "$DIAG_INFO"
  for i in "${!DIAG_SEV[@]}"; do
    [ $first = 1 ] || printf ','
    first=0
    printf '{"severity":%s,"id":%s,"title":%s,"detail":%s,"fix":%s,"scope":%s}' \
      "$(_json_str "${DIAG_SEV[i]}")" "$(_json_str "${DIAG_ID[i]}")" \
      "$(_json_str "${DIAG_TITLE[i]}")" "$(_json_str "${DIAG_DETAIL[i]}")" \
      "$(_json_str "${DIAG_FIX[i]}")" "$(_json_str "${DIAG_SCOPE[i]}")"
  done
  printf '],"recoverable":{"components":['
  first=1
  local c
  for c in "${DIAG_IDLE_COMPS[@]:-}"; do
    [ -n "$c" ] || continue
    [ $first = 1 ] || printf ','
    first=0
    printf '%s' "$(_json_str "$c")"
  done
  printf '],"bytes":%d}}' "${DIAG_IDLE_BYTES:-0}"
}
