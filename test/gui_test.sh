#!/usr/bin/env bash
# The GUI's stream reader.
#
# pitcrew-gui is Python/GTK and the rest of this suite is bash, so this file is
# a thin bridge: it drives the real Stream class out of gui/pitcrew-gui under
# the SYSTEM python and asserts on behaviour that has already broken once.
#
# The bug it guards: GIO reports end-of-stream as an EMPTY line (b""), never
# None, and an async read on a pipe at EOF completes IMMEDIATELY, every time.
# The reader re-armed on it and spun the main loop at G_PRIORITY_DEFAULT, which
# outranks GTK's redraw — so switching project froze the window at 100% CPU
# rather than raising anything. Measured on the broken code, that was ~100k
# handler calls per second, which is why every assertion here counts calls
# rather than just checking the happy path: a test that only counts frames
# passes just as well on the broken reader.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

GUI="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gui/pitcrew-gui"

# The GTK bindings live in the system python, which is what the app shebangs
# into — not whatever `python3` resolves to on $PATH (a Homebrew or pyenv
# python has no `gi`). No bindings, no GUI, nothing to test: skip, don't fail.
gui_available() {
  [ -r "$GUI" ] && /usr/bin/python3 -c 'import gi, cairo' >/dev/null 2>&1
}

_drive() { # $1 = python body, with Stream / Counting / GLib in scope
  /usr/bin/python3 -c "
import importlib.machinery, importlib.util, sys
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gio, GLib
spec = importlib.util.spec_from_loader(
    'pgui', importlib.machinery.SourceFileLoader('pgui', '$GUI'))
pgui = importlib.util.module_from_spec(spec); spec.loader.exec_module(pgui)

class Counting(pgui.Stream):
    '''Counts completed reads — the direct measure of the spin.'''
    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.reads = 0
    def _finish_line(self, stream, result):
        self.reads += 1
        return super()._finish_line(stream, result)

def spin(ms):
    loop = GLib.MainLoop()
    GLib.timeout_add(ms, lambda: (loop.quit(), False)[1])
    loop.run()
$1
" 2>/dev/null
}

test_reader_stops_at_eof_instead_of_spinning() {
  gui_available || return 0
  # Two frames then EOF. A correct reader completes a handful of times and goes
  # quiet; the broken one completed ~150000 times in the same window.
  local out; out=$(_drive "
frames = []
s = Counting('/usr/bin/printf', None, 1, frames.append, lambda e: None)
s._argv = ['/usr/bin/printf', '{\"a\":1}\n{\"a\":2}\n']
s.start(); spin(1500)
print(len(frames), 'quiet' if s.reads < 20 else f'SPUN({s.reads})')
")
  assert_eq "$out" "2 quiet" "two frames, then the reader stops being called"
}

test_eof_is_not_reported_as_a_malformed_frame() {
  gui_available || return 0
  # The empty line at EOF used to reach json.loads() and raise, filling the
  # banner with "malformed state" while the UI locked up.
  local out; out=$(_drive "
errors = []
s = Counting('/usr/bin/printf', None, 1, lambda f: None, errors.append)
s._argv = ['/usr/bin/printf', '{\"a\":1}\n']
s.start(); spin(1500)
print(sum('malformed' in e for e in errors))
")
  assert_eq "$out" "0" "a clean exit reports no malformed frames"
}

test_a_stopped_stream_goes_quiet_and_delivers_nothing() {
  gui_available || return 0
  # Switching project must not let the OLD project's frames land in the new
  # window, and must not leave a reader burning the main loop. stop() cancels
  # the reader; it does not merely kill the child.
  local out; out=$(_drive "
frames, errors = [], []
s = Counting('/bin/sh', None, 1, frames.append, errors.append)
s._argv = ['/bin/sh', '-c', 'while :; do echo {}; sleep 0.05; done']
s.start(); spin(300)
s.stop()
frames.clear(); after = s.reads
spin(1200)
print(len(frames), 'quiet' if s.reads - after < 20 else f'SPUN({s.reads - after})',
      len([e for e in errors if 'stream read failed' in e]))
")
  assert_eq "$out" "0 quiet 0" "silent after stop, and cancelling is not an error"
}

# ── settings and grouping ───────────────────────────────────────────────────

_settings_drive() { # $1 = python body, with Settings/SETTINGS_BY_KEY/group_of in scope
  /usr/bin/python3 -c "
import importlib.machinery, importlib.util, os, pathlib, sys
import gi
gi.require_version('Gtk', '4.0')
spec = importlib.util.spec_from_loader(
    'pgui', importlib.machinery.SourceFileLoader('pgui', '$GUI'))
pgui = importlib.util.module_from_spec(spec); spec.loader.exec_module(pgui)
Settings, SETTINGS, SETTINGS_BY_KEY = pgui.Settings, pgui.SETTINGS, pgui.SETTINGS_BY_KEY
group_of = pgui.group_of
$1
" 2>/dev/null
}

test_settings_round_trip_through_the_house_file_format() {
  gui_available || return 0
  local dir; dir=$(mktemp -d)
  local out; out=$(_settings_drive "
path = pathlib.Path('$dir/gui')
s = Settings(path)
s['group'] = 'role'; s['interval'] = 9
print(s.save())
print(path.read_text().strip().replace(chr(10), ' '))
print(Settings(path)['group'], Settings(path)['interval'])
")
  rm -rf "$dir"
  local saved; saved=$(printf '%s' "$out" | sed -n 2p)
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "True" "save reports success"
  assert_match "$saved" 'group=role' "written as key=value, like render"
  assert_match "$saved" 'interval=9' "every key is rewritten, not just the changed one"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "role 9" "and reads back"
}

test_a_hand_edited_setting_falls_back_instead_of_crashing() {
  gui_available || return 0
  # Same contract as render_resolve: the file is written by us, so an unknown
  # value means a hand edit or a newer version — use the default, do not die.
  local dir; dir=$(mktemp -d)
  printf 'group=sideways\ninterval=nine\nhistory=99999\nbogus=1\n' > "$dir/gui"
  local out; out=$(_settings_drive "
s = Settings(pathlib.Path('$dir/gui'))
print(s['group'], s['interval'], s['history'])
")
  rm -rf "$dir"
  assert_eq "$out" "app 2 120" "every unusable value falls back to its default"
}

test_env_overrides_the_saved_file() {
  gui_available || return 0
  local dir; dir=$(mktemp -d)
  printf 'group=flat\n' > "$dir/gui"
  local out; out=$(PITCREW_GUI_GROUP=role _settings_drive "
print(Settings(pathlib.Path('$dir/gui'))['group'])
")
  rm -rf "$dir"
  assert_eq "$out" "role" "PITCREW_GUI_* beats the file, like PITCREW_GRAPH does"
}

test_grouping_uses_the_stream_fields_not_the_component_name() {
  gui_available || return 0
  # A component is `<role>-<app>`, but the JSON carries app and role already —
  # parsing the name would break on any app whose name contains a dash.
  local out; out=$(_settings_drive "
comp = {'name': 'be-my-app', 'app': 'my-app', 'role': 'be'}
fe = {'name': 'fe-my-app', 'app': 'my-app', 'role': 'fe'}
print(group_of(comp, 'app')[1], group_of(fe, 'app')[1])
print(group_of(comp, 'role')[1], group_of(fe, 'role')[1])
print(group_of(comp, 'flat')[1])
print('be-first' if group_of(comp, 'role')[0] < group_of(fe, 'role')[0] else 'wrong-order')
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "my-app my-app" "by app: both roles land together"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "Backends Frontends" "by role: split"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "Components" "flat: one heading"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "be-first" "backends sort before frontends"
}

test_an_empty_component_list_always_explains_itself() {
  gui_available || return 0
  # A filter that hides everything must not look like a broken app.
  local out; out=$(_settings_drive "
print(pgui.empty_message(0))
print(pgui.empty_message(1).replace(chr(10), ' '))
print(pgui.empty_message(12).replace(chr(10), ' '))
")
  assert_match "$(printf '%s' "$out" | sed -n 1p)" 'no components configured' "nothing to show at all"
  assert_match "$(printf '%s' "$out" | sed -n 2p)" '1 stopped component hidden' "singular"
  assert_match "$(printf '%s' "$out" | sed -n 3p)" '12 stopped components hidden' "plural, and says why"
}

run_tests
