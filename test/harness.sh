#!/usr/bin/env bash
# test/harness.sh — a tiny assert library, deliberately dependency-free.
#
# pitcrew installs with `ln -s` and runs anywhere bash does, including over
# ssh on a box you don't control. A test suite that needs bats, npm or a
# submodule before it will run contradicts that, so this is ~70 lines of bash
# instead. It reports one line per test and a summary, and exits non-zero if
# anything failed — which is all CI needs.
#
# A test is any function named test_*. Assertions record failures against the
# running test rather than aborting, so one test can report several problems.

# ── the environment these tests are ABOUT ───────────────────────────────────
#
# pitcrew draws box-drawing and braille characters and emits 24-bit colour, and
# a lot of the assertions below are about exactly those bytes. Both are
# properties of the TERMINAL, not of pitcrew — so inheriting them from whoever
# happens to be running the suite makes the result depend on their shell.
#
# That is not theoretical. CI has no COLORTERM and no LANG, so it ran every
# palette assertion against 16-colour escapes and counted `█` as three
# characters instead of one — and the suite failed there while passing on every
# developer's machine, for months.
#
# So: pin both. A test that wants a different depth still sets PITCREW_COLOR
# itself; this is the default it overrides.
_pick_utf8_locale() {
  local candidate
  for candidate in "${LC_ALL:-}" "${LANG:-}" en_US.UTF-8 C.UTF-8 en_GB.UTF-8; do
    [ -n "$candidate" ] || continue
    # Not "does this locale exist" but "can bash do the two things the
    # assertions need in it" — and both have bitten. COUNT a multibyte
    # character, which every width assertion depends on; and accept a
    # multibyte RANGE in a regex, which C.UTF-8 refuses outright with
    # "Invalid collation character" — so a gauge that drew perfectly still
    # failed its test.
    LC_ALL=$candidate bash -c \
      'hi=$(printf "\u2588"); lo=$(printf "\u2581")
       [ ${#hi} = 1 ] && [[ $hi =~ [$lo-$hi] ]]' 2>/dev/null && {
        printf '%s' "$candidate"; return 0; }
  done
  return 1
}
_PITCREW_TEST_LOCALE=$(_pick_utf8_locale) && export LC_ALL="$_PITCREW_TEST_LOCALE"
export PITCREW_COLOR="${PITCREW_COLOR:-truecolor}"

_T_RUN=0; _T_FAIL=0; _T_NAME=""; _T_OK=1; _T_MSGS=()

_t_bad() { _T_OK=0; _T_MSGS+=("$1"); }

assert_eq() { # $1 actual, $2 expected, $3 label
  [ "$1" = "$2" ] || _t_bad "${3:-value}: expected [$2] got [$1]"
}

assert_ne() { # $1 actual, $2 unexpected, $3 label
  [ "$1" != "$2" ] || _t_bad "${3:-value}: expected anything but [$2]"
}

assert_match() { # $1 actual, $2 ERE, $3 label
  [[ $1 =~ $2 ]] || _t_bad "${3:-value}: [$1] does not match /$2/"
}

assert_not_match() { # $1 actual, $2 ERE, $3 label
  [[ $1 =~ $2 ]] && _t_bad "${3:-value}: [$1] unexpectedly matches /$2/"
  return 0
}

# NOTE: unlike the assertions above these take a COMMAND, not a value and a
# label — `assert_ok test -d "$d" "some label"` runs `test` with three
# arguments and fails for the wrong reason.
#
# Both also run the command in a SUBSHELL. pitcrew reports fatal config and
# target errors through die(), which calls `exit 1` — run in the current shell
# that would kill the test runner itself, and the suite would report a partial
# pass with no summary. Isolation is not optional here.
assert_ok() { # $@ = command that must succeed
  ( "$@" ) >/dev/null 2>&1 || _t_bad "expected success: $*"
  return 0
}

assert_fails() { # $@ = command that must fail
  ( "$@" ) >/dev/null 2>&1 && _t_bad "expected failure: $*"
  return 0
}

assert_empty() { [ -z "$1" ] || _t_bad "${2:-value}: expected empty, got [$1]"; }

# strip SGR colour so assertions compare text, not escape codes
plain() { printf '%s' "$1" | sed -e $'s/\x1b\\[[0-9;]*m//g'; }

# Every distinct CHARACTER in $1, once each, in UNIQ_CHARS.
#
# In bash rather than `fold -w1 | sort -u`, because GNU fold counts BYTES
# unless the build carries the multibyte patch — Fedora's does, Git for
# Windows' does not. So on Windows a 3-byte block character became three
# separate bytes and `sort` gave up on the invalid sequences. Every assertion
# using this is about the characters a terminal DRAWS, which is the one thing
# a byte split cannot answer.
_uniq_chars() { # $1 text → UNIQ_CHARS
  local s=$1 i ch out=""
  for ((i = 0; i < ${#s}; i++)); do
    ch=${s:i:1}
    case "$out" in *"$ch"*) ;; *) out+=$ch ;; esac
  done
  UNIQ_CHARS=$out
}

run_tests() {
  local fn
  printf '\n\033[1m%s\033[0m\n' "${0##*/}"
  for fn in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
    _T_NAME=$fn; _T_OK=1; _T_MSGS=(); _T_RUN=$((_T_RUN + 1))
    "$fn"
    if [ "$_T_OK" = 1 ]; then
      printf '  \033[32m✓\033[0m %s\n' "${fn#test_}"
    else
      _T_FAIL=$((_T_FAIL + 1))
      printf '  \033[31m✗\033[0m %s\n' "${fn#test_}"
      local m; for m in "${_T_MSGS[@]}"; do printf '      \033[90m%s\033[0m\n' "$m"; done
    fi
  done
  printf '  \033[90m%d run, %d failed\033[0m\n' "$_T_RUN" "$_T_FAIL"
  [ "$_T_FAIL" -eq 0 ]
}

# ── portability of the harness itself ───────────────────────────────────────
#
# Two things the suite kept getting wrong about other people's machines, both
# of which failed as a dozen unrelated assertions rather than as one message.

# `mktemp --suffix` is GNU-only. BSD mktemp (macOS) rejects the flag, so the
# command failed, the variable came back EMPTY, and every test that wrote a
# sample config wrote it to nowhere — then asserted about a file that was never
# there. One directory per test file, so nothing is left behind but an empty
# one.
TEST_TMP=$(mktemp -d)
_TEST_TMP_N=0
temp_file() { # $1 = suffix, e.g. .yaml → a path in this run's temp dir
  _TEST_TMP_N=$((_TEST_TMP_N + 1))
  printf '%s/sample%d%s' "$TEST_TMP" "$_TEST_TMP_N" "$1"
}

# A path as this machine's PYTHON understands it. On Windows the interpreter
# that has the GTK bindings is a NATIVE build — MSYS2's ucrt64 python — and it
# cannot resolve `/d/a/pitcrew/gui`. MSYS2 rewrites paths it sees in a program's
# ARGUMENTS, but not ones sitting inside a `python -c` script, which is where
# every one of these lives: the GUI suite put its own directory on sys.path
# that way, the import failed, and all 107 tests behind that guard skipped
# themselves on every Windows run.
#
# `cygpath -m` spells it `D:/a/pitcrew/gui` — forward slashes, so it is also
# safe inside a single-quoted Python string. Everywhere else this is identity.
py_path() { # $1 path → the same path, spelled for python
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# ── loading pitcrew itself ──────────────────────────────────────────────────
# Mirrors bin/pitcrew's load sequence. The config MUST be sourced at the top
# level (not inside a function) for the same reason bin/pitcrew does it there:
# a bare `declare -A` in a sourced file is scoped to the running function.
PITCREW_DIR=${PITCREW_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
LIB_DIR="$PITCREW_DIR/lib"

# Tests must never read or write the developer's real pitcrew state. Without
# this, a saved theme preference or a registered project on this machine would
# quietly change what the assertions see — and the suite would pass or fail
# depending on whose laptop it ran on.
export PITCREW_HOME="${PITCREW_TEST_HOME:-$(mktemp -d)}"
export PITCREW_THEME_FILE="$PITCREW_HOME/theme"
export PITCREW_RENDER_FILE="$PITCREW_HOME/render"

load_pitcrew() { # $1 = project dir (defaults to the bundled fixture)
  local proj=${1:-$PITCREW_DIR/test/fixture}
  local f
  for f in "$LIB_DIR"/*.sh; do
    # shellcheck source=/dev/null
    source "$f"
  done
  PITCREW_CFG="$proj/pitcrew.config.sh"
  config_defaults
  ROOT=$(cd "$proj" && pwd)
}
