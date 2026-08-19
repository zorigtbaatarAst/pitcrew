#!/usr/bin/env bash
# lib/01-core.sh — styling, printing helpers, and the couple of OS-agnostic
# process checks that don't belong in 00-platform.sh (which is specifically
# the per-OS branching file).

ESC=$'\e'
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
BARS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

# ── palette ──────────────────────────────────────────────────────────────────
# A theme is a plain bash file that reassigns these variables — no new format,
# no parser. Looked up as $PITCREW_THEME in ~/.config/pitcrew/themes/<name>.sh
# first (yours), then themes/<name>.sh in this repo (shipped).
theme_defaults() {
  BOLD="$ESC[1m"; DIM="$ESC[2m"; RESET="$ESC[0m"
  RED="$ESC[31m"; GREEN="$ESC[32m"; YELLOW="$ESC[33m"; BLUE="$ESC[34m"
  MAGENTA="$ESC[35m"; CYAN="$ESC[36m"; GREY="$ESC[90m"
}

theme_load() {
  theme_defaults
  local name="${PITCREW_THEME:-}" f
  if [ -n "$name" ]; then
    for f in "$HOME/.config/pitcrew/themes/$name.sh" "$LIB_DIR/../themes/$name.sh"; do
      # shellcheck source=/dev/null
      [ -f "$f" ] && { source "$f"; break; }
    done
  fi
  # NO_COLOR is a documented cross-tool convention; honor it last so it wins
  # over any theme. Every format string goes through %b, so empty is safe.
  if [ -n "${NO_COLOR:-}${PITCREW_NO_COLOR:-}" ]; then
    BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""
    MAGENTA=""; CYAN=""; GREY=""
  fi
  return 0
}
theme_load

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

# ── terminal input ───────────────────────────────────────────────────────────
# read_key [timeout] — read one keypress and decode it to a symbolic name in
# $KEY. Returns 1 (and leaves KEY empty) on timeout, so a caller can tell
# "nothing happened, just repaint" from "the user pressed something".
#
# KEY is one of: up down left right enter tab esc mouse <literal char>
# On KEY=mouse, MOUSE_BTN/MOUSE_X/MOUSE_Y/MOUSE_REL describe the SGR (1006)
# report — see tui_enter for where that mode gets enabled.
#
# Every dashboard in this tool shares this one parser. Escape sequences arrive
# as several separate bytes, so the follow-up reads use a short timeout: long
# enough for the rest of a real sequence to land (even over ssh), short enough
# that a lone Esc press isn't mistaken for the start of one.
PITCREW_ESC_WAIT="${PITCREW_ESC_WAIT:-0.05}"

read_key() {
  local t=${1:-1} c intro body ch
  KEY=""
  IFS= read -rsn1 -t "$t" c 2>/dev/null || return 1
  # A terminal sends CR for Enter; `read -n1` reports LF as an empty string
  # because it is the line delimiter. Both mean Enter.
  [ -z "$c" ] || [ "$c" = $'\r' ] && { KEY=enter; return 0; }
  [ "$c" = $'\t' ] && { KEY=tab;   return 0; }
  [ "$c" = $'\e' ] || { KEY=$c;    return 0; }

  intro=""
  IFS= read -rsn1 -t "$PITCREW_ESC_WAIT" intro 2>/dev/null
  case "$intro" in
    '['|O) ;;              # CSI, or SS3 (some terminals send ESC O A for arrows)
    *) KEY=esc; return 0 ;;
  esac

  # consume up to the sequence's final byte — alphabetic, or '~' for the
  # numbered keys (ESC [ 5 ~ = PageUp). SGR mouse ends in M/m, also alphabetic.
  body=""
  while IFS= read -rsn1 -t "$PITCREW_ESC_WAIT" ch 2>/dev/null; do
    body+=$ch
    case "$ch" in [A-Za-z~]) break ;; esac
  done

  case "$body" in
    A) KEY=up ;;  B) KEY=down ;;  C) KEY=right ;;  D) KEY=left ;;
    '<'*)
      local m=${body#<} tail=${body: -1}
      m=${m%?}                                   # drop the trailing M/m
      MOUSE_BTN=${m%%;*}; m=${m#*;}
      MOUSE_X=${m%%;*};   MOUSE_Y=${m#*;}
      MOUSE_REL=0; [ "$tail" = m ] && MOUSE_REL=1
      KEY=mouse ;;
    *) KEY="" ;;                                 # some other CSI — swallowed
  esac
  return 0
}

# ── terminal state ───────────────────────────────────────────────────────────
# One entry/exit point for the alt screen, cursor visibility, auto-wrap and
# mouse reporting. tui_leave is idempotent and installed on EXIT, so an
# unexpected `die` (or a syntax error) inside a full-screen view can never
# leave the user with a hidden cursor, wrapping off, or — worse — a terminal
# still spraying mouse escape codes.
TUI_ACTIVE=0

tui_enter() {
  [ "$TUI_ACTIVE" = 1 ] && return 0
  TUI_ACTIVE=1
  tput smcup 2>/dev/null; tput civis 2>/dev/null
  printf '\033[?7l'                              # no auto-wrap: a too-wide line
                                                 # must not break repaint math
  [ "${PITCREW_MOUSE:-0}" = 1 ] && printf '\033[?1000;1006h'
  trap tui_leave EXIT
  return 0
}

tui_leave() {
  [ "$TUI_ACTIVE" = 1 ] || return 0
  TUI_ACTIVE=0
  printf '\033[?1000;1006l\033[?7h'              # harmless if never enabled
  tput cnorm 2>/dev/null; tput rmcup 2>/dev/null
  return 0
}

# Hand the terminal back to a child that wants it (fzf, $PAGER, an interactive
# shell) without tearing down the alt screen we'll return to.
tui_pause() {
  printf '\033[?1000;1006l\033[?7h'
  tput cnorm 2>/dev/null
  return 0
}

tui_resume() {
  tput civis 2>/dev/null
  printf '\033[?7l'
  [ "${PITCREW_MOUSE:-0}" = 1 ] && printf '\033[?1000;1006h'
  return 0
}
