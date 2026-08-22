#!/usr/bin/env bash
# setup.sh — take a fresh clone to a working pitcrew, on any OS.
#
# Everything here is idempotent: run it again after a pull and it re-checks
# rather than re-does. It is also bash 3.2 compatible, because on macOS one of
# the things it installs IS bash 5 — a setup script that needs what it installs
# is no use on the machine that needs it most.
#
# It installs nothing privileged on its own. --yes opts into the package step;
# without it that step reports and moves on.
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${PITCREW_BIN_DIR:-$HOME/.local/bin}"
ASSUME_YES=0
WANT_GUI=1

usage() {
  cat <<'USAGE'
usage: ./setup.sh [--yes] [--no-gui]

  --yes      allow the dependency step to install packages (it needs sudo on
             Linux). Without this it prints what it would run and continues.
  --no-gui   command line only: skip the desktop app entirely.
  --help

Safe to re-run. Set PITCREW_BIN_DIR to link somewhere other than ~/.local/bin.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)  ASSUME_YES=1; shift ;;
    --no-gui)  WANT_GUI=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '    \033[90m%s\033[0m\n' "$1"; }

have_bash5() {
  local candidate major
  for candidate in bash /opt/homebrew/bin/bash /usr/local/bin/bash; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2016  # expanded by the bash being interrogated
    major=$("$candidate" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0)
    [ "${major:-0}" -ge 5 ] 2>/dev/null && return 0
  done
  return 1
}

# shellcheck source=gui/pyfind.sh
. "$SELF_DIR/gui/pyfind.sh"

have_bindings() { pitcrew_find_python >/dev/null 2>&1; }

# ── 1. dependencies ─────────────────────────────────────────────────────────
step "1/4  dependencies"
DEPS_ARGS=""
[ "$ASSUME_YES" = 1 ] && DEPS_ARGS="--yes"
# Never let a refused or failed install abort the rest: linking the CLI still
# works without the GUI's bindings, and a partial setup beats none.
# shellcheck disable=SC2086
"$SELF_DIR/gui/install-deps.sh" $DEPS_ARGS 2>&1 | sed 's/^/  /' || true

# ── 2. the command ──────────────────────────────────────────────────────────
step "2/4  the pitcrew command"
"$SELF_DIR/install.sh" "$BIN_DIR" 2>&1 | sed 's/^/  /'
if ! have_bash5; then
  warn "no bash 5 yet — pitcrew will refuse to run until there is one"
  info "re-run with --yes, or install it yourself, then run ./setup.sh again"
fi

# ── 3. the desktop app ──────────────────────────────────────────────────────
step "3/4  the desktop app"
if [ "$WANT_GUI" = 0 ]; then
  info "skipped (--no-gui)"
elif have_bindings; then
  "$SELF_DIR/gui/install.sh" "$BIN_DIR" 2>&1 | sed 's/^/  /'
else
  warn "skipped — no python here can import the GTK bindings yet"
  info "install them (step 1 says how), then: make install-gui"
fi

# ── 4. what is left for you ─────────────────────────────────────────────────
step "4/4  next"
case ":$PATH:" in
  *":$BIN_DIR:"*) ok "$BIN_DIR is on your PATH" ;;
  *) warn "$BIN_DIR is NOT on your PATH — add it in your shell rc:"
     info "export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

if have_bash5 && [ -x "$BIN_DIR/pitcrew" ]; then
  # A fresh clone knows about no projects at all, which is the one thing setup
  # genuinely cannot guess: it does not know which checkout you meant.
  if "$BIN_DIR/pitcrew" projects >/dev/null 2>&1 && \
     [ -n "$(ls -1 "${PITCREW_HOME:-$HOME/.config/pitcrew}/projects" 2>/dev/null)" ]; then
    ok "you already have projects registered — just run: pitcrew"
  else
    ok "ready. Point it at a checkout:"
    info "pitcrew init ~/path/to/your/project"
    info "pitcrew doctor      # sanity-check what it guessed"
    info "pitcrew             # the dashboard"
  fi
else
  warn "finish the steps above, then re-run ./setup.sh"
fi
printf '\n'
