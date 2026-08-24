#!/usr/bin/env bash
# The GUI's config editor changes FIELDS; gui/pitcrewgui/yamledit.py turns a
# changed field into the smallest possible edit to the file's text.
#
# Two properties matter more than anything else here:
#
#   * everything not being edited comes back byte-identical — comments, blank
#     lines, key order, and whether a component was written as a block or as a
#     one-line flow mapping. An editor that rewrites the file wholesale hands
#     back a config with every comment gone, which is a replacement, not a save.
#
#   * it never INTERPRETS a value. lib/18-yaml.sh is the one definition of the
#     subset pitcrew accepts, and a second parser in the GUI would eventually
#     accept a file the tool rejects — or silently misread one and save it back.
#
# Bash driving Python, the same bridge test/gui_test.sh uses, so the whole
# suite stays one command.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

GUI_DIR=$(py_path "$PITCREW_DIR/gui")
PY=$(command -v python3) || PY=""

_edit() { # $1 = python body, with Y bound to the module and T to the sample
  [ -n "$PY" ] || return 0
  "$PY" -c "
import sys
sys.path.insert(0, '$GUI_DIR')
from pitcrewgui import yamledit as Y
T = '''$SAMPLE'''
$1
" 2>&1
}

SAMPLE='# what this project is
name: Shop

apps:
  shop:
    url_path: /api      # everything but fe sits behind this
    be:
      root: ~/work/api
      dir: services/orders
      cmd: gradlew bootRun
      port: 4000
    fe: { root: ~/work/web, cmd: npm run dev, port: 3000 }
deps: [postgres]'

_have_python() { [ -n "$PY" ]; }

test_every_key_is_addressable_by_its_dotted_path() {
  _have_python || return 0
  local out; out=$(_edit "print(' '.join('.'.join(l.path) for l in Y.scan(T)))")
  assert_match "$out" 'apps\.shop\.be\.port'  "a nested block key"
  assert_match "$out" 'apps\.shop\.fe'        "and the flow mapping's own line"
  assert_match "$out" 'deps'                  "and a top-level one"
}

test_changing_one_value_changes_exactly_one_line() {
  _have_python || return 0
  local out; out=$(_edit "
new = Y.set_value(T, ('apps','shop','be','port'), '4100')
before, after = T.splitlines(), new.splitlines()
print(sum(1 for a, b in zip(before, after) if a != b), len(before) == len(after))
")
  assert_eq "$out" "1 True" "one line differs and none were added or lost"
}

test_a_comment_on_the_line_being_edited_survives() {
  _have_python || return 0
  local out; out=$(_edit "
new = Y.set_value(T, ('apps','shop','url_path'), '/v2')
print([l for l in new.splitlines() if 'url_path' in l][0].strip())
")
  assert_match "$out" '^url_path: /v2' "the new value"
  assert_match "$out" 'behind this'    "and the note somebody left"
}

test_every_other_comment_survives_untouched() {
  _have_python || return 0
  local out; out=$(_edit "
new = Y.set_value(T, ('apps','shop','be','cmd'), 'gradlew bootRun --debug')
print(new.count('#'), 'what this project is' in new)
")
  assert_eq "$out" "2 True" "both comments still there"
}

test_a_one_line_component_is_edited_in_place_not_expanded() {
  _have_python || return 0
  # Rewriting a flow mapping as an indented block would be a correct config and
  # a diff nobody asked for.
  local out; out=$(_edit "
new = Y.set_value(T, ('apps','shop','fe','port'), '3100')
print([l for l in new.splitlines() if l.strip().startswith('fe:')][0].strip())
")
  assert_match "$out" '^fe: \{ ' "still a flow mapping"
  assert_match "$out" 'port: 3100' "with the new value"
  assert_match "$out" 'npm run dev' "and everything it already said"
}

test_a_new_field_lands_in_whichever_style_its_component_uses() {
  _have_python || return 0
  local out; out=$(_edit "
block = Y.set_value(T, ('apps','shop','be','health'), '/actuator/health')
flow  = Y.set_value(T, ('apps','shop','fe','health'), '/up')
print([l for l in block.splitlines() if 'actuator' in l][0])
print([l for l in flow.splitlines() if l.strip().startswith('fe:')][0].strip())
")
  assert_match "$(printf '%s' "$out" | sed -n 1p)" '^      health: ' "indented under the block it belongs to"
  assert_match "$(printf '%s' "$out" | sed -n 2p)" 'health: /up \}'  "appended inside the flow mapping"
}

test_removing_a_field_removes_only_that_line() {
  _have_python || return 0
  local out; out=$(_edit "
new = Y.set_value(T, ('apps','shop','be','dir'), None)
print(len(T.splitlines()) - len(new.splitlines()), 'dir:' in new)
")
  assert_eq "$out" "1 False" "one line gone, and it was the right one"
}

test_a_whole_component_can_be_added_to_a_group() {
  _have_python || return 0
  # The one thing a field-level edit cannot express: an app is an open group,
  # so adding a role has to be possible from the form.
  local out; out=$(_edit "
new = Y.add_block(T, ('apps','shop','worker'),
                  [('dir','services/worker'), ('cmd','gradlew worker')])
print('worker:' in new, new.count('shop:'))
import re
print([l for l in new.splitlines() if 'gradlew worker' in l][0])
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "True 1" "added once, into the existing group"
  assert_match "$(printf '%s' "$out" | sed -n 2p)" '^      cmd: ' "at the indent its siblings use"
}

test_a_value_is_quoted_only_when_leaving_it_bare_would_change_it() {
  _have_python || return 0
  local out; out=$(_edit "
for v in ['gradlew bootRun', '', 'true', '{ npm i; } && npm run dev', ' lead', 'a: b', 'x # y']:
    print(repr(v), '->', Y.format_value(v))
")
  assert_match "$out" "'gradlew bootRun' -> gradlew bootRun" "an ordinary command stays bare"
  assert_match "$out" "'' -> \"\""                            "empty has to be written as something"
  assert_match "$out" "'true' -> \"true\""                    "a word YAML would read as a boolean"
  assert_match "$out" 'npm i; \} && npm run dev. -> "' "a leading brace would look like a flow mapping"
  assert_match "$out" "' lead' -> \" lead\""                  "leading space is significant"
  assert_match "$out" "'a: b' -> \"a: b\""                    "a colon-space would look like a mapping"
  assert_match "$out" "'x # y' -> \"x # y\""                  "and an inline comment would eat the tail"
}

test_a_comma_is_quoted_inside_a_flow_mapping_and_not_outside_one() {
  _have_python || return 0
  # A comma separates the pairs in `{ … }`, so an unquoted one there would cut
  # the command in half. On a line of its own it is an ordinary character.
  local out; out=$(_edit "
print(Y.format_value('npm run build, npm start'))
print(Y.format_value('npm run build, npm start', flow=True))
new = Y.set_value(T, ('apps','shop','fe','cmd'), 'npm run build, npm start')
print([l for l in new.splitlines() if l.strip().startswith('fe:')][0].strip())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "npm run build, npm start" "bare on its own line"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" '"npm run build, npm start"' "quoted inside a flow mapping"
  assert_match "$(printf '%s' "$out" | sed -n 3p)" 'cmd: "npm run build, npm start"' "which is what gets written"
}

test_a_block_scalar_body_is_not_mistaken_for_keys() {
  _have_python || return 0
  # A `cmd: |` body is text. Reading `foo: bar` inside one as a mapping key
  # would make the editor address — and overwrite — part of a command.
  local out; out=$(_edit "
t = '''apps:
  a:
    be:
      cmd: |
        export A=1
        run: it
      port: 1
'''
print(' '.join('.'.join(l.path) for l in Y.scan(t)))
")
  assert_match "$out" 'apps\.a\.be\.port' "the key after the block scalar is found"
  assert_not_match "$out" 'run' "and nothing inside the body is"
}

test_an_unreachable_path_is_refused_rather_than_invented() {
  _have_python || return 0
  # The caller sends the user to the raw-text tab. Guessing at structure this
  # module does not understand is how an editor corrupts a file.
  local out; out=$(_edit "
try:
    Y.set_value(T, ('apps','nosuch','be','port'), '1')
    print('INVENTED')
except LookupError as e:
    print('refused', e)
")
  assert_match "$out" '^refused' "it says it cannot"
}

run_tests
