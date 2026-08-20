#!/usr/bin/env bash
# The order lib/*.sh is sourced in.
#
# `for f in "$LIB_DIR"/*.sh` sorts by the current collation, and a UTF-8 locale
# IGNORES punctuation when comparing — so "05-dashboard.sh" sorts AFTER
# "05a-cells.sh" on a normal desktop and BEFORE it under LC_ALL=C. Files in this
# group have top-level code that reads what the previous one set, so a machine
# with a different locale would load them in a different order and fail with an
# unbound variable. Letters sort identically either way; this pins that.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

_order() { # $1 = LC_ALL → the lib filenames in the order bash would source them
  ( export LC_ALL="$1"
    cd "$PITCREW_DIR/lib" || exit 1
    for f in *.sh; do printf '%s ' "$f"; done )
}

test_the_source_order_does_not_depend_on_the_locale() {
  local c utf8
  c=$(_order C)
  utf8=$(_order en_US.UTF-8)
  assert_eq "$utf8" "$c" "same order under C and UTF-8 collation"
}

test_no_module_uses_a_name_that_sorts_ambiguously() {
  # A bare "NN-name.sh" next to any "NNx-name.sh" is the shape that breaks:
  # use a letter on both, or neither.
  local f base num ambiguous=""
  for f in "$PITCREW_DIR"/lib/*.sh; do
    base=${f##*/}
    case "$base" in
      [0-9][0-9]-*) num=${base%%-*}
                    ls "$PITCREW_DIR"/lib/"$num"[a-z]-*.sh >/dev/null 2>&1 \
                      && ambiguous="$ambiguous $base" ;;
    esac
  done
  assert_empty "$ambiguous" "bare NN- names sharing a number with NNx- names"
}

run_tests
