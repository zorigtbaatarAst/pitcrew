#!/usr/bin/env bash
# Key decoding. Terminals deliver a keypress as several separate bytes, and
# every full-screen view in the tool shares this one parser — a regression
# here breaks navigation everywhere at once.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew

key_for() { KEY=""; MOUSE_BTN=""; MOUSE_X=""; MOUSE_Y=""; MOUSE_REL=""
            read_key 1 < <(printf '%b' "$1"); printf '%s' "$KEY"; }

test_plain_keys() {
  assert_eq "$(key_for 'q')"    q     "letter"
  assert_eq "$(key_for '\t')"   tab   "tab"
  assert_eq "$(key_for '5')"    5     "digit"
}

test_enter_arrives_as_cr_or_lf() {
  # a terminal sends CR; `read -n1` reports LF as an empty string because it is
  # the line delimiter. Both mean Enter.
  assert_eq "$(key_for '\r')" enter "carriage return"
  assert_eq "$(key_for '\n')" enter "line feed"
}

test_arrows_in_both_csi_and_ss3_forms() {
  assert_eq "$(key_for '\033[A')" up    "CSI up"
  assert_eq "$(key_for '\033[B')" down  "CSI down"
  assert_eq "$(key_for '\033[C')" right "CSI right"
  assert_eq "$(key_for '\033[D')" left  "CSI left"
  assert_eq "$(key_for '\033OA')" up    "SS3 up (some terminals)"
}

test_bare_escape_is_not_mistaken_for_a_sequence() {
  assert_eq "$(key_for '\033')" esc "lone Esc"
}

test_unhandled_sequences_are_swallowed_whole() {
  # PageUp is ESC [ 5 ~ — if the trailing '~' leaks it becomes a stray
  # keypress that triggers whatever is bound to it
  assert_empty "$(key_for '\033[5~')" "PageUp consumed entirely"
}

test_sgr_mouse_reports() {
  assert_eq "$(key_for '\033[<0;12;5M')" mouse "press decodes"
  read_key 1 < <(printf '%b' '\033[<0;12;5M')
  assert_eq "$MOUSE_BTN" 0  "button"
  assert_eq "$MOUSE_X"   12 "column"
  assert_eq "$MOUSE_Y"   5  "row"
  assert_eq "$MOUSE_REL" 0  "press, not release"
  read_key 1 < <(printf '%b' '\033[<64;30;9m')
  assert_eq "$MOUSE_BTN" 64 "wheel button"
  assert_eq "$MOUSE_REL" 1  "release"
}

test_timeout_is_distinguishable_from_a_keypress() {
  # the frame loop repaints on timeout and acts on a key; conflating them
  # either freezes the dashboard or spins it
  KEY=x
  read_key 0.1 < /dev/null
  local rc=$?
  assert_eq "$rc" 1 "returns non-zero on timeout"
  assert_empty "$KEY" "KEY cleared"
}

run_tests
