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
