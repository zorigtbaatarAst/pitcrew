#!/usr/bin/env bash
# lib/00-core.sh — styling, printing helpers, low-level port/process/tmux checks.
# No project knowledge here — everything that touches app names, ports, or
# commands lives in 01-config.sh and up.

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
  local inner=$((${#title} + 6)) pad top bot
  printf -v top '─%.0s' $(seq 1 "$inner")
  say "${CYAN}${BOLD}"
  say "  ┌${top}┐"
  printf '  │  %s  %s  │\n' "$emoji" "$title"
  say "  └${top}┘"
  say "${RESET}"
}

# ── low-level checks ─────────────────────────────────────────────────────────
port_open() { [ -n "${1:-}" ] || return 1; timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

port_pid() { ss -tlnpH "sport = :$1" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1; }

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

win_exists() { tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx "$1"; }
win_dead()   { [ "$(tmux list-panes -t "$SESSION:$1" -F '#{pane_dead}' 2>/dev/null | head -1)" = "1" ]; }

container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

scope_exists() { systemctl --user is-active "$SESSION-$1.scope" >/dev/null 2>&1; }

ensure_session() {
  tmux has-session -t "$SESSION" 2>/dev/null \
    || tmux new-session -d -s "$SESSION" -n _dash -c "$ROOT"
  tmux set-option -t "$SESSION" remain-on-exit on
}

attach_to() {
  if [ -n "${TMUX:-}" ]; then tmux switch-client -t "$1"; else tmux attach -t "$1"; fi
}

strip_ansi() { # logs are raw pane captures — keep what a terminal would SHOW, not every redraw
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
