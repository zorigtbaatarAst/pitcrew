#!/usr/bin/env bash
# lib/01-core.sh — styling, printing helpers, and the couple of OS-agnostic
# process checks that don't belong in 00-platform.sh (which is specifically
# the per-OS branching file).

ESC=$'\e'
BOLD="$ESC[1m"; DIM="$ESC[2m"; RESET="$ESC[0m"
RED="$ESC[31m"; GREEN="$ESC[32m"; YELLOW="$ESC[33m"; BLUE="$ESC[34m"
MAGENTA="$ESC[35m"; CYAN="$ESC[36m"; GREY="$ESC[90m"
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
BARS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

say()  { printf '%b\n' "$*"; }
hr()   { printf '%b\n' "${GREY}──────────────────────────────────────────────────────────────────────${RESET}"; }
die()  { say "${RED}✗${RESET} $*" >&2; exit 1; }
ok()   { say "  ${GREEN}✔${RESET} $*"; }
bad()  { say "  ${RED}✗${RESET} $*"; }
warn() { say "  ${YELLOW}⚠${RESET} $*"; }

banner() {
  local title="${PITCREW_PROJECT_NAME:-pitcrew} · local dev" emoji="${PITCREW_EMOJI:-🏁}"
  local inner=$((${#title} + 6)) top
  printf -v top '─%.0s' $(seq 1 "$inner")
  say "${CYAN}${BOLD}"
  say "  ┌${top}┐"
  printf '  │  %s  %s  │\n' "$emoji" "$title"
  say "  └${top}┘"
  say "${RESET}"
}

# ── low-level checks ─────────────────────────────────────────────────────────
port_open() { [ -n "${1:-}" ] || return 1; timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

kill_port() { # gracefully stop whatever listens on the port (external processes)
  local port=$1 pid pgid comm t=0
  pid=$(port_pid "$port"); [ -n "$pid" ] || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null)
  [ "$comm" = "docker-proxy" ] && return 1   # that's a container's port — not ours to kill
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  kill -TERM -- "-${pgid:-$pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  while port_open "$port" && [ $t -lt 8 ]; do sleep 1; t=$((t + 1)); done
  if port_open "$port"; then
    kill -KILL -- "-${pgid:-$pid}" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    sleep 1
  fi
  port_open "$port" && return 1 || return 0
}

container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

scope_exists() { [ "$HAS_SYSTEMD" = 1 ] && systemctl --user is-active "$SESSION-$1.scope" >/dev/null 2>&1; }

strip_ansi() { # logs are raw captures — keep what a terminal would SHOW, not every redraw
  # final \x1b. + tr pass: NOTHING cursor-moving may survive, or the repaint math breaks
  sed -E \
    -e $'s/\x1b\\[[0-9;]*[ADFG]/\r/g' \
    -e $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' \
    -e $'s/\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)//g' \
    -e $'s/\x1bk[^\x1b]*\x1b\\\\//g' \
    -e $'s/\x1b.//g' \
    -e $'s/\r+$//' \
    -e 's/.*\r//' \
  | tr -d '\000-\010\013-\037'
}
