#!/usr/bin/env bash
# gui/install-deps.sh — install what pitcrew and its GUI need, on this OS.
#
# Two constraints shape this file:
#
#   1. It CANNOT be written in python-with-gi. The GTK bindings are the main
#      thing it installs, so anything that imports them cannot be what installs
#      them.
#   2. It CANNOT use bash 5. On macOS bash 5 is one of the things it installs,
#      so it has to run under the 3.2 Apple ships — no associative arrays, no
#      ${var,,}, no readarray. Everything below is POSIX-ish bash 3.2.
#
# It never runs a privileged command on its own. The default prints the exact
# command and stops; --yes is how you say go ahead. Installing system packages
# is not something a tool should do to you because you ran its installer.
set -eu

usage() {
  cat <<'USAGE'
usage: gui/install-deps.sh [--yes] [--dry-run]

  --yes       actually run the install command (default: print it and stop)
  --dry-run   print the plan and exit 0 even if things are missing
  --help

Installs: PyGObject, pycairo, GTK 4, libadwaita — and bash 5 where the system
bash is older than pitcrew accepts.

Override the detected package manager with PITCREW_PKG=dnf|apt|pacman|zypper|apk|brew|msys2.
USAGE
}

# ── which package manager ───────────────────────────────────────────────────
detect_pkg() {
  if [ -n "${PITCREW_PKG:-}" ]; then printf '%s' "$PITCREW_PKG"; return 0; fi
  case "$(uname -s)" in
    Darwin) command -v brew >/dev/null 2>&1 && { printf brew; return 0; }
            printf 'none-brew'; return 0 ;;
    MINGW*|MSYS*) printf msys2; return 0 ;;
  esac
  local candidate
  for candidate in dnf apt-get pacman zypper apk; do
    if command -v "$candidate" >/dev/null 2>&1; then
      [ "$candidate" = apt-get ] && printf apt || printf '%s' "$candidate"
      return 0
    fi
  done
  printf unknown
}

# ── what each manager calls the same four things ────────────────────────────
# One case, one line per OS: this is the whole platform seam for dependencies.
packages_for() { # $1 = manager
  case "$1" in
    dnf)    echo "python3-gobject python3-cairo gtk4 libadwaita" ;;
    apt)    echo "python3-gi python3-gi-cairo gir1.2-gtk-4.0 gir1.2-adw-1" ;;
    pacman) echo "python-gobject python-cairo gtk4 libadwaita" ;;
    zypper) echo "python3-gobject python3-cairo typelib-1_0-Gtk-4_0 typelib-1_0-Adw-1" ;;
    apk)    echo "py3-gobject3 py3-cairo gtk4.0 libadwaita" ;;
    brew)   echo "pygobject3 gtk4 libadwaita" ;;
    # pycairo is a SEPARATE package here, and it was missing: PyGObject does
    # not pull it in on MSYS2 the way brew and the Linux distros do, so
    # `import gi, cairo` failed on the cairo half and the probe reported the
    # bindings missing right after a successful install.
    msys2)  echo "mingw-w64-ucrt-x86_64-python-gobject mingw-w64-ucrt-x86_64-python-cairo mingw-w64-ucrt-x86_64-gtk4 mingw-w64-ucrt-x86_64-libadwaita" ;;
    *)      echo "" ;;
  esac
}

install_command_for() { # $1 = manager, $2 = package list
  case "$1" in
    dnf)    echo "sudo dnf install -y $2" ;;
    apt)    echo "sudo apt-get install -y $2" ;;
    pacman) echo "sudo pacman -S --needed --noconfirm $2" ;;
    zypper) echo "sudo zypper install -y $2" ;;
    apk)    echo "sudo apk add $2" ;;
    brew)   echo "brew install $2" ;;
    msys2)  echo "pacman -S --needed --noconfirm $2" ;;
    *)      echo "" ;;
  esac
}

bash5_package_for() { # $1 = manager — only where the system bash is too old
  case "$1" in brew) echo "bash" ;; *) echo "" ;; esac
}

# ── what is actually missing ────────────────────────────────────────────────
# The interpreter search lives in one file for every script that needs it. It
# used to be copied into three, all of which looked only in Unix places — so on
# MSYS2 this reported MISSING immediately after a successful pacman install.
# shellcheck source=gui/pyfind.sh
. "$(dirname "${BASH_SOURCE[0]}")/pyfind.sh"

have_bindings() { pitcrew_find_python_gtk >/dev/null 2>&1; }

have_bash5() {
  local candidate major
  for candidate in bash /opt/homebrew/bin/bash /usr/local/bin/bash; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    # Single-quoted on purpose: the INVOKED bash expands this, not us — that is
    # the whole point of asking it its own version.
    # shellcheck disable=SC2016
    major=$("$candidate" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0)
    [ "${major:-0}" -ge 5 ] 2>/dev/null && return 0
  done
  return 1
}

# ── the run ─────────────────────────────────────────────────────────────────
# Everything above is tables and probes with no side effects, so the test suite
# can source this file (PITCREW_DEPS_LIB=1) and check what each OS would get
# without any of them being installed.
main() {
  local ASSUME_YES=0 DRY_RUN=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y)  ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --help|-h) usage; return 0 ;;
      *) echo "unknown argument: $1" >&2; usage >&2; return 2 ;;
    esac
  done

  local PKG WANT extra CMD need_bindings=0 need_bash=0
  PKG=$(detect_pkg)
  have_bindings || need_bindings=1
  have_bash5 || need_bash=1

  # Track what is MISSING separately from what we know how to install. An empty
  # package list means "no idea what this OS calls these", which is a different
  # answer from "nothing to do" — and reporting the second when the first is
  # true sends someone away believing they are ready.
  WANT=""
  [ "$need_bindings" = 1 ] && WANT="$(packages_for "$PKG")"
  if [ "$need_bash" = 1 ]; then
    extra=$(bash5_package_for "$PKG")
    [ -n "$extra" ] && WANT="$WANT $extra"
  fi
  WANT=$(echo "$WANT" | sed -e 's/^ *//' -e 's/ *$//')

  echo "platform         $(uname -s)"
  echo "package manager  $PKG"
  have_bindings && echo "GTK bindings     present" || echo "GTK bindings     MISSING"
  have_bash5    && echo "bash 5           present" || echo "bash 5           MISSING"
  echo

  if [ "$need_bindings" = 0 ] && [ "$need_bash" = 0 ]; then
    echo "Nothing to install — everything pitcrew and its GUI need is already here."
    echo "Optional extras pitcrew will use if present: fzf (menus), lsof (port lookups), docker (deps)."
    return 0
  fi

  case "$PKG" in
    none-brew)
      echo "Homebrew is not installed, and it is how macOS gets these." >&2
      echo "  https://brew.sh   then re-run this script" >&2
      [ "$DRY_RUN" = 1 ] && return 0
      return 1 ;;
    unknown)
      echo "No package manager I recognise on $(uname -s)." >&2
      echo "Install these by hand: PyGObject, pycairo, GTK 4, libadwaita." >&2
      echo "Then re-run to confirm: gui/install-deps.sh --dry-run" >&2
      [ "$DRY_RUN" = 1 ] && return 0
      return 1 ;;
  esac

  CMD=$(install_command_for "$PKG" "$WANT")
  if [ -z "$WANT" ] || [ -z "$CMD" ]; then
    echo "Something is missing, but I do not know what $PKG calls it." >&2
    echo "Install by hand: PyGObject, pycairo, GTK 4, libadwaita" >&2
    [ "$need_bash" = 1 ] && echo "  ...and a bash 5.0 or newer" >&2
    [ "$DRY_RUN" = 1 ] && return 0
    return 1
  fi
  echo "Missing. This would run:"
  echo
  echo "  $CMD"
  echo

  if [ "$DRY_RUN" = 1 ]; then
    echo "(--dry-run; nothing was run)"
    return 0
  fi

  if [ "$ASSUME_YES" != 1 ]; then
    # Not a prompt by default: a script that installs system packages the moment
    # you run it is a script people learn not to run.
    echo "Re-run with --yes to let it, or copy the line above and run it yourself."
    return 0
  fi

  echo "running…"
  # Deliberately unquoted: $CMD is built from the fixed tables above, never from
  # user input, and it has to word-split into a command and its arguments.
  # shellcheck disable=SC2086
  $CMD

  echo
  if have_bindings && have_bash5; then
    echo "✔ all present now"
    return 0
  fi
  echo "still missing something after installing — check the output above" >&2
  return 1
}

if [ "${PITCREW_DEPS_LIB:-0}" != 1 ]; then
  main "$@"
fi
