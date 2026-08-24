#!/usr/bin/env bash
# lib/07a-start.sh — bringing components up, and the live wait-dashboard shown
# while they boot. Every component is a plain background process (wrapped in
# `systemd-run --user --scope` for a RAM cap when systemd is available, a
# bare backgrounded `bash -c` otherwise) with its own log file and pidfile —
# no terminal multiplexer involved.

start_deps() {
  [ ${#PITCREW_DEPS[@]} -eq 0 ] && return
  command -v docker >/dev/null || die "docker not found"
  docker info >/dev/null 2>&1 || die "docker daemon is not running"
  local dep
  for dep in "${PITCREW_DEPS[@]}"; do
    if container_running "$dep"; then
      say "  ${GREEN}●${RESET} $dep already running"
    else
      say "  ${YELLOW}▶${RESET} starting container ${BOLD}$dep${RESET}"
      docker start "$dep" >/dev/null || say "  ${RED}✗ could not start $dep${RESET}"
    fi
  done
  [ -n "$PITCREW_DEPS_READY_CMD" ] && bash -c "$PITCREW_DEPS_READY_CMD" >/dev/null 2>&1
}

# How many previous runs of each component's log to keep beside the live one.
PITCREW_LOG_KEEP="${PITCREW_LOG_KEEP:-2}"

rotate_log() { # $1 comp — keep the previous run's output instead of erasing it
  # The old behaviour was `: > log`, which meant restarting a service destroyed
  # the log you were restarting it to investigate. The previous process is
  # already dead by the time we get here, so a plain rename is safe — no open
  # fd is still pointing at the file.
  # NOTE: `c` must be its own `local` statement. bash expands the RHS of every
  # name=value in one `local ...` command against the PRE-statement scope, so
  # `f="$LOG_DIR/$c.log"` on the same line reads the CALLER's $c. It happened
  # to work only because launch_process has a variable of the same name — see
  # the identical note in comp_healthy (lib/03b-state.sh).
  local c=$1
  local f="$LOG_DIR/$c.log" i
  [ -s "$f" ] || { : > "$f"; return 0; }
  if [ "${PITCREW_LOG_KEEP:-0}" -lt 1 ]; then : > "$f"; return 0; fi
  for ((i = PITCREW_LOG_KEEP - 1; i >= 1; i--)); do
    [ -f "$f.$i" ] && mv -f "$f.$i" "$f.$((i + 1))"
  done
  mv -f "$f" "$f.1"
  : > "$f"
  return 0
}

launch_process() { # $1 comp $2 full command (env prefix already folded in)
  local c=$1 full_cmd=$2
  mkdir -p "$LOG_DIR"
  rotate_log "$c"
  rm -f "$LOG_DIR/$c.pid" "$LOG_DIR/$c.exit" "$LOG_DIR/.health-$c"

  # Before the wrapper, not inside it: systemd-run refuses to reuse a unit name
  # that is still loaded, and inside the subshell that refusal goes to the LOG
  # and comes back as one more crash. Out here it is one line saying what was
  # cleared. See scope_reclaim for what leaves a scope running behind a process
  # that has already exited.
  if scope_reclaim "$c"; then
    say "  ${GREY}■${RESET} cleared the leftover scope for ${BOLD}$c${RESET} ${GREY}(something outlived its last run)${RESET}"
  fi

  # The command is wrapped rather than exec'd so that something outlives it and
  # can record HOW it ended. Without this a dead service is just an absence:
  # the dashboard can say "crashed" but never "exited 1 at 12:04", which is the
  # first thing you actually want to know. The wrapper lives exactly as long as
  # the service, so pid liveness still means what it meant, and the process
  # tree walk already looks through it for RAM/CPU.
  {
    local rc=0
    if [ "$HAS_SYSTEMD" = 1 ]; then
      systemd-run --user --scope --collect --unit "$SESSION-$c" \
        -p MemoryMax="$(comp_max "$c")" -p MemorySwapMax=2G \
        bash -c "$full_cmd" || rc=$?
    else
      bash -c "$full_cmd" || rc=$?
    fi
    printf '%s %s\n' "$rc" "$EPOCHSECONDS" > "$LOG_DIR/$c.exit"
  } >>"$LOG_DIR/$c.log" 2>&1 &
  echo $! > "$LOG_DIR/$c.pid"
  disown 2>/dev/null || true
  say "  ${YELLOW}▶${RESET} launched ${BOLD}$c${RESET}"
}

start_comp() {
  local c=$1 cmd
  cmd=$(comp_cmd "$c")
  if [ -z "$cmd" ]; then warn "$c has no start command configured — skipping"; return; fi
  local pid; pid=$(read_pid "$c")
  if pid_alive "$pid" || port_open "$(comp_port "$c")"; then
    say "  ${GREEN}●${RESET} $c already running"; return
  fi
  launch_process "$c" "$(comp_env "$c") $cmd"
}

fail_marker() { # $1 comp — succeeds if its log shows a fatal startup failure
  local f="$LOG_DIR/$1.log"
  [ -f "$f" ] || return 1
  tail -n 80 "$f" 2>/dev/null | strip_ansi \
    | grep -qE 'BUILD FAILED|APPLICATION FAILED TO START|npm ERR!|EADDRINUSE|error Command failed'
}

fail_tail() { # $1 comp — last meaningful log lines, cleaned and indented
  tail -n 150 "$LOG_DIR/$1.log" 2>/dev/null | strip_ansi | grep -vE '^[[:space:]]*$' | tail -20 | sed 's/^/      /'
}

wait_dashboard() {
  local comps=("$@") t=0 i=0 c st pending=1 drawn=0 frame nl focus line W w
  [ ${#comps[@]} -eq 0 ] && return
  local -A failed=()
  say ""
  tput civis 2>/dev/null
  trap 'printf "\033[?7h"; tput cnorm 2>/dev/null; echo; return 0' INT
  while [ $t -lt "$PITCREW_WAIT_SECS" ]; do
    printf '\033[?7l'   # no auto-wrap: a too-wide line must never break the repaint line count
    W=$(tput cols 2>/dev/null); [ -n "$W" ] || W=100; w=$((W - 8))
    snapshot
    pending=0; focus=""; frame=""
    printf -v line '  %b%s%b %bwaiting%b %b(%ss · Ctrl+C stops waiting — services keep starting)%b' \
      "$MAGENTA" "${SPIN[i % 10]}" "$RESET" "$BOLD" "$RESET" "$GREY" "$t" "$RESET"
    frame+="$line"$'\e[K\n\e[K\n'
    for c in "${comps[@]}"; do
      st=${SNAP_STATE[$c]:-n/a}
      if [ "$st" != up ]; then
        if [ "$st" = crashed ] || fail_marker "$c"; then
          st=crashed; failed[$c]=1
        else
          pending=$((pending + 1))
        fi
        [ -z "$focus" ] && focus=$c
      fi
      state_icon "$st"
      printf -v line '    %b %-14s %b%s%b' "$R" "$c" "$GREY" "$st" "$RESET"
      frame+="$line"$'\e[K\n'
    done
    # live tail of the first not-yet-up service, so a slow or dying start is never a black box
    if [ -n "$focus" ] && [ -f "$LOG_DIR/$focus.log" ]; then
      frame+=$'\e[K\n'
      printf -v line '  %b── %s · live log ────────────────────────────────%b' "$GREY" "$focus" "$RESET"
      frame+="$line"$'\e[K\n'
      while IFS= read -r line; do
        frame+="    ${DIM}${line}${RESET}"$'\e[K\n'
      done < <(tail -n 80 "$LOG_DIR/$focus.log" 2>/dev/null | strip_ansi | grep -vE '^[[:space:]]*$' \
               | tail -10 | expand -t 4 | awk -v w="$w" '{ print substr($0, 1, w) }')
    fi
    nl=${frame//[^$'\n']/}
    [ "$drawn" -gt 0 ] && printf '\033[%dF' "$drawn"
    printf '%b\033[0J' "$frame"
    drawn=${#nl}
    [ "$pending" -eq 0 ] && break
    sleep 1; t=$((t + 1)); i=$((i + 1))
  done
  trap - INT
  printf '\033[?7h'; tput cnorm 2>/dev/null
  echo
  if [ ${#failed[@]} -eq 0 ] && [ "$pending" -eq 0 ]; then
    say "  ${GREEN}${BOLD}✔ everything is up!${RESET}"
    command -v notify-send >/dev/null && notify-send -i utilities-terminal "$PITCREW_PROJECT_NAME" "All services are up" 2>/dev/null
    return
  fi
  local any=0
  for c in "${comps[@]}"; do
    [ -n "${failed[$c]:-}" ] || continue
    any=1
    say "  ${RED}${BOLD}✗ $c failed to start${RESET} ${GREY}— last log lines:${RESET}"
    fail_tail "$c"
    say "  ${GREY}full log:${RESET} pitcrew logs $c"
    echo
  done
  if [ "$pending" -gt 0 ]; then
    say "  ${YELLOW}⚠ still waiting on some services — they keep starting in the background.${RESET}"
    say "  ${GREY}check progress with:${RESET} pitcrew ${GREY}(dashboard) ·${RESET} pitcrew logs"
  elif [ "$any" -eq 1 ]; then
    say "  ${GREY}fix the error and retry:${RESET} pitcrew restart <app>"
  fi
}

# Turn target words into components and start them. Shared by the CLI path
# (cmd_start, which wraps this in a banner, a boot dashboard and a URL table)
# and by the live dashboard, which needs exactly this work done with nothing
# printed over the frame it is drawing. Fills STARTED with what it touched.
# A RAM cap only protects you if it is smaller than the machine. Sixteen
# backends at the 8G default commit 128G on a 31G box — at which point the caps
# never fire and the kernel's OOM killer picks the victim instead, which is
# both slower and less predictable than being told up front.
ram_preflight() { # $@ = components about to start → RAM_WARN ("" when fine)
  RAM_WARN=""
  local c committed=0 n=$#
  for c in "$@"; do committed=$(( committed + ${COMP_MAX_B[$c]:-0} )); done
  [ "$committed" -gt 0 ] || return 0
  [ -n "${SYS_MEM_TOTAL_KB:-}" ] || sys_gauges
  local total=$(( ${SYS_MEM_TOTAL_KB:-0} * 1024 ))
  [ "$total" -gt 0 ] || return 0
  [ "$committed" -le "$total" ] && return 0
  human "$committed"; local ch=$HUMAN
  human "$total";     local th=$HUMAN
  RAM_WARN="$n services cap at ${ch} against ${th} of RAM — the caps cannot bite first, the OOM killer will"
  return 0
}

# How many components may be BOOTING at once. Launching twelve at a time is a
# thundering herd: six Gradle daemons and six Next dev servers all compiling
# against the same cores makes the machine unusable for a minute and is often
# slower, wall-clock, than starting them in waves. 0 disables the wait entirely
# (the old behaviour) for anyone who wants it back.
PITCREW_START_CONCURRENCY="${PITCREW_START_CONCURRENCY:-3}"
PITCREW_START_SLOT_SECS="${PITCREW_START_SLOT_SECS:-45}"   # give up waiting on one

_booting_count() { # how many of $@ are still on their way up
  local c n=0
  snapshot
  for c in "$@"; do
    case "${SNAP_STATE[$c]:-}" in starting) n=$((n + 1)) ;; esac
  done
  printf '%s' "$n"
}

_wait_for_slot() { # $@ = already-launched components
  [ "$PITCREW_START_CONCURRENCY" -gt 0 ] 2>/dev/null || return 0
  [ $# -ge "$PITCREW_START_CONCURRENCY" ] || return 0
  local waited=0
  while [ "$(_booting_count "$@")" -ge "$PITCREW_START_CONCURRENCY" ]; do
    sleep 1
    waited=$((waited + 1))
    # A service that never opens its port would otherwise hold the queue
    # forever. Move on and let the dashboard report it as still starting.
    [ "$waited" -ge "$PITCREW_START_SLOT_SECS" ] && return 0
  done
  return 0
}

start_targets() { # $@ = target words ("all" when empty)
  local words comps c
  mapfile -t words < <(expand_profiles "${@:-all}")
  mapfile -t comps < <(resolve_targets "${words[@]}")
  STARTED=()
  for c in "${comps[@]}"; do
    _wait_for_slot "${STARTED[@]}"
    start_comp "$c"
    STARTED+=("$c")
  done
  return 0
}

cmd_start() {
  banner
  local words; mapfile -t words < <(expand_profiles "${@:-all}")
  say "${BOLD}① deps${RESET}"
  start_deps
  [ ${#PITCREW_DEPS[@]} -eq 0 ] && ok "no deps configured"
  if [ "${words[*]}" = "deps" ]; then echo; return; fi
  echo
  say "${BOLD}② services${RESET}"
  local planned; mapfile -t planned < <(resolve_targets "${words[@]}")
  ram_preflight "${planned[@]}"
  [ -n "$RAM_WARN" ] && warn "$RAM_WARN"
  start_targets "${words[@]}"
  local comps=("${STARTED[@]}")
  say ""
  say "${BOLD}③ waiting for services${RESET} ${GREY}(Ctrl+C to stop waiting — they keep running)${RESET}"
  wait_dashboard "${comps[@]}"
  print_urls
}

# `pitcrew` with no subcommand: bring up whatever isn't already running, then
# drop straight into the live dashboard — one command, nothing to remember.
cmd_up() {
  local comps; mapfile -t comps < <(resolve_targets all)
  local c missing=() st
  snapshot
  for c in "${comps[@]}"; do
    st=${SNAP_STATE[$c]:-n/a}
    [ "$st" = up ] || [ "$st" = starting ] || missing+=("$c")
  done
  if [ ${#missing[@]} -gt 0 ] || [ ${#PITCREW_DEPS[@]} -gt 0 ]; then
    banner
    say "${BOLD}① deps${RESET}"
    start_deps
    [ ${#PITCREW_DEPS[@]} -eq 0 ] && ok "no deps configured"
    echo
    if [ ${#missing[@]} -gt 0 ]; then
      say "${BOLD}② services${RESET} ${GREY}(starting what isn't already up)${RESET}"
      for c in "${missing[@]}"; do start_comp "$c"; done
      say ""
      say "${BOLD}③ waiting for services${RESET} ${GREY}(Ctrl+C to stop waiting — they keep running)${RESET}"
      wait_dashboard "${missing[@]}"
      print_urls
    fi
  fi
  cmd_watch
}
