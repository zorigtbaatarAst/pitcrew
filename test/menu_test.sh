#!/usr/bin/env bash
# The action menu.
#
# This file exists because of a bug that produced no error at all: menu items
# were dispatched on their leading emoji, and two entries ended up sharing 🎨.
# `case` takes the first match, so choosing "change theme" silently ran "start
# frontends only". Nothing failed; the option just appeared to do nothing.
#
# Dispatch now happens on a unique key, and the first two tests here make a
# duplicate key — or an item wired to nothing — a test failure rather than a
# mystery.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
SELF="$PITCREW_DIR/bin/pitcrew"
load_pitcrew
source "$PITCREW_CFG"
config_finalize "$PITCREW_CFG"

test_every_menu_key_is_unique() {
  local dupes; dupes=$(menu_keys | sort | uniq -d | tr '\n' ' ')
  assert_empty "$dupes" "duplicate menu keys"
  # grep -c rather than `wc -l` — BSD wc pads its output, GNU does not.
  local n u; n=$(menu_keys | grep -c .); u=$(menu_keys | sort -u | grep -c .)
  assert_eq "$n" "$u" "item count vs unique key count"
}

test_every_menu_key_has_a_dispatch_arm() {
  # an item with no arm falls through to the catch-all, which closes the menu —
  # indistinguishable, from the outside, from the option doing nothing
  local arms key
  arms=$(sed -n '/^dispatch_choice() {/,/^}/p' "$PITCREW_DIR/lib/13-menu.sh" \
         | grep -oE '^    [a-z-]+\)' | tr -d ' )')
  while IFS= read -r key; do
    printf '%s\n' "$arms" | grep -qx -- "$key" || _t_bad "menu item '$key' has no dispatch arm"
  done < <(menu_keys)
}

test_the_overlay_menu_hides_entries_that_make_no_sense_there() {
  local overlay; overlay=$(menu_keys overlay | tr '\n' ' ')
  local full;    full=$(menu_keys | tr '\n' ' ')
  assert_match "$full"    'watch'   "the standalone menu offers the dashboard"
  assert_not_match "$overlay" 'watch' "the overlay does not — you are already in it"
}

test_labels_are_hidden_from_the_key() {
  # fzf shows field 2 onward and returns the whole line; the key must never
  # appear in what the user reads
  local line; line=$(menu_choices | head -1)
  assert_match "$line" $'^start-all\t' "key is the first tab-separated field"
  assert_not_match "$(printf '%s' "$line" | cut -f2-)" 'start-all' "label carries no key"
}

test_choosing_a_theme_actually_changes_the_theme() {
  local pref; pref=$(mktemp)
  ( PITCREW_THEME_FILE=$pref
    fzf() { echo gruvbox; }                       # stand in for the picker
    local before=$C_OK
    dispatch_choice "$(menu_choices overlay | grep '^theme')" overlay
    assert_ne "$C_OK" "$before" "palette changed"
    assert_eq "$C_OK" $'\e[38;2;184;187;38m' "and it is gruvbox"
    assert_eq "$(cat "$pref")" "gruvbox" "choice was remembered"
    assert_eq "$MENU_CLOSE" 1 "menu closes so the dashboard repaints"
  )
  rm -f "$pref"
}

test_cancelling_the_theme_picker_changes_nothing() {
  local pref; pref=$(mktemp)
  ( PITCREW_THEME_FILE=$pref
    fzf() { return 1; }                           # Esc
    local before=$C_OK
    dispatch_choice "$(menu_choices overlay | grep '^theme')" overlay
    assert_eq "$C_OK" "$before" "palette untouched"
    assert_empty "$(cat "$pref")" "nothing remembered"
  )
  rm -f "$pref"
}

test_choosing_a_render_style_actually_changes_it() {
  # the same shape as the theme picker, and the same failure mode if it is
  # wired up wrong: the option appears to do nothing
  local pref; pref=$(mktemp)
  ( PITCREW_RENDER_FILE=$pref
    fzf() { printf 'graph=braille\tsome label\n'; }    # stand in for the picker
    dispatch_choice "$(menu_choices overlay | grep '^render')" overlay
    assert_eq "$PITCREW_GRAPH" braille "the running dashboard switched style"
    assert_match "$(cat "$pref")" 'graph=braille' "and the choice was remembered"
    assert_eq "$MENU_CLOSE" 1 "menu closes so the dashboard repaints"
  )
  rm -f "$pref"
}

test_cancelling_the_render_picker_changes_nothing() {
  local pref; pref=$(mktemp)
  ( PITCREW_RENDER_FILE=$pref
    fzf() { return 1; }                           # Esc
    local before=$PITCREW_GRAPH
    dispatch_choice "$(menu_choices overlay | grep '^render')" overlay
    assert_eq "$PITCREW_GRAPH" "$before" "style untouched"
    assert_empty "$(cat "$pref")" "nothing remembered"
  )
  rm -f "$pref"
}

run_tests
