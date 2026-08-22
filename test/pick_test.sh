#!/usr/bin/env bash
# pick() — the one chooser every menu in the tool goes through.
#
# This file exists because of a bug that only ever showed up on somebody else's
# machine. Every picker shelled out to fzf directly, and nothing ships fzf on a
# stock macOS: `pitcrew menu` died on the spot, and the dashboard's `m` — which
# the key row advertises — hit a bare `command -v fzf || return` and did
# NOTHING AT ALL. doctor had been claiming menus "fall back to plain prompts"
# the whole time, and there was no such fallback.
#
# So two things are pinned here. The behaviour of the fallback, through
# _pick_resolve — which is pure precisely so the fiddly half can be tested
# without a terminal. And the structure: no picker anywhere may talk to fzf
# itself or guard itself on fzf being installed.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
SELF="$PITCREW_DIR/bin/pitcrew"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

# Stands in for the picker: prints its own argv, one per line, so a test can
# assert on what fzf was actually asked for.
_fzf_argv() {
  fzf() { printf '%s\n' "$@"; }
  PITCREW_PICKER=fzf pick "$@"
}

# ── what reaches fzf ────────────────────────────────────────────────────────

test_a_key_prefixed_list_is_displayed_without_its_keys() {
  # --with-nth=2.. is what hides the key. It is also what would blank the list
  # entirely if the lines had no tab in them, which is the next test.
  local argv; argv=$(printf 'k1\tone\nk2\ttwo\n' | _fzf_argv)
  assert_match "$argv" '--with-nth=2\.\.' "keys are hidden"
  assert_match "$argv" '--delimiter='     "on the tab"
}

test_a_plain_list_is_not_asked_to_hide_a_field_it_does_not_have() {
  # fzf renders --with-nth=2.. over a line with no delimiter as an EMPTY row,
  # so passing it unconditionally would show a list of nothing.
  local argv; argv=$(printf 'alpha\nbravo\n' | _fzf_argv)
  assert_not_match "$argv" '--with-nth' "no field trimming on plain lines"
}

test_options_are_passed_through_only_when_asked_for() {
  local argv
  argv=$(printf 'a\nb\n' | _fzf_argv --multi --header 'pick some' --height 45%)
  assert_match "$argv" '--multi'       "multi select"
  assert_match "$argv" '--marker'      "and something to mark it with"
  assert_match "$argv" 'pick some'     "the header"
  assert_match "$argv" '--height=45%'  "the height"
  assert_not_match "$argv" '--preview' "no preview was asked for"

  argv=$(printf 'a\nb\n' | _fzf_argv --preview 'echo {}' --preview-window 'down:5')
  assert_match "$argv" '--preview=echo' "the preview command"
  assert_match "$argv" 'down:5'         "and where to put it"
  assert_not_match "$argv" '--multi'    "single choice unless asked"
}

test_an_empty_list_is_not_a_picker_at_all() {
  # Every call site reads "nothing chosen" from a non-zero exit. A picker over
  # an empty list has to say that rather than open an empty window.
  local out; out=$(printf '' | pick) && _t_bad "expected failure on an empty list"
  assert_empty "$out" "and nothing on stdout"
}

# ── the fallback, without a terminal ────────────────────────────────────────

test_pick_label_is_what_the_user_reads() {
  pick_label $'save-profile\t💾  save running apps'
  assert_eq "$PICK_LABEL" '💾  save running apps' "the key is not part of the label"
  pick_label 'sales-be'
  assert_eq "$PICK_LABEL" 'sales-be' "a plain line is its own label"
}

test_a_number_picks_by_position() {
  _pick_resolve 2 0 alpha bravo charlie
  assert_eq "$PICK_RESULT" chosen     "a number is a choice"
  assert_eq "${PICK_OUT[*]}" bravo    "the second one"
}

test_a_number_off_the_end_says_so_instead_of_choosing_something_else() {
  _pick_resolve 9 0 alpha bravo
  assert_eq "$PICK_RESULT" none               "not a choice"
  assert_eq "${#PICK_OUT[@]}" 0               "and nothing was chosen"
  assert_match "$PICK_MSG" '9 is not on the list' "with a reason"
}

test_several_numbers_are_several_choices_only_where_that_is_offered() {
  _pick_resolve '1 3' 1 alpha bravo charlie
  assert_eq "$PICK_RESULT" chosen            "multi takes them all"
  assert_eq "${PICK_OUT[*]}" 'alpha charlie' "in the order typed"

  _pick_resolve '2,3' 1 alpha bravo charlie
  assert_eq "${PICK_OUT[*]}" 'bravo charlie' "commas are what people type"

  # A single-choice caller assigns the result to one variable. Handing it two
  # lines would put a newline in the middle of a component name.
  _pick_resolve '1 3' 0 alpha bravo charlie
  assert_eq "${#PICK_OUT[@]}" 1     "single choice returns one line"
  assert_eq "${PICK_OUT[*]}" alpha  "the first"
}

test_text_that_matches_one_entry_chooses_it() {
  _pick_resolve char 0 alpha bravo charlie
  assert_eq "$PICK_RESULT" chosen    "an unambiguous substring is a choice"
  assert_eq "${PICK_OUT[*]}" charlie "the one it matched"

  _pick_resolve ALPHA 0 alpha bravo
  assert_eq "${PICK_OUT[*]}" alpha "matching ignores case"
}

test_text_that_matches_several_narrows_the_list() {
  _pick_resolve sales 0 sales-be sales-fe hr-be
  assert_eq "$PICK_RESULT" narrow              "still a question, not an answer"
  assert_eq "${PICK_OUT[*]}" 'sales-be sales-fe' "asked again over what is left"
}

test_text_that_matches_nothing_says_so_and_keeps_asking() {
  _pick_resolve zzz 0 alpha bravo
  assert_eq "$PICK_RESULT" none            "nothing chosen"
  assert_match "$PICK_MSG" 'nothing matches' "and it says why"
}

test_matching_happens_on_the_label_not_on_its_colour_codes() {
  # limit_choices and render_choices feed coloured labels. Matching the raw
  # line would let "m" hit every row through the `m` that ends an SGR escape,
  # and matching the key would make the visible text a lie.
  local -a rows=(
    $'sales-be\t\e[38;2;1;2;3msales backend\e[0m'
    $'hr-be\t\e[38;2;1;2;3mhr backend\e[0m'
  )
  _pick_resolve 'hr' 0 "${rows[@]}"
  assert_eq "$PICK_RESULT" chosen "matched the readable text"
  assert_match "${PICK_OUT[*]}" '^hr-be' "and returns the whole line, key and all"

  _pick_resolve 'm' 0 "${rows[@]}"
  assert_eq "$PICK_RESULT" none "the m in an escape sequence is not a match"
}

test_typing_nothing_cancels() {
  _pick_resolve '' 0 alpha bravo
  assert_eq "$PICK_RESULT" cancel "Enter alone is Esc"
  assert_eq "${#PICK_OUT[@]}" 0   "nothing chosen"
}

test_the_fallback_gives_up_rather_than_hanging_without_a_terminal() {
  # A pitcrew in a pipeline or in CI has nobody to ask. It has to fail like a
  # cancelled picker — the one thing it must not do is block on a dead fd.
  local out
  out=$(printf 'a\nb\n' | PITCREW_PICKER=plain pick < /dev/null 2>/dev/null) && \
    _t_bad "expected failure with no terminal"
  assert_empty "$out" "and nothing on stdout"
}

# ── structure: this is the bug, not the symptom ─────────────────────────────

test_no_picker_talks_to_fzf_behind_picks_back() {
  # One place knows fzf exists, the same bargain lib/00-platform.sh strikes for
  # the OS. A new `| fzf` anywhere else is a menu that dies on macOS.
  # doctor is exempt: it reports `fzf --version` and never picks anything.
  local strays
  strays=$(grep -rln '| *fzf ' "$PITCREW_DIR/lib" \
           | grep -v '01-core.sh$' | grep -v '12-doctor.sh$' | tr '\n' ' ')
  assert_empty "$strays" "files piping a list into fzf themselves"
}

test_no_menu_guards_itself_on_fzf_being_installed() {
  # `command -v fzf >/dev/null || return` is what made the dashboard's m key do
  # nothing at all, silently, on every Mac.
  local guards
  guards=$(grep -rn 'command -v fzf' "$PITCREW_DIR/lib" \
           | grep -v '01-core.sh:' | grep -v '12-doctor.sh:' | tr '\n' ' ')
  assert_empty "$guards" "fzf guards outside the chooser and doctor"
}

test_the_plain_path_can_be_forced_on_a_machine_that_has_fzf() {
  # A fallback nobody runs is a fallback that rots — so CI runs this one, the
  # same way PITCREW_FORCE_COLLECTOR=ps runs the macOS meters on Linux.
  local argv
  argv=$(printf 'a\nb\n' | _fzf_argv)
  assert_match "$argv" '--prompt' "PITCREW_PICKER=fzf uses fzf"

  fzf() { echo "fzf ran"; }
  local out
  out=$(printf 'a\nb\n' | PITCREW_PICKER=plain pick < /dev/null 2>/dev/null) || true
  assert_not_match "${out:-none}" 'fzf ran' "PITCREW_PICKER=plain does not"
}

run_tests
