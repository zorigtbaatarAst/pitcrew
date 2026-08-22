#!/usr/bin/env bash
# gui/pyfind.sh — "which python on this box can import the GTK bindings?", once.
#
# Sourced by setup.sh, gui/install.sh and gui/install-deps.sh. This had been
# copied into all three, and every copy looked in the same four Unix places:
#
#   /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 python3
#
# On MSYS2 none of those is the right answer. The GTK stack lives in a mingw
# PREFIX (/ucrt64, /mingw64, /clang64) and /usr/bin/python3 is a different
# interpreter that will never have `gi` no matter what you install. So all
# three copies concluded the bindings were missing: setup.sh skipped the
# desktop app, install.sh refused to write the Start Menu shortcut on the
# grounds that it "would not run", and install-deps.sh reported MISSING
# immediately after installing them successfully. Windows had a desktop app
# that could not be installed by any sequence of documented commands.
#
# bash 3.2 throughout, and no side effects: install-deps.sh sources this before
# bash 5 exists on macOS, and pitcrew's own lib/ is not available here.

# Every interpreter worth trying, most likely first, one per line.
#
# The last entry is always a BARE NAME, so a machine that keeps its python
# somewhere nobody predicted is still reachable through $PATH. A list of
# absolute paths is exactly how this broke on macOS the first time.
pitcrew_python_candidates() {
  local prefix root
  case "$(uname -s)" in
    Darwin)
      printf '%s\n' /opt/homebrew/bin/python3 /usr/local/bin/python3 python3
      return 0 ;;
    MINGW*|MSYS*|CYGWIN*)
      # $MINGW_PREFIX is set by the MSYS2 shell you actually opened — UCRT64,
      # MINGW64 or CLANG64 — so it is right before any guess is.
      [ -n "${MINGW_PREFIX:-}" ] && printf '%s\n' \
        "$MINGW_PREFIX/bin/python3.exe" "$MINGW_PREFIX/bin/python.exe"
      for prefix in /ucrt64 /mingw64 /clang64 /mingw32; do
        [ "$prefix" = "${MINGW_PREFIX:-}" ] && continue      # already first
        printf '%s\n' "$prefix/bin/python3.exe" "$prefix/bin/python.exe"
      done
      # Git Bash mounts nothing at /ucrt64; from there MSYS2 is a normal
      # directory on the C: drive. Both spellings, because which one exists
      # depends on which bash the user happened to open, not on the machine.
      for root in /c/msys64 /c/msys32 "${MSYS2_ROOT:-}"; do
        [ -n "$root" ] || continue
        for prefix in ucrt64 mingw64 clang64; do
          printf '%s\n' "$root/$prefix/bin/python3.exe" "$root/$prefix/bin/python.exe"
        done
      done
      printf '%s\n' python3 python
      return 0 ;;
  esac
  printf '%s\n' /usr/bin/python3 python3
}

# The first candidate that satisfies a probe, as an ABSOLUTE path.
#
# Absolute matters: gui/install.sh puts this straight into a Windows shortcut,
# and a .lnk whose target is the word "python3" is a shortcut to nothing. The
# callers that only want a yes/no ignore the value.
#
#   $1  python expression to test with (default: the bindings themselves)
pitcrew_find_python() {
  local probe=${1:-'import gi, cairo'}
  local candidate resolved
  # A herestring would need bash 3.2's `<<<` inside a loop reading a function's
  # output; a plain command substitution and word splitting is simpler and the
  # paths here never contain spaces (they are prefixes, not user directories).
  for candidate in $(pitcrew_python_candidates); do
    resolved=$(command -v "$candidate" 2>/dev/null) || continue
    [ -n "$resolved" ] || continue
    # Prefer the .exe where the bare name is not itself a file. On Windows the
    # answer to this question is handed to CreateProcess and written into a
    # .lnk, and a name the shell can resolve is not always a name Windows can.
    if [ ! -f "$resolved" ] && [ -f "$resolved.exe" ]; then resolved="$resolved.exe"; fi
    "$resolved" -c "$probe" >/dev/null 2>&1 || continue
    case "$resolved" in
      /*|[A-Za-z]:*) printf '%s' "$resolved" ;;
      # `command -v` answers a bare name with a bare name when it is a shell
      # builtin or a function; neither can be a python, so take the input.
      *) printf '%s' "$candidate" ;;
    esac
    return 0
  done
  return 1
}

# The narrower question install-deps.sh asks: the Python bindings are one
# package and the Gtk/Adw typelibs are another, and having the first without
# the second is a GUI that dies on its first import.
pitcrew_find_python_gtk() {
  pitcrew_find_python 'import gi, cairo; gi.require_version("Gtk","4.0"); gi.require_version("Adw","1")'
}
