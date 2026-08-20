#!/usr/bin/env bash
# lib/01-core.sh — styling, printing helpers, and the couple of OS-agnostic
# process checks that don't belong in 00-platform.sh (which is specifically
# the per-OS branching file).

ESC=$'\e'
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# ── icons ────────────────────────────────────────────────────────────────────
# Nerd Font glyphs live in the Private Use Area, so a terminal without a
# patched font renders them as tofu boxes. That is a bad enough first
# impression that detection is not worth guessing at — this is opt-in via
# PITCREW_ICONS=nerd, and every other mode simply has no icon.
PITCREW_ICONS_ENV="${PITCREW_ICONS:-}"
PITCREW_ICONS="${PITCREW_ICONS:-unicode}"
icons_load() {
  if [ "$PITCREW_ICONS" = nerd ]; then
    I_JAVA=$'\ue738'; I_NODE=$'\ue718'; I_PY=$'\ue73c'; I_RUST=$'\ue7a8'
    I_GO=$'\ue627';  I_RUBY=$'\ue739'; I_DOCKER=$'\uf308'; I_APP=$'\uf0c8'
  else
    I_JAVA=""; I_NODE=""; I_PY=""; I_RUST=""; I_GO=""; I_RUBY=""; I_DOCKER=""; I_APP=""
  fi
  return 0
}
icons_load

app_icon_for() { # $1 start command(s) → ICON, guessed from what it runs
  case "$1" in
    *gradle*|*bootRun*|*mvn*|*java\ *|*.jar*) ICON=$I_JAVA ;;
    *npm*|*node*|*vite*|*next*|*yarn*|*pnpm*|*bun*) ICON=$I_NODE ;;
    *python*|*uvicorn*|*gunicorn*|*flask*|*django*) ICON=$I_PY ;;
    *cargo*) ICON=$I_RUST ;;
    *"go run"*|*"go build"*) ICON=$I_GO ;;
    *rails*|*bundle*|*ruby*) ICON=$I_RUBY ;;
    *) ICON=$I_APP ;;
  esac
}
BARS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

# ── palette ──────────────────────────────────────────────────────────────────
# Colours are addressed by ROLE, not by hue. `$RED` tells you nothing about
# what a thing is; `$C_CRIT` does, and it means the theme decides what critical
# looks like. A theme is still a plain bash file — it just sets hex values, and
# the conversion to whatever the terminal can actually display happens here.
#
# Three colour depths are supported and detected, not guessed at:
#   truecolor  24-bit, from $COLORTERM — what any modern terminal reports
#   16         the classic ANSI codes, for an old ssh target or TERM=linux
#   none       NO_COLOR, or a pipe
# Override with PITCREW_COLOR=truecolor|16|none.

pitcrew_color_depth() {
  case "${PITCREW_COLOR:-}" in truecolor|16|none) printf '%s' "$PITCREW_COLOR"; return ;; esac
  [ -n "${NO_COLOR:-}${PITCREW_NO_COLOR:-}" ] && { printf none; return; }
  case "${COLORTERM:-}" in truecolor|24bit) printf truecolor; return ;; esac
  printf 16
}
PITCREW_COLOR_DEPTH=$(pitcrew_color_depth)

_tok() { # $1 var name, $2 hex "rrggbb", $3 ANSI fallback code
  case "$PITCREW_COLOR_DEPTH" in
    none)      printf -v "$1" '' ;;
    truecolor) printf -v "$1" '%s[38;2;%d;%d;%dm' "$ESC" \
                 $((16#${2:0:2})) $((16#${2:2:2})) $((16#${2:4:2})) ;;
    *)         printf -v "$1" '%s[%sm' "$ESC" "$3" ;;
  esac
}

_bgtok() { # same, for a background
  case "$PITCREW_COLOR_DEPTH" in
    none)      printf -v "$1" '' ;;
    truecolor) printf -v "$1" '%s[48;2;%d;%d;%dm' "$ESC" \
                 $((16#${2:0:2})) $((16#${2:2:2})) $((16#${2:4:2})) ;;
    *)         printf -v "$1" '%s[%sm' "$ESC" "$3" ;;
  esac
}

# The default palette. A theme file overrides any of these T_* hex values and
# nothing else — it never touches escape sequences, so one theme file works at
# every colour depth.
theme_hex_defaults() {
  T_TEXT=cdd6f4      # primary text — values you read
  T_SUBTLE=9399b2    # secondary text — names you scan
  T_MUTED=6c7086     # chrome — ports, labels, separators
  T_FAINT=45475a     # barely there — baselines, placeholders
  T_SURFACE=313244   # selected-row background
  T_ACCENT=89b4fa    # primary accent
  T_ACCENT2=cba6f7   # secondary accent — keys, markers
  T_OK=a6e3a1
  T_WARN=f9e2af
  T_CRIT=f38ba8
  T_INFO=89dceb
  # graph ramp, bottom of the chart to the top
  T_G1=94e2d5; T_G2=a6e3a1; T_G3=f9e2af; T_G4=f38ba8
}

theme_apply() {
  BOLD="$ESC[1m"; DIM="$ESC[2m"; RESET="$ESC[0m"
  [ "$PITCREW_COLOR_DEPTH" = none ] && { BOLD=""; DIM=""; RESET=""; }

  _tok C_TEXT    "$T_TEXT"    0
  _tok C_SUBTLE  "$T_SUBTLE"  37
  _tok C_MUTED   "$T_MUTED"   90
  _tok C_FAINT   "$T_FAINT"   90
  _tok C_ACCENT  "$T_ACCENT"  36
  _tok C_ACCENT2 "$T_ACCENT2" 35
  _tok C_OK      "$T_OK"      32
  _tok C_WARN    "$T_WARN"    33
  _tok C_CRIT    "$T_CRIT"    31
  _tok C_INFO    "$T_INFO"    34
  _tok C_G1      "$T_G1"      36
  _tok C_G2      "$T_G2"      32
  _tok C_G3      "$T_G3"      33
  _tok C_G4      "$T_G4"      31
  _bgtok C_BAND  "$T_SURFACE" 100
  _bgtok C_CAP   "$T_FAINT"   100     # key caps / pills
  GRAMP=("$C_G1" "$C_G2" "$C_G3" "$C_G4")

  # Legacy names, kept as aliases so every existing call site still reads
  # correctly while the codebase migrates to roles.
  RED=$C_CRIT; GREEN=$C_OK; YELLOW=$C_WARN; BLUE=$C_INFO
  MAGENTA=$C_ACCENT2; CYAN=$C_ACCENT; GREY=$C_MUTED
  return 0
}

PITCREW_THEME_ENV="${PITCREW_THEME:-}"
PITCREW_COLOR_ENV="${PITCREW_COLOR:-}"
PITCREW_THEME_FILE="${PITCREW_THEME_FILE:-$HOME/.config/pitcrew/theme}"

theme_dirs() { printf '%s\n' "$HOME/.config/pitcrew/themes" "$LIB_DIR/../themes"; }

theme_list() { # every theme available, yours first, deduped
  local d f n
  { while IFS= read -r d; do
      [ -d "$d" ] || continue
      for f in "$d"/*.sh; do [ -f "$f" ] || continue; n=${f##*/}; printf '%s\n' "${n%.sh}"; done
    done < <(theme_dirs); } | awk '!seen[$0]++'
}

theme_save() { # remember a choice across runs
  mkdir -p "$(dirname "$PITCREW_THEME_FILE")" 2>/dev/null
  printf '%s\n' "$1" > "$PITCREW_THEME_FILE"
}

# Resolution order, most specific first: the environment (a one-off run), the
# project's own config (this repo always looks like this), the saved
# preference (how you like your terminal), then the built-in palette.
theme_resolve() {
  if   [ -n "$PITCREW_THEME_ENV" ]; then PITCREW_THEME=$PITCREW_THEME_ENV
  elif [ -n "${PITCREW_THEME:-}" ]; then :
  elif [ -r "$PITCREW_THEME_FILE" ]; then read -r PITCREW_THEME < "$PITCREW_THEME_FILE"
  else PITCREW_THEME=""
  fi
  [ -n "$PITCREW_COLOR_ENV" ] && PITCREW_COLOR=$PITCREW_COLOR_ENV
  PITCREW_COLOR_DEPTH=$(pitcrew_color_depth)
  return 0
}

theme_swatch() { # $1 theme name → one line showing what it looks like
  local name=$1 saved=${PITCREW_THEME:-}
  PITCREW_THEME_ENV=$name; theme_load
  printf '  %b%-11s%b %b██%b██%b██%b██%b  %bup%b %bstarting%b %bcrashed%b %b down %b\n' \
    "$C_ACCENT$BOLD" "$name" "$RESET" \
    "$C_G1" "$C_G2" "$C_G3" "$C_G4" "$RESET" \
    "$C_OK" "$RESET" "$C_WARN" "$RESET" "$C_CRIT" "$RESET" "$C_BAND$C_TEXT" "$RESET"
  PITCREW_THEME_ENV=$saved; theme_load
}

# `pitcrew theme` — runs before any project config is resolved, so it works
# from anywhere, like `init` does.
cmd_theme() {
  case "${1:-list}" in
    list|"")
      local t cur=${PITCREW_THEME:-default}
      say ""
      while IFS= read -r t; do
        theme_swatch "$t"
      done < <(theme_list)
      say ""
      say "  ${C_MUTED}current: ${RESET}${BOLD}${cur}${RESET}"
      say "  ${C_MUTED}pitcrew theme <name>   ·   saved to $PITCREW_THEME_FILE${RESET}"
      say "" ;;
    --swatch) [ -n "${2:-}" ] || die "usage: pitcrew theme --swatch <name>"
              theme_swatch "$2" ;;
    --reset)  rm -f "$PITCREW_THEME_FILE"; ok "theme preference cleared — back to the default" ;;
    *)
      theme_list | grep -qx -- "$1" || die "no theme '$1' — see: pitcrew theme"
      theme_save "$1"
      PITCREW_THEME_ENV=$1; theme_load
      ok "theme set to ${BOLD}$1${RESET}"
      theme_swatch "$1" ;;
  esac
}

theme_load() {
  theme_resolve
  theme_hex_defaults
  local name="${PITCREW_THEME:-}" f d
  if [ -n "$name" ]; then
    while IFS= read -r d; do
      f="$d/$name.sh"
      # shellcheck source=/dev/null
      [ -f "$f" ] && { source "$f"; break; }
    done < <(theme_dirs)
  fi
  theme_apply
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
port_open() { [ -n "${1:-}" ] || return 1; pf_timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

kill_port() { # gracefully stop whatever listens on the port (external processes)
  local port=$1 pid pgid comm t=0
  pid=$(port_pid "$port"); [ -n "$pid" ] || return 1
  comm=$("${PITCREW_PS[@]}" -o comm= -p "$pid" 2>/dev/null)
  comm=${comm##*/}                           # macOS prints comm as a full path
  [ "$comm" = "docker-proxy" ] && return 1   # that's a container's port — not ours to kill
  pgid=$("${PITCREW_PS[@]}" -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
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
  # While fzf or $PAGER owned the terminal, THEY got the SIGWINCH and we did
  # not. This is the one resize a dashboard reliably sleeps through, so coming
  # back is the one moment worth re-measuring unconditionally.
  TERM_DIRTY=1
  return 0
}
