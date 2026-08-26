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

GUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gui"
# The same directory, spelled for the interpreter rather than for the shell —
# on Windows those are two different things (see py_path in harness.sh).
GUI_DIR_PY=$(py_path "$GUI_DIR")
PITCREW_DIR_PY=$(py_path "$PITCREW_DIR")

# The GTK bindings live in the system python, which is what the app shebangs
# into — not whatever `python3` resolves to on $PATH (a Homebrew or pyenv
# python has no `gi`). No bindings, no GUI, nothing to test: skip, don't fail.
# The interpreter with the bindings is not the same one on every OS — that is
# the whole reason the app re-execs instead of pinning a shebang, and a test
# file that hardcodes /usr/bin/python3 would silently SKIP everything on macOS
# and report a green run for a GUI nobody checked.
#
# The search itself is gui/pyfind.sh — the same one setup.sh, gui/install.sh
# and gui/install-deps.sh use. A fifth private copy here is how the suite came
# to report green on a Windows box where the installer could not find a python
# at all: the test looked in different places than the thing it was testing.
# shellcheck source=gui/pyfind.sh
. "$(dirname "${BASH_SOURCE[0]}")/../gui/pyfind.sh"
PY_WITH_GI=$(pitcrew_find_python) || PY_WITH_GI=""

# `import gi, cairo` is not what these tests need. They need the PACKAGE to
# import, which additionally wants the Gtk, Adw, Gdk and Pango typelibs — a
# separate install from the Python bindings, and separately missable.
#
# Probing the narrower thing is how macOS came to report thirty-nine failures
# all reading "expected [...] got []": every drive below died on the same
# import, `2>/dev/null` threw away the one line that said which, and the run
# was a wall of red that named no cause. Ask the real question once, keep the
# error, and let test_the_gui_package_imports_at_all be the single thing that
# reports it.
GUI_IMPORT_ERR=""
if [ -n "$PY_WITH_GI" ] && [ -d "$GUI_DIR/pitcrewgui" ]; then
  GUI_IMPORT_ERR=$("$PY_WITH_GI" -c "
import sys
sys.path.insert(0, '$GUI_DIR_PY')
import gi
gi.require_version('Gtk', '4.0')
import pitcrewgui.window, pitcrewgui.app, pitcrewgui.widgets
" 2>&1) && GUI_IMPORT_ERR=""
fi

gui_available() {
  [ -d "$GUI_DIR/pitcrewgui" ] && [ -n "$PY_WITH_GI" ] && [ -z "$GUI_IMPORT_ERR" ]
}

test_the_gui_package_imports_at_all() {
  # The guard on every other test in this file, stated once as an assertion.
  # Without it a broken environment is indistinguishable from a broken app:
  # both come back as an empty string, in every test, with no reason attached.
  [ -d "$GUI_DIR/pitcrewgui" ] && [ -n "$PY_WITH_GI" ] || return 0
  [ -z "$GUI_IMPORT_ERR" ] || _t_bad "the GUI package will not import under $PY_WITH_GI, so every
      other test in this file skipped. The interpreter said:
      $(printf '%s' "$GUI_IMPORT_ERR" | tail -1)"
}

# Anything that BUILDS a widget needs a display, not just the bindings: a
# Gtk.Button with an icon name reaches for the icon theme, the icon theme is
# per-display, and without one GTK aborts the process rather than raising —
# which arrives here as an empty string and an assertion about nothing.
#
# So these skip rather than fail where there is no display, and CI runs the
# Linux job under Xvfb so they are actually exercised somewhere. Pure-logic
# tests (the parsers, the model) need none of this and must not use it.
gui_display() {
  gui_available && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]
}

# The GUI is a package now, so the whole public surface is assembled into one
# namespace here rather than rewriting every assertion below to know which
# module a name ended up in.
_PRELUDE="
import importlib, sys, types
sys.path.insert(0, '$GUI_DIR_PY')
pgui = types.SimpleNamespace()
for _name in ('platform', 'model', 'registry', 'settings', 'runner', 'widgets',
              'dialogs', 'window', 'app'):
    _mod = importlib.import_module('pitcrewgui.' + _name)
    pgui.__dict__.update({k: v for k, v in vars(_mod).items() if not k.startswith('_')})
# As modules, not flattened: ansi.plain and model.plain are different functions
# with the same name and one of them would silently win, and theme.apply/save
# would shadow half a dozen names besides. model is here as a module too so a
# test can watch the palettes theme.apply MUTATES rather than a copy of them.
import pitcrewgui.ansi as _ansi_mod
import pitcrewgui.model as _model_mod
import pitcrewgui.theme as _theme_mod
pgui.ansi = _ansi_mod
pgui.model = _model_mod
pgui.theme = _theme_mod
"

_drive() { # $1 = python body, with Stream / Counting / GLib in scope
  _py "
import sys
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gio, GLib
$_PRELUDE

# Counts completed reads — the direct measure of the spin. Patched into the
# module rather than hooked through a seam in Stream: production code should
# not carry a hole cut for a test.
import pitcrewgui.runner as _runner
_READS = [0]
class _CountingReader(_runner.LineReader):
    def _done(self, stream, result):
        _READS[0] += 1
        return super()._done(stream, result)
_runner.LineReader = _CountingReader

class Counting(pgui.Stream):
    @property
    def reads(self):
        return _READS[0]

def spin(ms):
    loop = GLib.MainLoop()
    GLib.timeout_add(ms, lambda: (loop.quit(), False)[1])
    loop.run()

# The child that stands in for \`pitcrew json --watch\`, as THIS interpreter.
#
# It used to be /usr/bin/printf and /bin/sh. Both exist under MSYS2 — but the
# python that has the GTK bindings there is a NATIVE Windows build, Stream
# spawns through Gio.Subprocess, and CreateProcess cannot open a path spelled
# like that. So every spawn failed, every assertion below ran against zero
# frames, and two of the three still passed: '0 quiet 0' is what a stream that
# was never started looks like as well. sys.executable is the one program
# guaranteed to be startable by whoever is running these.
def emits(text):                       # writes text, then exits
    return [sys.executable, '-c', 'import sys; sys.stdout.write(%r)' % text]

def emits_forever(line, every):        # ... and one that keeps going
    return [sys.executable, '-c',
            'import sys, time\nwhile True:\n'
            '    sys.stdout.write(%r); sys.stdout.flush(); time.sleep(%r)' % (line, every)]
$1
"
}

test_reader_stops_at_eof_instead_of_spinning() {
  gui_available || return 0
  # Two frames then EOF. A correct reader completes a handful of times and goes
  # quiet; the broken one completed ~150000 times in the same window.
  local out; out=$(_drive "
frames = []
s = Counting(sys.executable, None, 1, frames.append, lambda e: None)
s._argv = emits('{\"a\":1}\n{\"a\":2}\n')
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
s = Counting(sys.executable, None, 1, lambda f: None, errors.append)
s._argv = emits('{\"a\":1}\n')
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
s = Counting(sys.executable, None, 1, frames.append, errors.append)
s._argv = emits_forever('{}\n', 0.05)
s.start(); spin(300)
s.stop()
frames.clear(); after = s.reads
spin(1200)
print(len(frames), 'quiet' if s.reads - after < 20 else f'SPUN({s.reads - after})',
      len([e for e in errors if 'stream read failed' in e]))
")
  assert_eq "$out" "0 quiet 0" "silent after stop, and cancelling is not an error"
}

# ── ANSI in a log file ──────────────────────────────────────────────────────
#
# A dev server's log is not plain text: Spring Boot, Vite, gradle and npm all
# write SGR colour into it. Rendering those bytes literally is what turned a
# Spring log into a wall of `▯▯[2m…▯▯[0;39m` with the message off-screen.

test_sgr_colour_becomes_spans_and_the_escapes_are_gone() {
  gui_available || return 0
  local out; out=$(_settings_drive "
line = ('\x1b[2m2026-08-20 11:04:19.670\x1b[0;39m \x1b[32mINFO\x1b[0;39m '
        '\x1b[34m[backoffice]\x1b[0;39m started')
for text, tags in pgui.ansi.spans(line):
    print(','.join(tags) or '-', '|', text)
print('PLAIN', pgui.ansi.plain(line))
print('ESC', '\x1b' in pgui.ansi.plain(line))
")
  assert_match "$out" 'dim \| 2026-08-20'   "the timestamp keeps its dim attribute"
  assert_match "$out" 'fg:green \| INFO'    "the level keeps its colour"
  assert_match "$out" 'fg:blue \| \[backoffice\]' "and so does the logger"
  assert_match "$out" 'PLAIN 2026-08-20 11:04:19.670 INFO \[backoffice\] started' "text is text"
  assert_match "$out" 'ESC False' "nothing escaped survives into the buffer"
}

test_every_other_escape_sequence_is_dropped_not_printed() {
  gui_available || return 0
  # An erase-line or a window-title has no meaning in a scrollback buffer, but
  # it is not text either — printing it is how `▯▯[K` ends up on screen.
  local out; out=$(_settings_drive "
for raw in ['text\x1b[K more', 'a\x1b[2Jb', '\x1b]0;window title\x07visible',
            'x\x1b(By', 'keep\x07me']:
    print(repr(pgui.ansi.plain(raw)))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "'text more'" "erase-line"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "'ab'"        "erase-display"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "'visible'"   "an OSC window title"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "'xy'"        "a charset selection"
  assert_eq "$(printf '%s' "$out" | sed -n 5p)" "'keepme'"    "and a stray control byte"
}

test_a_progress_line_shows_its_final_state() {
  gui_available || return 0
  # npm, pip and gradle draw progress by returning to column zero and writing
  # again. Kept verbatim, one download is two hundred copies of itself.
  local out; out=$(_settings_drive "
print(repr(pgui.ansi.plain('downloading 10%\rdownloading 90%\rdone')))
print(repr(pgui.ansi.plain('no carriage return here')))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "'done'" "what a terminal would have left on screen"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "'no carriage return here'" "and nothing else is touched"
}

test_256_and_24_bit_colour_are_kept_as_written() {
  gui_available || return 0
  # Their arguments must be consumed, not read as further codes — that is how a
  # truecolor sequence ends up setting something at random in a naive parser.
  local out; out=$(_settings_drive "
print(pgui.ansi.spans('\x1b[38;2;255;128;0mwarn')[0][1][0])
print(pgui.ansi.spans('\x1b[38;5;244mgrey')[0][1][0])
print(pgui.ansi.spans('\x1b[38;5;2mgreen')[0][1][0])
print(','.join(pgui.ansi.spans('\x1b[1;31mboth')[0][1]))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "fg:#ff8000"  "24-bit is used as given"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "fg:#808080"  "a 256-colour grey keeps its shade"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "fg:green"    "the low 16 map onto the palette"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "fg:red,bold" "attributes and colour together"
}

test_style_does_not_leak_between_lines() {
  gui_available || return 0
  # It can in a real terminal. A log buffer is scrolled, filtered and trimmed,
  # so one unterminated sequence would otherwise colour everything after it.
  local out; out=$(_settings_drive "
print(','.join(pgui.ansi.spans('\x1b[31mnever closed')[0][1]))
print(','.join(pgui.ansi.spans('the next line')[0][1]) or '-')
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "fg:red" "the line that opened it is coloured"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "-"      "the one after it is not"
}

test_the_view_colours_by_the_log_and_falls_back_to_the_error_pattern() {
  gui_display || return 0
  local dir; dir=$(mktemp -d)
  local out; out=$(_logview_drive "$dir" "
(d / 'be-api.log').write_text(
    '\x1b[32mINFO\x1b[0;39m fine\n'
    'plain ERROR with no colour\n'
    '\x1b[33mWARN\x1b[0;39m ERROR word inside a coloured line\n')
v = LogView(lambda m: None)
v.update_sources(str(d), COMPS, 'ERROR')
spin(700)
b = v._buffer
it = b.get_start_iter()
runs = []
while True:
    names = tuple(t.get_property('name') for t in it.get_tags())
    if not runs or runs[-1][0] != names:
        runs.append((names, it.get_char()))
    if not it.forward_char():
        break
v.stop()
for names, ch in runs:
    print((','.join(names) or '-'), repr(ch))
")
  rm -rf "$dir"
  assert_match "$out" "fg:green 'I'"  "the log's own colour is used"
  assert_match "$out" "fg:error 'p'"  "an uncoloured error line is coloured by the pattern"
  assert_match "$out" "fg:yellow 'W'" "a line the app already coloured is left as it asked"
  assert_not_match "$out" "fg:error 'E'" "the pattern never overrides a colour the log chose"
}

# ── the log tail ────────────────────────────────────────────────────────────
#
# All three of these were "the log view is frozen" with three different causes,
# and none of them was visible in a screenshot.

_logview_drive() { # $1 = python body, with LogView / GLib / a temp dir in scope
  "$PY_WITH_GI" -c "
import pathlib, sys
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Adw', '1')
from gi.repository import Adw, GLib
$_PRELUDE
Adw.init()
LogView = pgui.LogView
d = pathlib.Path('$(py_path "$1")')
d.mkdir(parents=True, exist_ok=True)
COMPS = [{'name': 'be-api', 'role': 'be', 'app': 'api'}]

def spin(ms):
    loop = GLib.MainLoop()
    GLib.timeout_add(ms, lambda: (loop.quit(), False)[1])
    loop.run()
$2
" 2>/dev/null
}

test_a_blank_line_does_not_end_the_log_tail() {
  gui_display || return 0
  # read_line_finish reports EOF as (b'', 0) — and a BLANK LINE as (b'', 0) too.
  # Treating the pair as EOF stopped the tail at the first empty line, which a
  # starting Spring Boot or npm process emits within its first few. The view
  # then sat there showing a stale prefix of the log forever.
  local dir; dir=$(mktemp -d)
  local out; out=$(_logview_drive "$dir" "
log = d / 'be-api.log'
log.write_text('first\n\nthird\n')
v = LogView(lambda m: None)
v.update_sources(str(d), COMPS, 'ERROR')
spin(500)
with log.open('a') as f:
    f.write('\nfourth\n'); f.flush()
spin(800)
v.stop()
print(','.join(v._raw))
")
  rm -rf "$dir"
  assert_eq "$out" "first,,third,,fourth" "every line, blanks included, and it kept going"
}

test_a_log_that_appears_later_is_picked_up() {
  gui_display || return 0
  # Open Logs, then start the stack: the component was selected while it had no
  # log file, and nothing ever re-checked. The view showed "no log yet" for the
  # rest of the session, which looks exactly like a frozen tail.
  local dir; dir=$(mktemp -d)
  local out; out=$(_logview_drive "$dir" "
v = LogView(lambda m: None)
v.update_sources(str(d), COMPS, 'ERROR')
spin(200)
before = list(v._raw)
(d / 'be-api.log').write_text('now it exists\n')
v.update_sources(str(d), COMPS, 'ERROR')      # the next frame from the stream
spin(800)
v.stop()
print(len(before), ','.join(v._raw))
")
  rm -rf "$dir"
  assert_eq "$out" "0 now it exists" "nothing before it started, and following after"
}

test_the_tail_follows_a_restart_that_rotates_the_log() {
  gui_display || return 0
  # Restarting a component renames its log and starts a new one (rotate_log in
  # lib/07a-start.sh). Plain `tail -f` goes on following the RENAMED file, so
  # after a restart the view showed the previous run and never moved again.
  local dir; dir=$(mktemp -d)
  local out; out=$(_logview_drive "$dir" "
log = d / 'be-api.log'
log.write_text('run1\n')
v = LogView(lambda m: None)
v.update_sources(str(d), COMPS, 'ERROR')
spin(500)
log.rename(d / 'be-api.log.1')
log.write_text('run2\n')
spin(2000)
v.stop()
print('run2' in v._raw)
")
  rm -rf "$dir"
  assert_eq "$out" "True" "it re-opens by name, so the new run is what you see"
}

test_a_tail_that_was_stopped_comes_back_on_the_next_frame() {
  gui_display || return 0
  # `stop()` is called on this view every time the state stream is rebuilt —
  # after a config save, after a sampling change, on reconnect. The re-arm
  # asked "was I waiting for this file to appear", and a view whose tail had
  # been stopped rather than never started was not waiting for anything. So it
  # sat there showing the run it had already read, forever: you saved a config,
  # restarted a component, and the log never moved again.
  local dir; dir=$(mktemp -d)
  local out; out=$(_logview_drive "$dir" "
log = d / 'be-api.log'
log.write_text('run1\n')
v = LogView(lambda m: None)
v.update_sources(str(d), COMPS, 'ERROR')
spin(600)
v.stop()                                    # what _restart_stream() does
v.update_sources(str(d), COMPS, 'ERROR')    # and the next frame after it
spin(800)
with log.open('a') as f:
    f.write('after the save\n')
spin(1500)
print('after the save' in v._raw)
v.stop()
")
  rm -rf "$dir"
  assert_eq "$out" "True" "a frame with nothing reading the log arms the tail again"
}

test_a_log_can_be_pulled_out_into_its_own_window() {
  gui_display || return 0
  # A log is read WHILE doing something else to the service that writes it —
  # restarting it, editing the config that starts it. In one tab of one window
  # it is the only thing you can be looking at.
  local dir; dir=$(mktemp -d)
  local out; out=$(_logview_drive "$dir" "
COMPS = [{'name': 'be-api', 'role': 'be', 'app': 'api'},
         {'name': 'fe-api', 'role': 'fe', 'app': 'api'}]
(d / 'be-api.log').write_text('backend line\n')
(d / 'fe-api.log').write_text('frontend line\n')
closed = []
w = pgui.LogWindow(None, 'demo', 'be-api', closed.append, lambda m: None)
w.feed(str(d), COMPS, 'ERROR')
spin(700)
print(w.get_title())
print('backend line' in w.view._raw)
with (d / 'be-api.log').open('a') as f:
    f.write('a later line\n')
spin(1200)
print('a later line' in w.view._raw)
w.view.show_component('fe-api')
print(w.get_title())
w._closing()
print(bool(closed) and closed[0] is w)
")
  rm -rf "$dir"
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "be-api · demo" "it opens on the log it was asked for"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True" "with what is already in the file"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "True" \
    "and it keeps following it — a detached log that stops is how you stop watching"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "fe-api · demo" \
    "pointed somewhere else, it says so rather than lying in its title"
  assert_eq "$(printf '%s' "$out" | sed -n 5p)" "True" "closing it reports itself"
}

test_a_detached_window_does_not_offer_to_detach_itself() {
  gui_display || return 0
  local dir; dir=$(mktemp -d)
  local out; out=$(_logview_drive "$dir" "
def labels(widget, found):
    while widget is not None:
        name = widget.get_icon_name() if hasattr(widget, 'get_icon_name') else None
        if name:
            found.add(name)
        child = widget.get_first_child() if hasattr(widget, 'get_first_child') else None
        if child is not None:
            labels(child, found)
        widget = widget.get_next_sibling()
attached, detached = set(), set()
labels(LogView(lambda m: None, on_detach=lambda n: None).get_first_child(), attached)
labels(LogView(lambda m: None).get_first_child(), detached)
print('window-new-symbolic' in attached, 'window-new-symbolic' in detached)
")
  rm -rf "$dir"
  assert_eq "$out" "True False" "the button is where detaching is possible and nowhere else"
}

test_the_picker_is_not_rebuilt_on_every_frame() {
  gui_display || return 0
  # update_sources compared whole component dicts, which carry live rss/cpu — so
  # the comparison was false every frame and the rebuild ran every frame.
  local dir; dir=$(mktemp -d)
  local out; out=$(_logview_drive "$dir" "
v = LogView(lambda m: None)
calls = []
real = v._refill
v._refill = lambda: (calls.append(1), real())[1]
v.update_sources(str(d), [dict(COMPS[0], rss=1)], 'ERROR')
v.update_sources(str(d), [dict(COMPS[0], rss=2)], 'ERROR')
v.update_sources(str(d), [dict(COMPS[0], rss=3)], 'ERROR')
v.stop()
print(len(calls))
")
  rm -rf "$dir"
  assert_eq "$out" "1" "only the first frame changes the shape"
}

# ── settings and grouping ───────────────────────────────────────────────────

_settings_drive() { # $1 = python body, with Settings/SETTINGS_BY_KEY/group_of in scope
  _py "
import os, pathlib, sys
import gi
gi.require_version('Gtk', '4.0')
$_PRELUDE
Settings, SETTINGS, SETTINGS_BY_KEY = pgui.Settings, pgui.SETTINGS, pgui.SETTINGS_BY_KEY
group_of = pgui.group_of
$1
"
}

# Run a program and hand back its stdout — but say what went wrong when there
# is no stdout to hand back. GTK aborts rather than raises on a good few
# environment problems, so "the assertion got an empty string" is the normal
# shape of a failure here, and it is worth nothing on its own.
_py() { # $1 = python program → its stdout; its stderr onto the run's stderr
  local err out rc
  err=$(mktemp)
  out=$("$PY_WITH_GI" -c "$1" 2>"$err"); rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '      \033[90mpython exited %d: %s\033[0m\n' "$rc" "$(tail -1 "$err")" >&2
  fi
  rm -f "$err"
  # no_cr because the interpreter with the bindings on Windows is a NATIVE
  # build: it writes CRLF into this pipe, and every assertion below compares
  # whole lines. See harness.sh. Every python in this file runs through here,
  # so this is the one place it has to be said.
  no_cr "$out"
}

test_settings_round_trip_through_the_house_file_format() {
  gui_available || return 0
  local dir; dir=$(mktemp -d)
  local out; out=$(_settings_drive "
path = pathlib.Path('$(py_path "$dir")/gui')
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
s = Settings(pathlib.Path('$(py_path "$dir")/gui'))
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
print(Settings(pathlib.Path('$(py_path "$dir")/gui'))['group'])
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

# ── the overview: the verdict, and where it comes from ──────────────────────

test_the_verdict_is_read_from_the_stream_not_re_derived() {
  gui_available || return 0
  # The GUI must not decide for itself whether the stack is healthy: that
  # judgement lives in lib/19-diag.sh so the terminal and the desktop app can
  # never disagree about it. Here the components are all fine and the verdict
  # says otherwise — the verdict has to win.
  local out; out=$(_settings_drive "
state = {'health': {'verdict': 'crit', 'headline': 'memory pressure'},
         'summary': {'up': 4, 'crashed': 0}}
print(' '.join(str(x) for x in pgui.verdict_of(state)))
")
  assert_match "$out" '^crit ' "the stream's verdict, not one inferred from states"
  assert_match "$out" 'memory pressure' "and its headline"
}

test_an_old_pitcrew_without_a_verdict_still_gets_a_header() {
  gui_available || return 0
  # The stream gained `health` after the GUI shipped. A blank status light is
  # worse than an approximate one, so fall back to the counts.
  local out; out=$(_settings_drive "
print(pgui.verdict_of({'summary': {'up': 2, 'crashed': 1}})[0])
print(pgui.verdict_of({'summary': {'up': 2, 'starting': 1}})[0])
print(pgui.verdict_of({'summary': {'up': 2}})[0])
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "crit" "a crash is critical"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "warn" "something starting is not settled"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "ok"   "otherwise fine"
}

test_findings_are_ordered_worst_first() {
  gui_available || return 0
  local out; out=$(_settings_drive "
state = {'health': {'findings': [
  {'severity': 'info', 'title': 'i'},
  {'severity': 'crit', 'title': 'c'},
  {'severity': 'warn', 'title': 'w'}]}}
print(''.join(f['title'] for f in pgui.findings_of(state)))
")
  assert_eq "$out" "cwi" "critical, then warning, then note"
}

test_the_machine_meters_omit_what_the_machine_does_not_have() {
  gui_available || return 0
  # A swap row reading 0 B / 0 B on a swapless container is noise, and the
  # absence of swap is not a fact worth a line of screen.
  local out; out=$(_settings_drive "
full = {'memTotal': 1000, 'memUsed': 500, 'cpuPercent': 20, 'swapTotal': 100, 'swapUsed': 50}
print(' '.join(r[0] for r in pgui.machine_meters(full, 250)))
print(' '.join(r[0] for r in pgui.machine_meters({'cpuPercent': 5}, 0)))
print(int(pgui.machine_meters(full, 250)[0][1]))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "RAM CPU SWAP Stack" "every gauge it can measure"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "CPU" "and only those"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "50" "percentages are of the machine"
}

test_the_largest_consumers_are_ranked_and_shared_out() {
  gui_available || return 0
  local out; out=$(_settings_drive "
comps = [{'name': 'small', 'rss': 100}, {'name': 'big', 'rss': 300},
         {'name': 'off', 'rss': None}]
rows = pgui.top_consumers(comps)
print(' '.join(r[0] for r in rows))
print(int(rows[0][2]))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "big small" "biggest first, nothing for what is not running"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "75" "share is of what the project holds"
}

test_the_whole_window_renders_a_frame_without_a_project() {
  gui_display || return 0
  # A smoke test over the real widget tree: every view is built, then one
  # synthetic frame is pushed through the same path the stream uses. A typo in
  # a rarely-taken render branch is otherwise only found by opening the app.
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
state = {
  'project': 'demo', 'at': 1000, 'logDir': '/tmp', 'errorPattern': 'ERROR',
  'machine': {'memTotal': 16 * 1024**3, 'memUsed': 15 * 1024**3,
              'cpuPercent': 40, 'swapTotal': 2 * 1024**3, 'swapUsed': 1024**3},
  'components': [
    {'name': 'be-api', 'app': 'api', 'role': 'be', 'state': 'up', 'rss': 2 * 1024**3,
     'cpu': 1, 'errors': 0, 'port': 8080, 'limit': 4 * 1024**3, 'since': 100, 'idle': 900},
    {'name': 'be-worker', 'app': 'worker', 'role': 'be', 'state': 'crashed', 'rss': None,
     'cpu': None, 'errors': 2, 'exit': 1, 'since': None}],
  'deps': [{'name': 'pg', 'state': 'down'}],
  'health': {'verdict': 'crit', 'headline': 'be-worker crashed',
             'counts': {'crit': 1, 'warn': 1, 'info': 0},
             'findings': [
               {'severity': 'crit', 'id': 'crashed', 'title': 'be-worker crashed',
                'detail': 'exited 1', 'fix': 'pitcrew logs be-worker', 'scope': 'be-worker'},
               {'severity': 'warn', 'id': 'memory', 'title': 'memory pressure',
                'detail': 'lots in use', 'fix': 'pitcrew diagnose', 'scope': ''}],
             'deep': False,
             'recoverable': {'components': ['be-api'], 'protected': [], 'bytes': 2 * 1024**3}},
  'summary': {'up': 1, 'starting': 0, 'crashed': 1, 'external': 0, 'down': 0}}
w._on_state(state)
print(w._verdict_title.get_text())
print(len(w._finding_rows), len(w._recover_rows), len(w._consumer_rows))
print('overview' in [w._stack.get_visible_child_name() or '', 'overview'])
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "be-worker crashed" "the headline is the verdict"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "2 1 1" "findings, recovery candidates, consumers"
}

test_every_page_fits_a_small_window() {
  gui_available || return 0
  # A Gtk.Stack sizes to its LARGEST child unless told otherwise, so the Logs
  # toolbar — the widest thing in the app at 854px — was setting the minimum
  # width of every other page. Projects needs 127 and was being given 854,
  # which is why a narrow window clipped rows that had room to shrink.
  #
  # 640 is not arbitrary: it is a half-screen window on a 1280 laptop, which is
  # how a monitoring tool is actually used — beside the thing being monitored.
  local out; out=$(_settings_drive "
from gi.repository import Adw, Gtk
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
w.present()
w._set_compact(True)
w._logs.role_filter().set_visible(False)
worst = 0
for page in ('overview', 'components', 'resources', 'logs', 'projects'):
    child = w._stack.get_child_by_name(page)
    worst = max(worst, child.measure(Gtk.Orientation.HORIZONTAL, -1)[0])
print(worst <= 640, worst)
")
  assert_match "$out" "^True " "no page needs more than 640px once narrowed: $out"
}

test_the_stack_does_not_charge_every_page_for_the_widest_one() {
  gui_available || return 0
  # The fix for the above, asserted directly: without it the stack reports the
  # widest child whatever is on screen, and a page that could shrink never
  # gets the chance.
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
print(w._stack.get_hhomogeneous(), w._body.get_hhomogeneous())
")
  assert_eq "$out" "False False" "each page is measured on its own"
}

test_the_header_loses_the_same_columns_its_rows_do() {
  gui_available || return 0
  # A header that keeps a column its rows have dropped is worse than no header:
  # every figure below it is then labelled with the wrong name.
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
from pitcrewgui.widgets import ComponentRow, set_row_compact
head = ComponentRow.header()
row = ComponentRow('be-a', '#3fb950', lambda *a: None, lambda *a: None, lambda *a: None)
set_row_compact(head, True)
row.set_compact(True)
print(len(head._optional), len(row._optional))
print(all(not w.get_visible() for w in head._optional))
print(all(not w.get_visible() for w in row._optional))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "3 3" "the same three columns"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True" "gone from the header"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "True" "and from the rows"
}

test_one_ramp_means_one_ramp() {
  gui_available || return 0
  # AGENTS.md says resource meters and status badges draw from the same ramp,
  # and that is the kind of invariant that decays silently — it was lost once
  # already to a stock LevelBar whose "high" offset painted orange, which made
  # a 32%-full meter and a warning badge the same hue.
  #
  # Three states ARE the ramp and must stay it. Two deliberately are not:
  # `external` is a distinct state rather than a severity, and `down` is not a
  # level of anything. Pinned in both directions so a future edit has to be a
  # decision rather than an accident.
  local out; out=$(_settings_drive "
from pitcrewgui.model import STATE_STYLE, RAMP, VERDICT_STYLE
print(STATE_STYLE['up'][1] == RAMP['ok'])
print(STATE_STYLE['starting'][1] == RAMP['warn'])
print(STATE_STYLE['crashed'][1] == RAMP['crit'])
print(all(VERDICT_STYLE[k][0] == RAMP[k] for k in ('ok', 'warn', 'crit')))
print(STATE_STYLE['external'][1] not in RAMP.values())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "True" "up is the ramp's ok"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True" "starting is its warn"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "True" "crashed is its crit"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "True" "and the verdict draws from it too"
  assert_eq "$(printf '%s' "$out" | sed -n 5p)" "True" \
    "external is a state, not a severity — deliberately outside the ramp"
}

test_nothing_to_say_is_one_grey() {
  gui_available || return 0
  # A stopped component's dot and a calm meter both mean "nothing to say", and
  # they were two different greys — #57606a against #6e7681. Close enough to
  # look like a rendering artefact and far enough to be one more colour to
  # explain.
  local out; out=$(_settings_drive "
from pitcrewgui.model import STATE_STYLE, RAMP, UNKNOWN_STYLE
print(STATE_STYLE['down'][1] == RAMP['calm'], UNKNOWN_STYLE[1] == RAMP['calm'])
")
  assert_eq "$out" "True True" "one grey for nothing-to-say"
}

test_a_fresh_install_is_told_what_to_do_rather_than_shown_five_empty_pages() {
  gui_available || return 0
  # A brand-new install has nothing to stream FROM, and five empty pages behind
  # a switcher looks like a broken app rather than one that has not been set up.
  # The banner alone was the whole answer: the right weight for a transient
  # failure and the wrong one for somebody's first minute.
  local home; home=$(mktemp -d); mkdir -p "$home/projects"
  local out; out=$(PITCREW_HOME="$home" _settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
print(w._body.get_visible_child_name())
print(w._welcome_page.get_title())
print(w._welcome_button.get_visible())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "welcome" "not the empty pages"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "No projects yet" "says so"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "True" "and offers the only thing that helps"
}

test_a_failure_before_the_first_frame_uses_the_clis_own_words() {
  gui_available || return 0
  # pitcrew knows why better than the GUI does, and it is the same sentence the
  # terminal would have printed. The `<dir>` in it is why the status page must
  # not parse markup either.
  # With a project registered: "no projects at all" takes precedence over any
  # message, because "Add a project" is more actionable than a raw error, and
  # this test is about the OTHER branch.
  local home; home=$(mktemp -d); mkdir -p "$home/projects"
  printf 'root: /tmp\n' > "$home/projects/demo.yaml"
  local out; out=$(PITCREW_HOME="$home" _settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', 'demo', Settings(pathlib.Path('$(mktemp -d)/gui')))
w._fail('no config here — write a pitcrew.yaml, or: pitcrew init <dir>')
print(w._body.get_visible_child_name())
print(w._welcome_page.get_title())
print(w._welcome_page.get_description())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "welcome" "the whole window, not a strip"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "Nothing to show" ""
  assert_match "$(printf '%s' "$out" | sed -n 3p)" "pitcrew init <dir>" \
    "the angle brackets survive — the status page is text, not markup"
}

test_a_stream_that_drops_later_keeps_the_last_known_state() {
  gui_available || return 0
  # Swapped out on the first frame and never swapped back. A failure after that
  # has a banner AND a window full of the last thing that was true, which is
  # more use than a status page that throws it away.
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', 'demo', Settings(pathlib.Path('$(mktemp -d)/gui')))
w._on_state({'components': [], 'at': 0, 'logDir': '', 'errorPattern': '',
  'machine': {'memTotal': 1, 'memUsed': 0, 'cpuPercent': 0, 'swapTotal': 0, 'swapUsed': 0},
  'health': {'verdict': 'ok', 'headline': '', 'deep': False,
             'counts': {'crit': 0, 'warn': 0, 'info': 0}, 'findings': [],
             'recoverable': {'components': [], 'protected': [], 'bytes': 0}},
  'summary': {'up': 0, 'starting': 0, 'crashed': 0, 'external': 0, 'down': 0},
  'deps': [], 'profiles': []})
print(w._body.get_visible_child_name())
w._fail('the stream ended')
print(w._body.get_visible_child_name(), w._banner.get_revealed())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "live" "the first frame swaps it in"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "live True" "and a later failure is the banner's job"
}

test_a_full_run_adds_to_the_stream_rather_than_replacing_it() {
  gui_available || return 0
  # The stream carries the cheap checks; `pitcrew diagnose` also runs the slow
  # ones. Merged and de-duplicated on (id, scope), so the list does not flicker
  # between two versions of the same finding on every frame.
  local out; out=$(_settings_drive "
live = [{'severity': 'crit', 'id': 'crashed', 'scope': 'be-a', 'title': 'c'}]
deep = [{'severity': 'crit', 'id': 'crashed', 'scope': 'be-a', 'title': 'c'},
        {'severity': 'warn', 'id': 'jvm-cap', 'scope': 'be-a', 'title': 'j'}]
rows = pgui.merge_findings(live, deep)
print(''.join(f['title'] for f in rows))
print(''.join(f['title'] for f in pgui.merge_findings(live, [])))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "cj" "the duplicate is not listed twice"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "c"  "and nothing is invented when there is no deep run"
}

test_the_overview_shows_what_it_will_never_propose() {
  gui_display || return 0
  # A candidate list that silently omits your biggest idle service reads as a
  # bug. The lock has to be visible.
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
state = {
  'at': 1000, 'machine': {'memTotal': 100, 'memUsed': 90, 'cpuPercent': 1},
  'components': [
    {'name': 'be-api', 'app': 'api', 'role': 'be', 'state': 'up', 'rss': 10,
     'cpu': 0, 'errors': 0, 'since': 1, 'idle': 900, 'protected': True},
    {'name': 'be-etl', 'app': 'etl', 'role': 'be', 'state': 'up', 'rss': 20,
     'cpu': 0, 'errors': 0, 'since': 1, 'idle': 900, 'protected': False}],
  'deps': [],
  'health': {'verdict': 'warn', 'headline': 'memory pressure', 'deep': False,
             'counts': {'crit': 0, 'warn': 1, 'info': 0}, 'findings': [],
             'recoverable': {'components': ['be-etl'], 'protected': ['be-api'], 'bytes': 20}},
  'summary': {'up': 2}}
w._on_state(state)
print(len(w._recover_rows), len(w._protected_rows))
print(' '.join(w._recoverable))
print(w._deep_button.get_visible())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "1 1" "one candidate, one lock"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "be-etl" "the protected one can never reach the stop call"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "True" "and a shallow frame offers the full run"
}

test_a_deep_frame_does_not_offer_to_run_deeper() {
  gui_display || return 0
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
w._on_state({'at': 1, 'machine': {}, 'components': [], 'deps': [], 'summary': {},
             'health': {'verdict': 'ok', 'headline': 'fine', 'deep': True,
                        'counts': {}, 'findings': [], 'recoverable': {}}})
print(w._deep_button.get_visible())
")
  assert_eq "$out" "False" "the button is for asking, not for decoration"
}

# ── everything the GUI can now reach ────────────────────────────────────────

test_a_suggested_command_is_only_run_when_it_is_one_we_understand() {
  gui_available || return 0
  # A finding's `fix` is a string and a plugin can put anything in it, so it is
  # never handed to a shell — it is split, matched against a small list of
  # verbs, and run as argv or not at all.
  local out; out=$(_settings_drive "
for fix in ['pitcrew logs be-api', 'pitcrew restart be-api', 'pitcrew stale --restart',
            'pitcrew stop be-a be-b']:
    print(pgui.fix_action(fix)[0], pgui.fix_action(fix)[3])
for fix in ['rm -rf /', 'pitcrew limit be-api 2G', 'pitcrew stop ../../etc',
            'pitcrew stop --deps', 'pitcrew', 'pitcrew diagnose', '']:
    print(pgui.fix_action(fix))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "logs False"    "opening a log is not destructive"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "restart True"  "restarting is"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "stale True"    "so is restarting the stale ones"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "stop True"     "several components at once"
  local refused; refused=$(printf '%s' "$out" | sed -n '5,11p' | tr '\n' ' ')
  assert_eq "$refused" "None None None None None None None" "everything else is text, not a button"
}

test_the_process_tree_comes_from_the_stream() {
  gui_display || return 0
  # The GUI must never run its own ps — the tree arrives in the state object.
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
t = pgui.ProcessTree()
print(len(t._rows))
t.set_processes([{'pid': 1, 'cmd': 'java', 'rss': 900, 'cpu': 12},
                 {'pid': 2, 'cmd': 'bash', 'rss': 100, 'cpu': None}])
print(len(t._rows))
t.set_processes([])
print(len(t._rows))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "0" "nothing before a frame arrives"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "2" "a row per process"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "0" "and it empties when the service stops"
}

test_the_detail_dialog_keeps_up_with_later_frames() {
  gui_display || return 0
  # Watching a heap climb is what someone opens this for. A dialog frozen at
  # the instant you clicked is a screenshot, not a monitor.
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
runner = pgui.Runner('/bin/true')
comp = {'name': 'be-api', 'state': 'starting', 'rss': 100, 'limit': 1000,
        'processes': [{'pid': 1, 'cmd': 'java', 'rss': 100, 'cpu': 0}]}
d = pgui.DetailDialog(runner, 'p', comp, '/tmp', 10, lambda *a: None)
print(len(d._procs._rows), d._status.get_subtitle())
d.update({**comp, 'state': 'up',
          'processes': [{'pid': 1, 'cmd': 'java', 'rss': 900, 'cpu': 5},
                        {'pid': 2, 'cmd': 'sh', 'rss': 10, 'cpu': 0}]})
print(len(d._procs._rows), d._status.get_subtitle())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "1 starting" "opened on the frame that was current"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "2 up" "and follows the stream after that"
}

test_dependencies_can_be_acted_on_not_just_looked_at() {
  gui_display || return 0
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
w._render_deps([{'name': 'pg', 'state': 'down'}])
row, dot, badge = w._dep_rows['pg']
print(badge.get_text())
w._render_deps([{'name': 'pg', 'state': 'up'}])
print(w._dep_rows['pg'][2].get_text(), len(w._dep_rows))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "down" "state is shown"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "up 1" "and updated in place, not duplicated"
}

# ── running the CLI from a GUI ──────────────────────────────────────────────

test_the_cli_argv_names_an_interpreter_only_where_it_has_to() {
  gui_available || return 0
  # `pitcrew` is a bash script with a shebang. Linux and macOS honour that, so
  # the path alone is executable. Windows has no shebang — CreateProcess on a
  # file starting with `#!` fails with "not a valid application", which from a
  # GUI with no console is a button that does nothing at all.
  # Both branches are set explicitly, because ONE of these runs on the OS it is
  # asking about: the Windows GUI job's interpreter really is Windows, so the
  # off-Windows case inherited IS_WINDOWS=True and asserted the wrong branch
  # against itself. What is under test is the function, not the runner.
  local out; out=$(_settings_drive "
import pitcrewgui.platform as pf
pf.IS_WINDOWS = False
print(' '.join(pf.cli_argv('/home/me/.local/bin/pitcrew', ['status', '--json'])))
pf.IS_WINDOWS = True
pf.find_bash = lambda: 'C:/msys64/usr/bin/bash.exe'
print(' '.join(pf.cli_argv('C:/x/pitcrew', ['status'])))
pf.find_bash = lambda: None
print(' '.join(pf.cli_argv('C:/x/pitcrew', ['status'])))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" \
    "/home/me/.local/bin/pitcrew status --json" "off Windows the path is the command"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" \
    "C:/msys64/usr/bin/bash.exe C:/x/pitcrew status" "on Windows bash runs it"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" \
    "C:/x/pitcrew status" "and with no bash it still spawns, so the error names the file"
}

test_nothing_in_the_gui_builds_a_pitcrew_argv_by_hand() {
  gui_available || return 0
  # One function builds every invocation. The alternative is being right in the
  # three places someone remembered and wrong in the fourth — and the fourth
  # only fails on an OS nobody testing this is running.
  # Look for the CLI path at the head of a list literal, which is what building
  # an argv by hand looks like — not for the spawn call, which takes a variable
  # and would have let exactly that through.
  local stray
  stray=$(grep -n '\[ *self\._pitcrew\|\[ *pitcrew,\|\[ *self\.pitcrew' \
            "$GUI_DIR"/pitcrewgui/*.py | grep -v 'platform\.py' || true)
  assert_empty "$stray" "every CLI argv comes from cli_argv"
}

# ── project registry and config editing ─────────────────────────────────────

test_the_config_editor_follows_the_source_indirection() {
  gui_available || return 0
  # A registry entry for a repo that ships its own pitcrew.config.sh only sets
  # PITCREW_ROOT and sources it — editing that stub would change nothing pitcrew
  # reads, so the GUI has to open the file with the content in it.
  local home repo; home=$(mktemp -d); repo=$(mktemp -d)
  mkdir -p "$home/projects"
  # Written, read back and compared in PYTHON's spelling of a path throughout —
  # on Windows the interpreter's is not the shell's, and a test that mixed the
  # two would be asserting about the difference rather than about the app.
  local home_py repo_py; home_py=$(py_path "$home"); repo_py=$(py_path "$repo")
  # $PITCREW_ROOT stays literal on purpose — that is what init writes into the stub.
  # shellcheck disable=SC2016
  printf 'PITCREW_ROOT=%s\nsource "$PITCREW_ROOT/pitcrew.config.sh"\n' "$repo_py" > "$home/projects/stub.sh"
  printf 'PITCREW_APPS=(a)\n' > "$repo/pitcrew.config.sh"
  printf 'PITCREW_ROOT=%s\nPITCREW_APPS=(a)\n' "$repo_py" > "$home/projects/own.sh"

  local out; out=$(PITCREW_HOME=$home_py _settings_drive "
print(pgui.project_config_path('stub'))
print(pgui.project_config_path('own'))
print(pgui.declared_root(pgui.project_file('own')))
print(' '.join(pgui.known_projects()))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "$repo_py/pitcrew.config.sh" "stub resolves into the repo"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "$home_py/projects/own.sh" "a self-contained entry is edited in place"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "$repo_py" "PITCREW_ROOT is read without sourcing"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "own stub" "the registry lists both"
  rm -rf "$home" "$repo"
}

test_the_config_editor_follows_the_include_indirection_too() {
  gui_available || return 0
  # The YAML twin of the test above: a registry entry for a repo that ships its
  # own pitcrew.yaml records the root and includes it, so the GUI has to open
  # the repo's file rather than the two-line stub.
  local home repo; home=$(mktemp -d); repo=$(mktemp -d)
  mkdir -p "$home/projects"
  local home_py repo_py; home_py=$(py_path "$home"); repo_py=$(py_path "$repo")
  printf 'root: %s\ninclude: pitcrew.yaml\n' "$repo_py" > "$home/projects/ystub.yaml"
  printf 'name: shipped\napps:\n  a:\n    be:\n      cmd: "true"\n' > "$repo/pitcrew.yaml"
  printf 'root: %s\nname: own\n' "$repo_py" > "$home/projects/yown.yaml"

  local out; out=$(PITCREW_HOME=$home_py _settings_drive "
print(pgui.project_config_path('ystub'))
print(pgui.project_config_path('yown'))
print(pgui.declared_root(pgui.project_file('yown')))
print(' '.join(pgui.known_projects()))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "$repo_py/pitcrew.yaml" "stub resolves into the repo"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "$home_py/projects/yown.yaml" "a self-contained entry is edited in place"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "$repo_py" "root: is read without loading the config"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "yown ystub" "the registry lists both"
  rm -rf "$home" "$repo"
}

test_the_registry_lists_both_formats_side_by_side() {
  gui_available || return 0
  local home; home=$(mktemp -d); mkdir -p "$home/projects"
  printf 'root: /tmp\n'      > "$home/projects/newer.yaml"
  printf 'PITCREW_ROOT=/tmp\n' > "$home/projects/older.sh"
  local out; out=$(PITCREW_HOME=$home _settings_drive "
print(' '.join(pgui.known_projects()))
print(pgui.project_file('older').name)
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "newer older" "one name per project, either format"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "older.sh" "and each resolves to its own file"
  rm -rf "$home"
}

test_a_quoted_root_survives_being_read_back() {
  gui_available || return 0
  # init writes PITCREW_ROOT with printf %q, so a path with a space arrives quoted.
  local home; home=$(mktemp -d); mkdir -p "$home/projects"
  printf "PITCREW_ROOT='/tmp/two words'\nPITCREW_APPS=(a)\n" > "$home/projects/spaced.sh"
  local out; out=$(PITCREW_HOME=$home _settings_drive "
print(pgui.declared_root(pgui.project_file('spaced')))
")
  assert_eq "$out" "/tmp/two words" "the quoting is undone, not carried through"
  rm -rf "$home"
}

test_a_config_that_bash_cannot_parse_is_refused() {
  gui_available || return 0
  # Saving an unparseable config breaks every pitcrew command for that project,
  # including the one that would tell you why.
  local out; out=$(_settings_drive "
print('ok' if pgui.bash_syntax_error('PITCREW_APPS=(a b)') == '' else 'WRONGLY-REJECTED')
bad = pgui.bash_syntax_error('if [ 1 ]; then')
print('rejected' if bad else 'WRONGLY-ACCEPTED')
print('leaks-tmp-path' if '/tmp' in bad else 'path-hidden')
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "ok" "a valid config saves"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "rejected" "an invalid one does not"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "path-hidden" "and the message names the config, not a temp file"
}

test_paths_with_shell_punctuation_still_render() {
  gui_available || return 0
  # Adw parses subtitles as Pango markup regardless of use-markup, so a checkout
  # at /srv/a&b rendered as an empty row and a warning nobody reads.
  local out; out=$(_settings_drive "print(pgui.plain('/srv/a&b <x>'))")
  assert_eq "$out" "/srv/a&amp;b &lt;x&gt;" "escaped for the markup parser"
}

# ── the platform seam ───────────────────────────────────────────────────────

test_only_the_platform_module_knows_which_os_this_is() {
  [ -d "$GUI_DIR/pitcrewgui" ] || return 0
  # The bargain lib/00-platform.sh strikes, for the GUI: adding an OS means
  # editing one file. This fails the moment an OS check leaks anywhere else,
  # which is how a "portable" codebase quietly stops being one.
  local offenders
  offenders=$(grep -lE 'platform\.system|sys\.platform|"Darwin"|IS_MACOS|IS_WINDOWS|/opt/homebrew|uname' \
    "$GUI_DIR"/pitcrewgui/*.py 2>/dev/null | grep -v '/platform\.py$' || true)
  assert_empty "$offenders" "OS knowledge outside pitcrewgui/platform.py"
}

test_the_config_directory_is_deliberately_not_platform_specific() {
  gui_available || return 0
  # macOS convention says ~/Library/Application Support. That would be tidy and
  # wrong: the GUI must read the registry the `pitcrew` COMMAND writes, and
  # pitcrew uses $HOME/.config/pitcrew everywhere with no branch.
  # The harness exports PITCREW_HOME to a temp dir so the suite never touches the
  # real registry — unset it here to see the default this test is actually about.
  local out; out=$( (unset PITCREW_HOME; _settings_drive "
import pathlib
print(pgui.pitcrew_home() == pathlib.Path.home() / '.config' / 'pitcrew')
") )
  assert_eq "$out" "True" "same path the CLI uses, on every OS"
  # Set in the interpreter, and compared as a Path rather than as a string.
  # Both for the same reason: on the Windows job this crosses an MSYS boundary,
  # which rewrites a POSIX-looking value in the environment it hands a native
  # process (/tmp/elsewhere arrived as D:/a/_temp/msys64/tmp/elsewhere), and
  # pathlib then spells the result back with backslashes. Neither is what this
  # test is about — which is that the variable is READ at all.
  local out2; out2=$(_settings_drive "
import os, pathlib
os.environ['PITCREW_HOME'] = '/tmp/elsewhere'
print(pgui.pitcrew_home() == pathlib.Path('/tmp/elsewhere'))
")
  assert_eq "$out2" "True" "and PITCREW_HOME still overrides it"
}

test_config_validation_uses_a_bash_pitcrew_would_accept() {
  gui_available || return 0
  # pitcrew refuses to run under bash < 5. macOS still ships 3.2 as /bin/bash,
  # so validating with "whatever bash is first" would accept configs the tool
  # then rejects — or reject ones it would have run.
  local out; out=$(_settings_drive "
found = pgui.bash5()
if found is None:
    print('none', 'message' if pgui.missing_bash_message() else 'SILENT')
else:
    import subprocess
    major = subprocess.run([found, '-c', 'echo \${BASH_VERSINFO[0]}'],
                           capture_output=True, text=True).stdout.strip()
    print('found', 'ge5' if int(major) >= 5 else 'TOO-OLD')
")
  assert_match "$out" '^(found ge5|none message)$' "a bash 5, or an honest refusal"
}

test_every_platform_offers_a_last_resort_on_path() {
  gui_available || return 0
  # A hardcoded absolute interpreter is what broke this on macOS in the first
  # place. Whatever the OS, the list has to end with something $PATH can find.
  local out; out=$(_settings_drive "
print(pgui.python_candidates()[-1])
print(bool(pgui.missing_bindings_message()))
")
  assert_not_match "$(printf '%s' "$out" | sed -n 1p)" '^/' "the last candidate is not an absolute path"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True" "and there is an install hint when none work"
}

test_a_gui_launched_app_finds_the_cli_that_shipped_with_it() {
  gui_available || return 0
  # $PATH is the first answer and the right one when it works. When it does
  # not — an app grid, a Launchpad entry, a Windows shortcut, all of which
  # start with a minimal environment — the checkout this GUI was installed
  # from is not a guess: bin/ and gui/ are siblings in the repo.
  #
  # On Windows the guess was not merely unreliable, it could not work: MSYS2
  # bash has $HOME=C:\msys64\home\you and writes the shim under it, while the
  # native python a shortcut runs reports Path.home() as C:\Users\you. Every
  # button in the app was dead for that one reason.
  local out; out=$(_settings_drive "
import pathlib
import pitcrewgui.platform as pf
first = pf._cli_fallbacks()[0]
print(first == pf.REPO_ROOT / 'bin' / 'pitcrew')
print(first.is_file())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "True" "the checkout comes first among the fallbacks"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True" "and it is really there"
}

test_msys2_python_is_still_windows() {
  gui_available || return 0
  # MSYS2 ships two kinds of python. The mingw/ucrt builds are native Windows
  # and report "Windows"; the msys one reports "MSYS_NT-10.0-22631". Under that
  # interpreter every Windows special case switched off — so the GUI would run
  # a bash script by path on an OS with no shebangs, i.e. a button that does
  # nothing.
  local out; out=$(_settings_drive "
import importlib, platform, sys
for name in ('Windows', 'MSYS_NT-10.0-22631', 'MINGW64_NT-10.0', 'CYGWIN_NT-10.0', 'Linux'):
    platform.system = lambda name=name: name
    module = importlib.reload(importlib.import_module('pitcrewgui.platform'))
    print(name, module.IS_WINDOWS)
")
  assert_match "$out" 'MSYS_NT-10\.0-22631 True' "the msys python counts as Windows"
  assert_match "$out" 'MINGW64_NT-10\.0 True'    "so does a mingw one"
  assert_match "$out" 'CYGWIN_NT-10\.0 True'     "and cygwin"
  assert_match "$out" 'Linux False'              "and Linux does not"
}

test_the_wsl_launcher_is_never_mistaken_for_a_bash() {
  gui_available || return 0
  # C:\Windows\System32\bash.exe is on the PATH of every machine with WSL
  # enabled, and it is what shutil.which("bash") finds first from a shortcut.
  # Running the CLI through it executes pitcrew inside a Linux VM against a
  # filesystem with none of the user's project in it — a failure that reads
  # like pitcrew being broken rather than like the wrong bash.
  local out; out=$(_settings_drive "
import pitcrewgui.platform as pf
for path in (r'C:\\Windows\\System32\\bash.exe', r'C:\\Windows\\SysNative\\bash.exe',
             r'C:\\msys64\\usr\\bin\\bash.exe', '/usr/bin/bash'):
    print(pf._is_wsl_stub(path))
")
  assert_eq "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ *$//')" "True True False False" \
    "only System32/SysNative bash.exe is the WSL launcher"
}

test_a_windows_app_with_no_console_can_still_say_what_went_wrong() {
  gui_available || return 0
  # The shortcut runs pythonw.exe, whose sys.stderr is None — and CPython's
  # print() returns SILENTLY when there is nowhere to write. So "no bindings",
  # "no bash", "pitcrew not found" all came out as a double-click that did
  # nothing at all. report_fatal is the one channel that survives that.
  local out; out=$(_settings_drive "
import io, sys
import pitcrewgui.platform as pf
captured = io.StringIO()
real = sys.stderr
sys.stderr = captured
pf.report_fatal('something broke')
sys.stderr = real
print(repr(captured.getvalue().strip()))
sys.stderr = None
pf.IS_WINDOWS = False
pf.report_fatal('nowhere to print this')      # must not raise
sys.stderr = real
print('survived')
")
  assert_match "$out" "pitcrew-gui: something broke" "a console gets the message"
  assert_match "$out" "survived" "and no console is not a crash"
}

test_nothing_shells_out_on_windows_without_suppressing_the_console() {
  gui_available || return 0
  # Every helper the GUI runs — bash, python -c, pitcrew check — is a console
  # program. Started from pythonw, which has no console, Windows gives each one
  # a fresh black window that appears and vanishes on a timer.
  #
  # And the switch is sys.platform == 'win32', NOT IS_WINDOWS: MSYS2's msys
  # python answers yes to "behaves like Windows" and raises ValueError on
  # creationflags, being a Cygwin-style POSIX build — which would break the
  # launcher on the one interpreter whose only job is to find a better one.
  #
  # Every case sets _TAKES_CREATIONFLAGS itself. On the Windows GUI job this
  # module is imported by an interpreter for which it is genuinely True, so
  # leaving it alone asked the host what it is rather than asking the function
  # what it does — and the first two cases failed on the OS they are about.
  local out; out=$(_settings_drive "
import pitcrewgui.platform as pf
pf.IS_WINDOWS, pf._TAKES_CREATIONFLAGS = False, False
print(pf.no_window_kwargs() == {})
pf.IS_WINDOWS = True
print(pf.no_window_kwargs() == {})
pf._TAKES_CREATIONFLAGS = True
print(pf.no_window_kwargs().get('creationflags') == 0x08000000)
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "True" "nothing added off Windows"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True" "nor on an MSYS python that would reject it"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "True" "CREATE_NO_WINDOW where it is accepted"

  local bare
  bare=$(grep -n 'subprocess\.run(' "$GUI_DIR"/pitcrewgui/*.py | grep -v 'platform\.py' || true)
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" | grep -q 'no_window_kwargs' && continue
    # The call may span lines; check the file has the kwargs somewhere near.
    local file; file=${line%%:*}
    grep -q 'no_window_kwargs' "$file" || _t_bad "$file shells out without no_window_kwargs()"
  done <<< "$bare"
}

test_the_two_python_searches_agree_about_windows() {
  gui_available || return 0
  # gui/pyfind.sh answers "which python should the INSTALLER report on"; this
  # module answers "which should the launcher re-exec into". Different jobs,
  # but a Windows box where one finds MSYS2 and the other does not is exactly
  # the install that reports success and produces nothing runnable.
  # IS_MACOS off as well as IS_WINDOWS on: python_candidates() asks the macOS
  # question first, so on a Mac this test was reading the Homebrew list and
  # calling it a Windows failure.
  local out; out=$(_settings_drive "
import os
import pitcrewgui.platform as pf
pf.IS_MACOS = False
pf.IS_WINDOWS = True
os.environ['MINGW_PREFIX'] = '/ucrt64'
candidates = pf.python_candidates()
print(candidates[0])
print(any('ucrt64' in c for c in candidates), any('mingw64' in c for c in candidates))
print(candidates[-1])
")
  assert_match "$(printf '%s' "$out" | sed -n 1p)" 'ucrt64' "the live MSYS2 prefix comes first"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True True" "both prefixes are covered"
  assert_not_match "$(printf '%s' "$out" | sed -n 3p)" '[/\\]' "and it still ends with a bare name"
}

# ── the config form ─────────────────────────────────────────────────────────
#
# An app is an open group of components now, and hand-indenting a fourth role
# into a YAML file is exactly the friction the form exists to remove. What it
# must NOT do is rewrite the file: a config is something people annotate, and
# an editor that regenerates it hands back a version with every comment gone.

_config_form() { # $1 = python body, with `dialog` bound to a built ConfigDialog
  _py "
import json, pathlib, subprocess, sys
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Adw', '1')
from gi.repository import Adw
$_PRELUDE
Adw.init()
import pitcrewgui.dialogs as dialogs

SAMPLE = pathlib.Path('$(py_path "$SAMPLE_YAML")')
dialogs.project_config_path = lambda name: SAMPLE
dialog = dialogs.ConfigDialog(pgui.Runner('$PITCREW_DIR_PY/bin/pitcrew'), 'demo', lambda: None)
# cli_argv, not a bare path: on Windows bin/pitcrew is a bash script that
# nothing will execute directly, and naming the interpreter is exactly what
# that function is for — the app is not allowed to build an argv by hand
# here either.
state = json.loads(subprocess.run(
    pgui.cli_argv('$PITCREW_DIR_PY/bin/pitcrew',
                  ['-C', '$PITCREW_DIR_PY/test/fixture-yaml', 'config', '--json']),
    capture_output=True, text=True).stdout)
dialog._form_ready(state, '')

def text():
    start, end = dialog._buffer.get_bounds()
    return dialog._buffer.get_text(start, end, False)
$1
"
}

test_the_form_is_built_from_what_pitcrew_reads_not_from_a_second_parser() {
  gui_available || return 0
  # lib/18-yaml.sh is the one definition of the subset pitcrew accepts. A YAML
  # parser in the GUI would sooner or later accept a file the tool rejects, or
  # silently misread one and save it back — so every value on the form arrives
  # over `pitcrew config --json`.
  SAMPLE_YAML=$(temp_file .yaml)
  cp "$PITCREW_DIR/test/fixture-yaml/pitcrew.yaml" "$SAMPLE_YAML"
  local out; out=$(_config_form "
paths = sorted('.'.join(p) for p in dialog._rows)
print(len(paths))
print('apps.both.be.cmd' in paths, 'apps.both.be.root' in paths, 'apps.both.fe.port' in paths)
")
  assert_ne "$(printf '%s' "$out" | sed -n 1p)" "0" "the form has fields"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True True True" \
    "a component's command, its own checkout, and its port"
  rm -f "$SAMPLE_YAML"
}

test_editing_a_field_changes_one_line_and_leaves_the_comments() {
  gui_available || return 0
  SAMPLE_YAML=$(temp_file .yaml)
  printf '%s\n' '# a note somebody left' 'apps:' '  a:' '    be:' \
    '      cmd: "true"    # and another' '      port: 1' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
before = text()
dialog._apply(('apps','a','be','port'), '2')
after = text()
print(sum(1 for x, y in zip(before.splitlines(), after.splitlines()) if x != y))
print(after.count('#'))
print([l for l in after.splitlines() if 'port' in l][0].strip())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "1" "exactly one line differs"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "2" "and both comments are still there"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "port: 2" "with the new value"
  rm -f "$SAMPLE_YAML"
}

test_the_form_never_writes_a_config_the_tool_cannot_load() {
  gui_available || return 0
  # Saving a config pitcrew cannot parse breaks every command for that project,
  # including the one that would tell you why.
  SAMPLE_YAML=$(temp_file .yaml)
  printf '%s\n' 'apps:' '  a:' '    be:' '      cmd: "true"' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
dialog._buffer.set_text('apps:\n  a:\n   \tbroken indent\n')
dialog._save()
print(SAMPLE.read_text().strip().replace(chr(10), ' | '))
")
  assert_match "$out" 'cmd: "true"' "the file on disk is untouched"
  assert_not_match "$out" 'broken indent' "the unloadable text was refused"
  rm -f "$SAMPLE_YAML"
}

test_switching_a_component_off_writes_the_exclusion_and_switching_it_on_removes_it() {
  gui_available || return 0
  # `enabled: true` is the default, so turning it back on should leave the file
  # as it was rather than adding a line that says nothing.
  SAMPLE_YAML=$(temp_file .yaml)
  printf '%s\n' 'apps:' '  a:' '    be:' '      cmd: "true"' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
class Fake:
    def __init__(self, on): self._on = on
    def get_active(self): return self._on
dialog._enabled_changed(Fake(False), None, ('apps','a','be'))
print('enabled: false' in text())
dialog._enabled_changed(Fake(True), None, ('apps','a','be'))
print('enabled' in text())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "True"  "off writes the exclusion"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "False" "on takes the line away again"
  rm -f "$SAMPLE_YAML"
}

test_a_new_role_can_be_added_to_a_group_from_the_form() {
  gui_available || return 0
  SAMPLE_YAML=$(temp_file .yaml)
  printf '%s\n' 'apps:' '  a:' '    be:' '      cmd: "true"' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
dialog._do_add_component('a', 'worker')
print('worker:' in text())
dialog._do_add_component('a', 'my-worker')
print('my-worker' in text())
print(dialog._output.__class__.__name__ != '')
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "True"  "a role the config never had"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "False" \
    "and a name that cannot be half of a component id is refused, not written"
  rm -f "$SAMPLE_YAML"
}

test_a_command_with_an_ampersand_in_it_is_still_shown() {
  gui_available || return 0
  # Adw renders a row's subtitle as Pango MARKUP by default, and every real
  # start command has `&&` in it. `&&` is not an entity, so the markup failed
  # to parse and the line rendered as nothing — the component row that says
  # what a component runs was blank for exactly the commands worth reading.
  SAMPLE_YAML=$(temp_file .yaml)
  printf '%s\n' 'apps:' '  a:' '    be:' '      cmd: "true"' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
cmd = '{ [ -d node_modules ] || npm install; } && npm run dev'
row = dialog._component_row('frontend', {'role': 'fe', 'cmd': cmd})
print(row.get_subtitle() == cmd, row.get_use_markup())
")
  assert_eq "$(printf '%s' "$out" | tail -n 1)" "True False" \
    "the command is the subtitle, and it is text rather than markup"
  rm -f "$SAMPLE_YAML"
}

test_adding_an_app_offers_what_pitcrew_found_in_the_checkout() {
  gui_available || return 0
  # Asking for a name and writing `cmd: "true"` under it left the actual work —
  # the gradle task, the port, the health path — to be typed by hand for a
  # project pitcrew can read perfectly well. The list comes from
  # `pitcrew detect --json`, which is the same guess `init` makes.
  SAMPLE_YAML=$(temp_file .yaml)
  printf '%s\n' 'apps:' '  frontend:' '    fe:' '      cmd: "npm run dev"' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
found = {'schema': 1, 'root': '/checkout', 'deps': [], 'apps': [
    {'name': 'frontend', 'components': [{'role': 'fe', 'cmd': 'npm run dev',
                                         'dir': 'frontend', 'port': 3000, 'health': ''}]},
    {'name': 'backend', 'components': [{'role': 'be', 'cmd': './gradlew :backend:bootRun',
                                        'dir': '', 'port': 8444,
                                        'health': '/actuator/health'}]},
]}
dialog._config = {'root': '/checkout', 'apps': [{'name': 'frontend'}]}
# what the picker would have been given
import pitcrewgui.dialogs as d
offered = []
dialog._offer_detected = lambda apps: offered.extend(a['name'] for a in apps)
dialog._detected(found, '')
print(offered)
dialog._add_detected([found['apps'][1]])
print(text())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "['backend']" \
    "only what the config does not already have is offered"
  assert_match "$out" 'backend:'                         "the app is written"
  assert_match "$out" 'cmd: \./gradlew :backend:bootRun' "with the command pitcrew found"
  assert_match "$out" 'port: 8444'                       "the port it found"
  assert_match "$out" 'health: /actuator/health'         "and the health path"
  assert_not_match "$out" 'cmd: "true"' "and no placeholder anybody has to replace"
  rm -f "$SAMPLE_YAML"
}

test_switching_project_in_the_app_is_remembered_next_time() {
  gui_display || return 0
  # The app opens on whatever `~/.config/pitcrew/current` names — the same
  # selection `pitcrew` with no -p uses, and the one the Projects page badges
  # as "current". Switching only ever changed it in this window, so closing it
  # threw the choice away and the next launch reopened whatever the terminal
  # had last run `pitcrew use` on.
  #
  # Asserting on the ARGV rather than on the file: the registry belongs to the
  # CLI, and a GUI that wrote `current` itself would be a second writer to
  # disagree with the first.
  local home; home=$(mktemp -d); mkdir -p "$home/projects"
  printf 'root: /tmp\n' > "$home/projects/demo.yaml"
  printf 'root: /tmp\n' > "$home/projects/other.yaml"
  local log; log=$(mktemp)
  local cli; cli=$(temp_file .sh)
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' \"\$*\" >> $log" > "$cli"
  chmod +x "$cli"
  local out; out=$(PITCREW_HOME="$home" _settings_drive "
from gi.repository import Adw, GLib
Adw.init()
w = pgui.Window('$cli', 'demo', Settings(pathlib.Path('$(mktemp -d)/gui')))
w._switch_to('other')
loop = GLib.MainLoop()
GLib.timeout_add(900, lambda: (loop.quit(), False)[1])
loop.run()
print(w._project)
")
  assert_eq "$out" "other" "the window follows the switch"
  assert_match "$(cat "$log")" 'use other' \
    "and the choice is saved through the CLI that owns the registry"
  rm -rf "$home"; rm -f "$log"
}

test_a_project_pitcrew_cannot_read_still_gets_an_empty_app() {
  gui_available || return 0
  # Plenty of projects are started by a command no detector could guess. That
  # is not a failure — it just means the empty app is the only thing left to
  # offer, and it has to still be offered.
  SAMPLE_YAML=$(temp_file .yaml)
  printf '%s\n' 'apps:' '  a:' '    be:' '      cmd: "true"' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
asked = []
dialog._ask_app_name = lambda: asked.append('asked')
dialog._config = {'root': '/checkout', 'apps': [{'name': 'a'}]}
dialog._detected(None, 'detect: no such directory')
dialog._detected({'apps': []}, '')
print(asked)
start, end = dialog._output._buffer.get_bounds()
print('no such directory' in dialog._output._buffer.get_text(start, end, False)
      or 'nothing here' in dialog._output._buffer.get_text(start, end, False))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "['asked', 'asked']" \
    "both a failed look and an empty one fall back to naming it yourself"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True" "and what happened is said"
  rm -f "$SAMPLE_YAML"
}

test_a_bash_config_is_offered_a_way_out_of_being_bash() {
  gui_available || return 0
  # The .sh configs that most need a form are exactly the ones a form cannot
  # touch: six apps built from a `for` loop over a `declare -A` of ports. The
  # offer to convert belongs where the problem is, so it sits in that dialog's
  # header and nowhere else.
  SAMPLE_YAML=$(temp_file .sh)
  printf '%s\n' 'PITCREW_APPS=(a)' 'PITCREW_BE_CMD[a]=true' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
def labels(widget, found):
    while widget is not None:
        text = widget.get_label() if hasattr(widget, 'get_label') else None
        if text:
            found.add(text)
        child = widget.get_first_child() if hasattr(widget, 'get_first_child') else None
        if child is not None:
            labels(child, found)
        widget = widget.get_next_sibling()
found = set()
labels(dialog._header(True).get_first_child(), found)
print(sorted(found))
")
  assert_match "$out" 'Convert to YAML' "a bash config is offered the conversion"

  # And a YAML one is not — there is nothing to convert.
  local yaml_out
  SAMPLE_YAML=$(temp_file .yaml)
  printf '%s\n' 'apps:' '  a:' '    be:' '      cmd: "true"' > "$SAMPLE_YAML"
  yaml_out=$(_config_form "
def labels(widget, found):
    while widget is not None:
        text = widget.get_label() if hasattr(widget, 'get_label') else None
        if text:
            found.add(text)
        child = widget.get_first_child() if hasattr(widget, 'get_first_child') else None
        if child is not None:
            labels(child, found)
        widget = widget.get_next_sibling()
found = set()
labels(dialog._header(True).get_first_child(), found)
print(sorted(found))
")
  assert_not_match "$yaml_out" 'Convert to YAML' "a yaml config is not"
  rm -f "$SAMPLE_YAML"
}

test_the_config_is_edited_as_the_language_it_is_written_in() {
  gui_available || return 0
  # A wall of one-colour YAML is a file you read a line at a time. Where
  # GtkSourceView is installed the editor highlights it — as YAML for a
  # pitcrew.yaml and as shell for a pitcrew.config.sh, which are two different
  # languages that used to look identical. Where it is NOT installed the plain
  # view is still there: the typelib is one more package on seven package
  # managers, and an install without it has to keep opening configs.
  SAMPLE_YAML=$(temp_file .yaml)
  printf '%s\n' 'apps:' '  a:' '    be:' '      cmd: "true"' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
from pitcrewgui import widgets
buffer = dialog._buffer
if widgets.GtkSource is None:
    print('plain', 'plain')
else:
    lang = buffer.get_language()
    print(lang.get_id() if lang is not None else 'none', buffer.get_highlight_syntax())
print('apps:' in text())
")
  assert_match "$(printf '%s' "$out" | sed -n 1p)" '(yaml True|plain plain)' \
    "YAML is highlighted as YAML where that is possible"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True" "and the file is still the file"
  rm -f "$SAMPLE_YAML"

  SAMPLE_YAML=$(temp_file .sh)
  printf '%s\n' 'PITCREW_APPS=(a)' 'PITCREW_BE_CMD[a]=true' > "$SAMPLE_YAML"
  local sh_out; sh_out=$(_config_form "
from pitcrewgui import widgets
lang = None if widgets.GtkSource is None else dialog._buffer.get_language()
print('plain' if widgets.GtkSource is None else (lang.get_id() if lang else 'none'))
")
  assert_match "$sh_out" '(sh|plain)' "and a bash config as shell"
}

test_the_editor_never_indents_a_config_with_a_tab() {
  gui_available || return 0
  # pitcrew's YAML loader REJECTS a tab used for indentation, so an editor that
  # inserted one on Tab would write a file the tool then refuses — from a
  # keystroke nobody thinks about.
  SAMPLE_YAML=$(temp_file .yaml)
  printf '%s\n' 'apps:' '  a:' '    be:' '      cmd: "true"' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
from pitcrewgui import widgets
body = dialog.get_child().get_content()
view = body.get_start_child().get_child_by_name('yaml').get_child()
print(view.get_insert_spaces_instead_of_tabs() if widgets.GtkSource else True)
")
  assert_eq "$(printf '%s' "$out" | tail -n 1)" "True" "Tab inserts spaces"
  rm -f "$SAMPLE_YAML"
}

test_the_output_panel_shares_the_height_and_can_be_dragged() {
  gui_available || return 0
  # `doctor` reports every port this machine argues with itself about, and
  # `migrate` reports what it could not carry over. In a dialog that cannot be
  # resized, a fixed 120px strip meant reading those six lines at a time. The
  # editor and the output split the height with a handle between them — and
  # neither half can be dragged onto nothing, because a panel you can lose is
  # a panel somebody will lose.
  SAMPLE_YAML=$(temp_file .yaml)
  printf '%s\n' 'apps:' '  a:' '    be:' '      cmd: "true"' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
body = dialog.get_child().get_content()
print(body.__class__.__name__)
print(body.get_start_child() is dialog._stack, body.get_end_child() is dialog._output)
print(body.get_shrink_start_child(), body.get_shrink_end_child())
print(body.get_resize_start_child())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "Paned" "there is a handle between them"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True True" \
    "the editor above it, the output below"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "False False" \
    "and neither can be collapsed away"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "True" \
    "the room a bigger window brings goes to the editor"
  rm -f "$SAMPLE_YAML"
}

test_a_conversion_says_where_the_file_went_and_waits_to_be_read() {
  gui_available || return 0
  # It used to close itself 1.2 seconds after converting, which threw away both
  # the warnings about what YAML cannot carry and the one line saying where the
  # file went — so the app looked like it had done nothing at all. The same
  # button becomes the way on, pressed once that has been read.
  SAMPLE_YAML=$(temp_file .sh)
  printf '%s\n' 'PITCREW_APPS=(a)' 'PITCREW_BE_CMD[a]=true' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
import pathlib
converted = pathlib.Path('/checkout/pitcrew.yaml')
# Where it went is asked of pitcrew, not scraped out of that output.
dialogs.project_config_path = lambda name: converted
dialog._converted(True, 'wrote /checkout/pitcrew.yaml')
start, end = dialog._output._buffer.get_bounds()
shown = dialog._output._buffer.get_text(start, end, False)
print(str(converted) in shown)
print(dialog._convert.get_label())
dialog._on_converted = lambda: print('reopened on it')
dialog._convert_clicked()
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "True" "the path is the first thing said"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "Open the YAML" \
    "and the button stops offering a conversion that already happened"
  assert_match "$out" 'reopened on it' "pressing it lands on the new file"
  rm -f "$SAMPLE_YAML"
}

test_a_failed_conversion_leaves_the_button_where_it_was() {
  gui_available || return 0
  SAMPLE_YAML=$(temp_file .sh)
  printf '%s\n' 'PITCREW_APPS=(a)' 'PITCREW_BE_CMD[a]=true' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
dialog._converted(False, 'the generated YAML does not mean the same thing')
start, end = dialog._output._buffer.get_bounds()
print(dialog._output._buffer.get_text(start, end, False))
print(dialog._convert.get_label())
")
  assert_match "$out" 'does not mean the same thing' "the refusal is shown verbatim"
  assert_eq "$(printf '%s' "$out" | tail -n 1)" "Convert to YAML" \
    "and nothing pretends a file was written"
  rm -f "$SAMPLE_YAML"
}

test_a_bash_config_is_offered_as_text_and_not_as_a_form() {
  gui_available || return 0
  # A pitcrew.config.sh is a sourced shell script that may branch, loop or
  # source something else. There is no form for that, and one that could not
  # round-trip it would quietly drop what it did not understand.
  SAMPLE_YAML=$(temp_file .sh)
  printf '%s\n' 'PITCREW_APPS=(a)' 'PITCREW_BE_CMD[a]=true' > "$SAMPLE_YAML"
  local out; out=$(_config_form "
print(dialog._is_yaml)
print(dialog._stack.get_child_by_name('form') is None)
print(dialog._stack.get_child_by_name('yaml') is not None)
")
  assert_eq "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ *$//')" "False True True" \
    "no form tab, and the text is still there"
  rm -f "$SAMPLE_YAML"
}

# ── the dependency installer ────────────────────────────────────────────────
#
# Only the Fedora path can actually be run here, so these check the tables and,
# more importantly, that nothing privileged happens without being asked.

_deps() { # source the tables without running anything
  PITCREW_DEPS_LIB=1 bash -c "source '$GUI_DIR/install-deps.sh'; $1"
}

test_every_supported_package_manager_has_a_real_plan() {
  [ -r "$GUI_DIR/install-deps.sh" ] || return 0
  local m pkgs cmd
  for m in dnf apt pacman zypper apk brew msys2; do
    pkgs=$(_deps "packages_for $m")
    cmd=$(_deps "install_command_for $m '$pkgs'")
    assert_ne "$pkgs" "" "$m: has packages"
    assert_ne "$cmd" "" "$m: has an install command"
    # openSUSE calls it typelib-1_0-Adw-1, hence the case-insensitive match.
    assert_match "$pkgs" '[Aa]dw' "$m: installs libadwaita"
  done
  assert_empty "$(_deps "packages_for freedos")" "an unknown manager promises nothing"
  assert_empty "$(_deps "install_command_for freedos x")" "and offers no command"
}

test_homebrew_is_never_run_as_root() {
  [ -r "$GUI_DIR/install-deps.sh" ] || return 0
  # Homebrew refuses to run under sudo and says so rudely; a plan that used it
  # would fail on every Mac.
  local cmd; cmd=$(_deps "install_command_for brew 'gtk4'")
  assert_not_match "$cmd" 'sudo' "brew install runs unprivileged"
  assert_not_match "$(_deps "install_command_for msys2 'x'")" 'sudo' "MSYS2 has no sudo either"
  assert_match "$(_deps "install_command_for dnf 'x'")" 'sudo' "but a system manager does need it"
}

test_macos_is_the_only_platform_told_to_install_bash() {
  [ -r "$GUI_DIR/install-deps.sh" ] || return 0
  # Everywhere else already ships bash 5; macOS is stuck on 3.2, which pitcrew
  # refuses to run under.
  assert_eq "$(_deps "bash5_package_for brew")" "bash" "macOS gets bash"
  local m
  for m in dnf apt pacman zypper apk msys2; do
    assert_empty "$(_deps "bash5_package_for $m")" "$m does not need it"
  done
}

test_nothing_privileged_runs_until_it_is_asked_to() {
  [ -r "$GUI_DIR/install-deps.sh" ] || return 0
  # The whole safety property: running the installer must PRINT the command, not
  # execute it. Both probes are stubbed to "missing" so the plan is non-empty.
  local out
  out=$(PITCREW_DEPS_LIB=1 PITCREW_PKG=dnf bash -c "
    source '$GUI_DIR/install-deps.sh'
    have_bindings() { return 1; }
    have_bash5() { return 0; }
    main" 2>&1)
  assert_match "$out" 'sudo dnf install' "it shows exactly what it would run"
  assert_not_match "$out" 'running…' "and does not run it"
  assert_match "$out" 'Re-run with --yes' "saying how to consent"
}

test_an_unknown_platform_says_so_instead_of_all_clear() {
  [ -r "$GUI_DIR/install-deps.sh" ] || return 0
  # The empty package list for an unrecognised manager used to look exactly like
  # "nothing missing", sending someone away believing they were ready to go.
  local out
  out=$(PITCREW_DEPS_LIB=1 PITCREW_PKG=freedos bash -c "
    source '$GUI_DIR/install-deps.sh'
    have_bindings() { return 1; }
    have_bash5() { return 1; }
    main --dry-run" 2>&1)
  assert_not_match "$out" 'Nothing to install' "it does not claim all-clear"
  assert_match "$out" 'MISSING' "it says what is missing"
}

test_dry_run_succeeds_even_when_things_are_missing() {
  [ -r "$GUI_DIR/install-deps.sh" ] || return 0
  # So it is usable as a report in a script without failing the script.
  local rc
  rc=$(PITCREW_DEPS_LIB=1 PITCREW_PKG=unknown bash -c "
    source '$GUI_DIR/install-deps.sh'
    have_bindings() { return 1; }
    have_bash5() { return 1; }
    main --dry-run >/dev/null 2>&1; echo \$?")
  assert_eq "$rc" "0" "--dry-run reports without failing"
}

# ── the log viewer ──────────────────────────────────────────────────────────

test_the_log_view_tails_and_marks_the_error_lines() {
  gui_display || return 0
  local dir; dir=$(mktemp -d)
  printf 'starting up\nready on :8080\n' > "$dir/be-demo.log"
  local out; out=$(_drive "
import pathlib
from pitcrewgui.logview import LogView
log = pathlib.Path('$dir/be-demo.log')
errs = []
view = LogView(errs.append)
view.update_sources('$dir', [{'name': 'be-demo', 'role': 'be', 'app': 'demo'}],
                    'ERROR|FATAL|Exception')
loop = GLib.MainLoop()

def more():
    with log.open('a') as fh:
        fh.write('handling request\nERROR could not reach mongo\nrecovered\n')
    return False

def check():
    buf = view._buffer
    text = buf.get_text(*buf.get_bounds(), False)
    tagged = []
    it = buf.get_start_iter()
    while True:
        end = it.copy()
        if not end.forward_to_line_end():
            break
        if any(t.props.name == 'fg:error' for t in it.get_tags()):
            tagged.append(buf.get_text(it, end, False))
        if not it.forward_line():
            break
    print('ready on :8080' in text, 'recovered' in text,
          tagged == ['ERROR could not reach mongo'], not errs)
    view.stop(); loop.quit(); return False

GLib.timeout_add(1200, more)
GLib.timeout_add(3200, check)
GLib.timeout_add_seconds(20, lambda: (loop.quit(), False)[1])
loop.run()
")
  rm -rf "$dir"
  assert_eq "$out" "True True True True" "tails, follows, marks only the error line, reports nothing"
}

test_the_log_view_says_so_when_there_is_no_log_yet() {
  gui_display || return 0
  # A component that has never started has no file. An empty pane would read as
  # a broken viewer rather than as "nothing has run".
  local dir; dir=$(mktemp -d)
  local out; out=$(_drive "
from pitcrewgui.logview import LogView
view = LogView(lambda e: None)
view.update_sources('$dir', [{'name': 'be-never', 'role': 'be', 'app': 'never'}], 'ERROR')
print(view._status.get_text())
")
  rm -rf "$dir"
  assert_match "$out" 'has not been started' "it explains the empty pane"
}

test_the_log_picker_separates_backends_from_frontends() {
  gui_display || return 0
  # Backends and frontends fail differently and you are usually after one kind.
  # Backends lead: they start first, and are what a frontend is failing to reach.
  local out; out=$(_drive "
from pitcrewgui.logview import LogView
comps = [
    {'name': 'fe-sales', 'role': 'fe', 'app': 'sales'},
    {'name': 'be-orders', 'role': 'be', 'app': 'orders'},
    {'name': 'be-sales', 'role': 'be', 'app': 'sales'},
]
view = LogView(lambda e: None)
view.update_sources('/nonexistent', comps, 'ERROR')
print(' '.join(view._names))
view._roles.set_active_name('fe'); print(' '.join(view._names))
view._roles.set_active_name('be'); print(' '.join(view._names))
view._roles.set_active_name('all')
print(view._picker.get_model().get_string(0))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "be-orders be-sales fe-sales" "backends first, then by app"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "fe-sales" "the frontend filter narrows it"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "be-orders be-sales" "and so does the backend one"
  assert_match "$(printf '%s' "$out" | sed -n 4p)" 'be.*orders' "each entry names its role"
}

# ── notifications, filtering, shortcuts ─────────────────────────────────────

test_a_crash_notifies_once_and_only_for_a_transition() {
  gui_available || return 0
  # A dashboard you have to be looking at tells you nothing. But a component
  # that was ALREADY crashed when you started watching is not news, and one
  # that flaps must not stack twelve notifications.
  local out; out=$(_drive "
from pitcrewgui.notify import CrashWatcher
fired = []
w = CrashWatcher(None, lambda n: None)
w._notify = lambda c: fired.append(c['name'])
w.check([{'name': 'be-x', 'state': 'up'}])
w.check([{'name': 'be-x', 'state': 'crashed', 'exit': 1}])
w.check([{'name': 'be-x', 'state': 'crashed', 'exit': 1}])
print(fired)
w.reset()
w.check([{'name': 'be-y', 'state': 'crashed'}])
print(fired)
w2 = CrashWatcher(None, lambda n: None); w2.enabled = False
w2._notify = lambda c: fired.append('SHOULD-NOT-FIRE')
w2.check([{'name': 'be-z', 'state': 'up'}])
w2.check([{'name': 'be-z', 'state': 'crashed'}])
print(fired)
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "['be-x']" "up → crashed fires exactly once"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "['be-x']" "a crash already in progress is not news"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "['be-x']" "and the preference turns it off"
}

test_the_log_filter_hides_lines_as_they_arrive() {
  gui_display || return 0
  # Filtering a LIVE tail cannot re-read the file — it may already have been
  # truncated by a restart — so every line is kept and the view is rebuilt.
  local out; out=$(_drive "
from pitcrewgui.logview import LogView
v = LogView(lambda e: None)
v.update_sources('/nonexistent', [{'name': 'be-a', 'role': 'be', 'app': 'a'}], 'ERROR')
v._raw = ['alpha one', 'beta two', 'ERROR three']
v._filter.set_text('beta'); v._refilter()
print(repr(v._buffer.get_text(*v._buffer.get_bounds(), False).strip()))
v._filter.set_text(''); v._errors_only.set_active(True); v._refilter()
print(repr(v._buffer.get_text(*v._buffer.get_bounds(), False).strip()))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "'beta two'" "text filter shows only matches"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "'ERROR three'" "errors-only shows only error lines"
}

test_profiles_arrive_as_state_not_as_a_directory_listing() {
  gui_available || return 0
  # The GUI used to read pitcrew's profile DIRECTORY and show the saved words
  # back. That is the one thing it cannot interpret: a profile holds target
  # words, and only pitcrew can say that "sales" now covers a worker too, or
  # that "legacy" names nothing at all any more. Every number on a profile row
  # comes from the stream.
  local strays
  strays=$(grep -rln 'profileDir' "$GUI_DIR"/pitcrewgui/*.py || true)
  assert_empty "$strays" "the GUI still reading pitcrew's profile directory"

  gui_display || return 0
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
w._render_profiles([
    {'name': 'core', 'targets': ['sales'], 'components': ['be-sales', 'fe-sales'],
     'missing': [], 'total': 2, 'up': 1, 'starting': 0, 'rss': 1048576, 'limit': 0},
    {'name': 'gone', 'targets': ['legacy'], 'components': [],
     'missing': ['legacy'], 'total': 0, 'up': 0, 'starting': 0, 'rss': 0, 'limit': 0},
])
print(len(w._profile_rows))
for row in w._profile_rows:
    print(row.get_title() + ' | ' + (row.get_subtitle() or ''))
print('visible', w._profiles_group.get_visible())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "2" "a row per profile"
  assert_match "$out" '@core \| 1/2 up'   "how much of it is already running"
  assert_match "$out" 'be-sales, fe-sales' "and what it actually covers, not the word it was saved as"
  assert_match "$out" 'legacy missing'     "a profile that can no longer start says so"
  assert_match "$out" 'visible True'       "and the group is on the Overview"
}

test_every_icon_the_gui_asks_for_actually_exists() {
  gui_display || return 0
  # A missing icon name is not an error — GTK draws NOTHING. The Resources tab
  # and the "open URL" button both shipped invisible because the names looked
  # plausible (`utilities-system-monitor-symbolic`, `external-link-symbolic`)
  # and neither is in the theme.
  local names; names=$(grep -rhoE '"[a-z0-9.-]+-symbolic"' "$GUI_DIR"/pitcrewgui/*.py \
    | tr -d '"' | sort -u | tr '\n' ' ')
  local out; out=$(_drive "
from gi.repository import Gtk, Gdk
theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default())
missing = [n for n in '''$names'''.split() if not theme.has_icon(n)]
print(' '.join(missing))
")
  assert_empty "$out" "icon names the theme does not have"
}

test_uptime_is_compact_at_every_scale() {
  gui_available || return 0
  local out; out=$(_drive "
from pitcrewgui.widgets import human_age
print([human_age(n) for n in (None, 0, -5, 45, 90, 3599, 8040, 90000)])
")
  assert_eq "$out" "['', '', '', '45s', '1m', '59m', '2h14m', '1d01h']" \
    "seconds, minutes, hours, days — and nothing at all for unknown"
}

test_the_component_filter_matches_name_or_app() {
  gui_available || return 0
  # Typing "sales" should find be-sales and fe-sales; typing nonsense should
  # say so rather than showing an empty list that reads as a broken view.
  local out; out=$(_drive "
comps = [{'name': 'be-sales', 'app': 'sales', 'role': 'be', 'state': 'up'},
         {'name': 'fe-sales', 'app': 'sales', 'role': 'fe', 'state': 'up'},
         {'name': 'be-orders', 'app': 'orders', 'role': 'be', 'state': 'down'}]
def matching(needle):
    n = needle.lower()
    return [c['name'] for c in comps
            if n in c['name'].lower() or n in (c.get('app') or '').lower()]
print(' '.join(matching('sales')))
print(' '.join(matching('orders')))
print(' '.join(matching('be-')))
print(matching('zzz'))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "be-sales fe-sales" "an app name finds both roles"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "be-orders" "and one app does not drag in another"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "be-sales be-orders" "a role prefix works too"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "[]" "no match is empty, not everything"
}

test_hovering_a_graph_reads_the_nearest_sample() {
  gui_available || return 0
  # With a few minutes of history the line only occupies the right edge of the
  # plot. Rejecting a hover over the empty left half would mean the readout
  # shows nothing for most of the widget, which is when you most want it.
  local out; out=$(_drive "
from pitcrewgui.model import hover_index
print(hover_index(0, 800, 5, 20),        # left of every sample
      hover_index(850, 800, 5, 20),      # exactly on one
      hover_index(9999, 800, 5, 20),     # right of every sample
      hover_index(500, 0, 5, 0),         # nothing plotted yet
      hover_index(500, 0, 0, 4))         # a one-sample series has no step
")
  assert_eq "$out" "0 10 19 0 0" "clamped into the series at both ends"
}

test_a_group_folds_only_when_nothing_wants_attention() {
  gui_available || return 0
  # Folding away the one group that just crashed would be exactly backwards.
  local out; out=$(_drive "
from pitcrewgui.model import group_is_idle
print(group_is_idle([{'state': 'down'}, {'state': 'down'}]),
      group_is_idle([{'state': 'down'}, {'state': 'up'}]),
      group_is_idle([{'state': 'down'}, {'state': 'crashed'}]),
      group_is_idle([{'state': 'down'}, {'state': 'starting'}]),
      group_is_idle([{'state': 'down'}, {'state': 'external'}]),
      group_is_idle([]))
")
  assert_eq "$out" "True False False False False True" \
    "all-down folds; up, crashed, starting and external all keep it open"
}

test_the_share_ring_ranks_and_totals_what_is_running() {
  gui_available || return 0
  # The line graphs are bad at "which of these twelve is the problem" — a 3 GiB
  # frontend and a 300 MiB worker are both just lines. The ring answers it, so
  # the order has to be biggest-first and the total has to be the sum of what
  # is actually drawn.
  local out; out=$(_drive "
from pitcrewgui.model import share_slices
rows, total = share_slices([('a', 100, 0), ('b', 300, 0), ('c', 0, 0), ('d', None, 0)])
print([(r.name, r.value) for r in rows])
print(total)
print(share_slices([]))
print(round(rows[0].value / total * 100))
print(share_slices([('a', 100, 512)])[0][0].limit)
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "[('b', 300.0), ('a', 100.0)]" \
    "biggest first, and nothing for a component using nothing"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "400.0" "the total is the sum of the slices"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "([], 0.0)" "an idle stack draws no ring"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "75" "shares are of the drawn total"
  assert_eq "$(printf '%s' "$out" | sed -n 5p)" "512.0" "a wedge carries its own RAM cap"
}

test_the_share_ring_folds_wedges_too_thin_to_point_at() {
  gui_available || return 0
  # A wedge under ~1.5% is a sliver: invisible, and — now that the ring is
  # something you hover and click — impossible to hit. Folding the tail is what
  # keeps every wedge on the chart a real target.
  local out; out=$(_drive "
from pitcrewgui.model import share_slices
tail = [(f'tiny{i}', 2, 0) for i in range(6)]
rows, total = share_slices([('big', 1000, 0), ('mid', 400, 0)] + tail)
print([r.name for r in rows])
print(rows[-1].value, len(rows[-1].members))
# one leftover is named, not folded: 'other (1)' says less than the name does
print([r.name for r in share_slices([('big', 1000, 0), ('lonely', 2, 0)])[0]])
# nine real components stay nine wedges
print(len(share_slices([(f'c{i}', 100, 0) for i in range(9)])[0]))
# ten become nine, the last of them the fold
print([r.name for r in share_slices([(f'c{i}', 100, 0) for i in range(10)])[0]][-1])
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "['big', 'mid', 'other']" \
    "the slivers become one wedge"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "12.0 6" "which totals them and says how many"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "['big', 'lonely']" \
    "a single leftover keeps its name"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "9" "nine equal components are nine wedges"
  assert_eq "$(printf '%s' "$out" | sed -n 5p)" "other" "the tenth is what starts a fold"
}

test_every_wedge_on_the_share_ring_can_be_pointed_at() {
  gui_display || return 0
  # The ring grew hover, pinning and keyboard selection, and all three run off
  # ONE hit test against the geometry the last paint left behind. If that
  # mapping is wrong the chart looks perfect and answers the wrong component —
  # the failure mode a screenshot cannot catch.
  local out; out=$(_drive "
import math, cairo
from pitcrewgui.widgets import ShareChart
from pitcrewgui.model import share_slices, SERIES_COLORS
from gi.repository import Gdk

comps = [('be-shop', 3.1e9, 4e9), ('fe-shop', 1.2e9, 0), ('be-admin', 780e6, 800e6),
         ('fe-admin', 410e6, 0), ('be-jobs', 260e6, 0), ('worker', 120e6, 0),
         ('cron', 41e6, 0), ('tiny', 9e6, 0)]
rows, total = share_slices(comps)
colors = {n: SERIES_COLORS[i % len(SERIES_COLORS)] for i, (n, _v, _l) in enumerate(comps)}
opened = []
chart = ShareChart(on_activate=opened.append)
chart.set_slices(rows, total, colors, 16 * 1024 ** 3)
cr = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 620, 210))
chart._draw(None, cr, 620, 210)
g = chart._geom
mid = (g['inner'] + g['outer']) / 2

hits, angle = [], -math.tau / 4
for index, row in enumerate(rows):
    sweep = math.tau * row.value / total
    a = angle + sweep / 2
    hits.append(chart._at(g['cx'] + mid * math.cos(a), g['cy'] + mid * math.sin(a)) == index)
    angle += sweep
print(all(hits), len(hits))
print(chart._at(g['cx'], g['cy']), chart._at(g['cx'], g['cy'] - g['outer'] - 40))
print(all(chart._at(g['legend_x'] + 30, (t + b) / 2) == i
          for i, (t, b) in enumerate(g['rows'])), len(g['rows']))
chart._select('be-shop'); chart._on_key(None, Gdk.KEY_Return, 0, 0)
print(opened)
chart._select('other'); chart._on_key(None, Gdk.KEY_Return, 0, 0)
print(opened)
chart._select('fe-shop')
chart.set_slices(*share_slices([('be-shop', 1e9, 0)]), colors, 16 * 1024 ** 3)
print(chart._selected)
chart.set_slices([], 0.0, {}, 0)
chart._draw(None, cr, 620, 210)
print(chart._geom, chart._at(10, 10))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "True 7" "the pointer lands on the wedge it is over"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "None None" "the hole and the space around it are not wedges"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "True 7" "and so is every row of the key beside it"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "['be-shop']" "a wedge opens the component it names"
  assert_eq "$(printf '%s' "$out" | sed -n 5p)" "['be-shop']" \
    "but 'other' is several at once and opens nothing"
  assert_eq "$(printf '%s' "$out" | sed -n 6p)" "None" \
    "a pinned component that stops lets go of the readout"
  assert_eq "$(printf '%s' "$out" | sed -n 7p)" "None None" "an idle ring has no geometry to hit"
}

# ── zen mode ────────────────────────────────────────────────────────────────
# The desktop zen is the same promise as the terminal's: hide what is fine.
# It is a filter over the existing views, not a sixth view, and the thing that
# makes it safe is that nothing about LEAVING it is hidden.

test_zen_hides_what_is_fine_and_keeps_what_is_not() {
  gui_display || return 0
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
def comp(name, state):
    return {'name': name, 'app': name[3:], 'role': 'be', 'state': state, 'rss': 10,
            'cpu': 0, 'errors': 0, 'since': 1}
state = {
  'at': 1000, 'machine': {'memTotal': 100, 'memUsed': 10, 'cpuPercent': 1},
  'components': [comp('be-api', 'up'), comp('be-etl', 'crashed')],
  'deps': [{'name': 'postgres', 'state': 'up'}, {'name': 'redis', 'state': 'down'}],
  'health': {'verdict': 'crit', 'headline': 'be-etl crashed', 'deep': False,
             'counts': {'crit': 1}, 'findings': [], 'recoverable': {}},
  'summary': {'up': 1, 'crashed': 1}}
w._on_state(state)
print(len(w._rows), w._meters_group.get_visible(), w._consumers_group.get_visible())
w._toggle_zen()
print(sorted(w._rows), w._zen_pill.get_visible())
print(w._meters_group.get_visible(), w._consumers_group.get_visible())
print([n for n, (row, _d, _b) in w._dep_rows.items() if row.get_visible()])
w._toggle_zen()
print(len(w._rows), w._meters_group.get_visible(),
      [n for n, (row, _d, _b) in w._dep_rows.items() if row.get_visible()])
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "2 True True" "everything is shown to begin with"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "['be-etl'] True" "zen keeps only the crashed one, and says it is on"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "False False" "the meters and the ranking are not what you came for"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "['redis']" "a running postgres is not news; a stopped redis is"
  assert_match "$(printf '%s' "$out" | sed -n 5p)" "^2 True" "and leaving zen puts all of it back"
  assert_match "$(printf '%s' "$out" | sed -n 5p)" "postgres" "dependencies included"
}

test_zen_with_nothing_wrong_says_so_rather_than_going_blank() {
  gui_display || return 0
  # An empty list is indistinguishable from a broken app. In zen it is the
  # answer, so it has to be written down.
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
w._on_state({
  'at': 1000, 'machine': {'memTotal': 100, 'memUsed': 10, 'cpuPercent': 1},
  'components': [{'name': 'be-api', 'app': 'api', 'role': 'be', 'state': 'up',
                  'rss': 10, 'cpu': 0, 'errors': 0, 'since': 1}],
  'deps': [], 'summary': {'up': 1},
  'health': {'verdict': 'ok', 'headline': 'all up', 'deep': False,
             'counts': {}, 'findings': [], 'recoverable': {}}})
w._toggle_zen()
print(w._empty_group.get_visible())
print(w._empty_label.get_text())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "True" "the empty state is shown"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "Nothing needs you." "and it is an answer, not an error"
}

test_zen_never_folds_away_the_list_it_just_built() {
  gui_display || return 0
  # The trap this guards: auto-collapse asks "is anything in this group up?"
  # and answers no for a list of stopped services — which is exactly the list
  # zen builds. Zen also drops the headings, so nothing was left to expand it
  # with, and the Components page went blank with "2/12 up" in the header.
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
def comp(name, app, state):
    return {'name': name, 'app': app, 'role': name[:2], 'state': state, 'rss': 10,
            'cpu': 0, 'errors': 0, 'since': 1}
comps = [comp('be-a', 'a', 'up'), comp('fe-a', 'a', 'up')]
for i in range(5):
    comps += [comp('be-%d' % i, str(i), 'down'), comp('fe-%d' % i, str(i), 'down')]
w._on_state({
  'at': 1000, 'machine': {'memTotal': 100, 'memUsed': 10, 'cpuPercent': 1},
  'components': comps, 'deps': [{'name': 'pg', 'state': 'up'}],
  'summary': {'up': 2, 'down': 10},
  'health': {'verdict': 'ok', 'headline': 'all good', 'deep': False,
             'counts': {}, 'findings': [], 'recoverable': {}}})
w._toggle_zen()
rows = w._group_rows.get('', [])
print(len(rows), sum(1 for r in rows if r.get_visible()))
print(list(w._group_toggles))
print(w._zen_pill.get_tooltip_text().splitlines()[0])
# and with nothing left to show, the page says so rather than going blank
w._settings['stopped'] = 'hide'
w._on_state(w._last_state)
print(repr(w._empty_label.get_text()), w._empty_group.get_visible())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "10 10" \
    "every row zen kept is a row you can see"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "[]" \
    "and there is no expander in zen, which is what made the fold unescapable"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" \
    "Zen is hiding 2 components that are fine." \
    "the chip stays a dot and a word; the count it used to spell out is a tooltip away"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "'Nothing needs you.' True" \
    "an empty zen list is an answer, not a blank page"
}

test_the_zen_header_is_the_icons_and_the_oval_and_nothing_else() {
  gui_display || return 0
  # Zen strips the header down to navigation plus one green oval. The project
  # name and the up-count both answer questions zen is not asking, and the
  # switcher keeps its icons but drops its titles.
  #
  # Everything asserted twice, on and off: the running pill is repainted on
  # EVERY frame, so a version of this that only checked the way in would pass
  # while the pill reappeared half a second later.
  local out; out=$(_settings_drive "
from gi.repository import Adw, Gtk
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))

def titles():
    got = [l.get_text() for l in w._labels_in(w._switcher) if l.get_text()]
    return len([l for l in w._labels_in(w._switcher) if l.get_text() and l.get_visible()]), len(got)

def tips():
    out, b = [], w._switcher.get_first_child()
    while b is not None:
        out.append(b.get_tooltip_text()); b = b.get_next_sibling()
    return out

def line(tag):
    print(tag, w._project_button.get_visible(), w._running_pill.get_visible(),
          w._zen_pill.get_visible(), titles())

line('off')
w._toggle_zen()
line('on')
print(tips())
# the frame loop must not undo it
w._on_state({'at': 1, 'machine': {'memTotal': 100, 'memUsed': 10, 'cpuPercent': 1},
             'components': [{'name': 'be-a', 'app': 'a', 'role': 'be', 'state': 'up',
                             'rss': 10, 'cpu': 0, 'errors': 0, 'since': 1}],
             'deps': [], 'summary': {'up': 1},
             'health': {'verdict': 'ok', 'headline': 'ok', 'deep': False,
                        'counts': {}, 'findings': [], 'recoverable': {}}})
line('frame')
w._toggle_zen()
line('back')
print(tips())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "off True True False (10, 10)" \
    "normally: the project, the count, no oval, every title readable"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "on False False True (0, 10)" \
    "in zen: icons and the oval, nothing else"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" \
    "['Overview', 'Components', 'Resources', 'Logs', 'Projects']" \
    "the titles become tooltips — zen sheds chrome, never navigation"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "frame False False True (0, 10)" \
    "and a frame arriving does not put the count back"
  assert_eq "$(printf '%s' "$out" | sed -n 5p)" "back True True False (10, 10)" \
    "leaving puts all of it back"
  assert_eq "$(printf '%s' "$out" | sed -n 6p)" "[None, None, None, None, None]" \
    "including dropping the tooltips that stood in for the titles"
}

test_zen_never_hides_the_way_out_of_zen() {
  gui_display || return 0
  # A mode you cannot see you are in, or cannot navigate out of, is a trap.
  # The switcher is navigation, not chrome, and it stays.
  local out; out=$(_settings_drive "
from gi.repository import Adw, Gtk
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
w._toggle_zen()
def switcher(widget):
    if isinstance(widget, Adw.ViewSwitcher) and widget.get_visible():
        return True
    child = widget.get_first_child()
    while child is not None:
        if switcher(child):
            return True
        child = child.get_next_sibling()
    return False
print(w._zen_pill.get_visible(), w._zen_pill.get_sensitive())
print(switcher(w))
w._zen_pill.emit('clicked')
print(w._zen, w._zen_pill.get_visible())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "True True" "the indicator is visible and clickable"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True" "and the view switcher is still there"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "False False" "clicking the indicator leaves"
}

test_zen_is_reachable_by_keyboard_and_by_menu() {
  gui_available || return 0
  local src="$GUI_DIR/pitcrewgui/window.py"
  assert_match "$(grep -c 'win.zen' "$src")" '^[2-9]' "the action is bound and listed"
  assert_ok grep -q 'set_accels_for_action("win.zen", \["<Primary>z"\])' "$src"
  assert_ok grep -q 'menu.append("Zen mode", "win.zen")' "$src"
  assert_ok grep -q 'Ctrl+Z' "$src"
}

test_a_module_that_does_not_import_says_why() {
  gui_available || return 0
  # Every assertion in this file runs python with stderr closed, so ANY import
  # error anywhere in the package arrives as forty tests reporting
  # "expected [x] got []" and nothing about the cause. This one keeps stderr.
  #
  # Not hypothetical: style.py holds its sheet as a BYTES literal, so one
  # em dash in a CSS comment is a SyntaxError that takes the whole app down at
  # launch -- and that is exactly how it was found.
  local out
  out=$("$PY_WITH_GI" -c "
import importlib, sys
sys.path.insert(0, '$GUI_DIR_PY')
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Adw', '1')
for name in ('ansi', 'platform', 'model', 'registry', 'settings', 'style', 'runner',
             'widgets', 'dialogs', 'logview', 'notify', 'yamledit', 'bootstrap',
             'window', 'app'):
    importlib.import_module('pitcrewgui.' + name)
print('ok')
" 2>&1)
  assert_eq "${out##*$'\n'}" "ok" "every module in the package imports"
}

test_a_group_heading_describes_the_group_not_the_filter() {
  gui_display || return 0
  # A heading that says "0/1 up" over a group of two, because a filter hid the
  # healthy one, is a wrong number stated confidently. Worse, "Stop all" under
  # that heading would stop one of the two -- and you would believe the port
  # was free. Driven through the SEARCH box, which is where headings survive;
  # zen has no headings at all (see the flat-list test below).
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
def comp(name, state, rss):
    return {'name': name, 'app': 'orders', 'role': name[:2], 'state': state,
            'rss': rss, 'cpu': 0, 'errors': 0, 'since': 1}
w._on_state({
  'at': 1000, 'machine': {'memTotal': 100, 'memUsed': 10, 'cpuPercent': 1},
  'components': [comp('be-orders', 'crashed', 0), comp('fe-orders', 'up', 100)],
  'deps': [], 'summary': {'up': 1, 'crashed': 1},
  'health': {'verdict': 'crit', 'headline': 'be-orders crashed', 'deep': False,
             'counts': {'crit': 1}, 'findings': [], 'recoverable': {}}})
heading = next(iter(w._group_widgets))
print(w._group_widgets[heading].get_description())
w._comp_filter.set_text('be-')
# GtkSearchEntry debounces search-changed by ~150ms, so drive the handler the
# signal would have called rather than spinning a main loop for it.
w._filter_changed()
print(sorted(w._rows))
print(w._group_widgets[heading].get_description())

calls = []
w._run_action = lambda verb, *targets: calls.append((verb, targets))
box = w._group_widgets[heading].get_header_suffix()
child = box.get_first_child()
while child is not None:
    if child.get_icon_name() == 'media-playback-stop-symbolic':
        child.emit('clicked')
    child = child.get_next_sibling()
print(calls)
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "1/2 up  ·  100 B" "unfiltered, the summary is just the group"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "['be-orders']" "the filter hides the healthy half"
  assert_match "$(printf '%s' "$out" | sed -n 3p)" "^1/2 up" "the count still describes the group, not the rows"
  assert_match "$(printf '%s' "$out" | sed -n 3p)" "1 not shown" "and says the rows are not all of it"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" \
    "[('stop', ('be-orders', 'fe-orders'))]" "\"Stop all\" stops all of orders, hidden rows included"
}

test_zen_is_one_flat_list_not_a_page_of_headings() {
  gui_display || return 0
  # Grouped, zen showed three headings over four rows. A heading for a group
  # of one is the same noise as a column header over a single row, which is
  # exactly what the terminal's zen drops.
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
def comp(name, app, state):
    return {'name': name, 'app': app, 'role': name[:2], 'state': state, 'rss': 10,
            'cpu': 0, 'errors': 0, 'since': 1}
w._on_state({
  'at': 1000, 'machine': {'memTotal': 100, 'memUsed': 10, 'cpuPercent': 1},
  # Deliberately the REVERSE of worst-first: listed crashed-first, the order
  # assertion below would hold with no sorting code at all.
  'components': [comp('fe-billing', 'billing', 'down'),
                 comp('be-billing', 'billing', 'starting'),
                 comp('fe-orders', 'orders', 'up'),
                 comp('be-orders', 'orders', 'crashed')],
  'deps': [{'name': 'postgres', 'state': 'up'}, {'name': 'redis', 'state': 'down'}],
  'summary': {'up': 1, 'crashed': 1, 'starting': 1, 'down': 1},
  'health': {'verdict': 'crit', 'headline': 'be-orders crashed', 'deep': False,
             'counts': {'crit': 1}, 'findings': [], 'recoverable': {}}})
print(sorted(t for t in (g.get_title() for g in w._groups) if t), w._dep_group.get_title())
print(w._overview_clamp.get_maximum_size(), w._comp_clamp.get_maximum_size())
w._toggle_zen()
print([g.get_title() for g in w._groups], repr(w._dep_group.get_title()))
print(sorted(w._rows))
print(w._overview_clamp.get_maximum_size(), w._comp_clamp.get_maximum_size())
print(w._overview_body.get_valign().value_nick, w._comp_header.get_visible())
order = []
row = w._groups[-1].get_first_child()
def walk(widget, out):
    if isinstance(widget, pgui.ComponentRow):
        out.append(widget.get_title()); return
    child = widget.get_first_child()
    while child is not None:
        walk(child, out); child = child.get_next_sibling()
walk(w._groups[-1], order)
w._toggle_zen()
print(sorted(t for t in (g.get_title() for g in w._groups) if t), w._dep_group.get_title())
print(w._overview_clamp.get_maximum_size())
print(' '.join(order))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "['billing', 'orders'] Dependencies" "grouped by app normally"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "1240 1240" "and the column is wide enough for the table"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "[''] ''" "in zen there are no headings, deps included"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "['be-billing', 'be-orders', 'fe-billing']" \
    "only what needs you, still one row per component"
  assert_eq "$(printf '%s' "$out" | sed -n 9p)" "be-orders be-billing fe-billing" \
    "worst first, the same order the terminal uses"
  assert_eq "$(printf '%s' "$out" | sed -n 5p)" "800 800" "the column narrows to something you read in one go"
  assert_eq "$(printf '%s' "$out" | sed -n 6p)" "center False" "the verdict sits in the middle, and the column header is gone"
  assert_eq "$(printf '%s' "$out" | sed -n 7p)" "['billing', 'orders'] Dependencies" "leaving zen puts the headings back"
  assert_eq "$(printf '%s' "$out" | sed -n 8p)" "1240" "and the width with them"
}

test_the_error_banner_shows_the_error_not_the_escape_codes() {
  gui_display || return 0
  # pitcrew colours its own errors and AdwBanner parses its title as Pango
  # markup, so the failure the banner exists to explain arrived as SGR bytes
  # across the top of the window. AdwBanner is also the one title in this app
  # that does NOT parse markup, so escaping it turned `pitcrew init <dir>`
  # into a literal `&lt;dir&gt;` -- both halves are asserted here.
  local out; out=$(_settings_drive "
from gi.repository import Adw
Adw.init()
w = pgui.Window('/bin/true', None, Settings(pathlib.Path('$(mktemp -d)/gui')))
w._fail('pitcrew stopped: \x1b[38;2;243;139;168mno project\x1b[0m at /srv/a&b <dir>')
print(w._banner.get_title())
print(w._banner.get_revealed())
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" \
    "pitcrew stopped: no project at /srv/a&b <dir>" "colour stripped, the text left alone"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "True" "and it is actually shown"
}

test_the_zen_column_is_never_narrower_than_a_row_needs() {
  gui_display || return 0
  # ComponentRow's columns are fixed widths; the component NAME is the only
  # flexible part, so a clamp under the row's natural width squeezes the name
  # until it wraps mid-word -- "be-billing" came out as "be-billi-/ng". That
  # is a silent, visual-only failure, and CLAMP_ZEN is a constant somebody will
  # tune. Ask the widget rather than trusting the number.
  local out; out=$(_settings_drive "
from gi.repository import Adw, GLib, Gtk
Adw.init()
import pitcrewgui.window as W
group = Adw.PreferencesGroup()
group.add(pgui.ComponentRow('be-billing', '#89b4fa', lambda *a: None, lambda *a: None))
win = Gtk.Window(child=group)
win.present()
ctx = GLib.MainContext.default()
for _ in range(200):
    ctx.iteration(False)
natural = group.measure(Gtk.Orientation.HORIZONTAL, -1)[1]
print(natural, W.CLAMP_ZEN, W.CLAMP_ZEN >= natural)
")
  assert_match "$out" 'True$' "CLAMP_ZEN ($out) must fit a component row without squeezing its name"
}

# ── theming ─────────────────────────────────────────────────────────────────
#
# The app used to follow the desktop theme and nothing else, so `pitcrew theme`
# meant nothing here: you picked Gruvbox, the terminal dashboard turned
# Gruvbox, and the window it belongs to did not move. These are about the two
# halves agreeing — same files, same roles, same answer.

test_the_app_reads_the_same_theme_files_the_cli_does() {
  gui_available || return 0
  local out; out=$(_settings_drive "
names = pgui.theme.available()
print(all(n in names for n in ('default', 'gruvbox', 'mono', 'rosepine', 'tokyonight')),
      pgui.theme.palette('gruvbox')['ok'],
      pgui.theme.palette('rosepine')['g1'])
")
  # The values are out of themes/gruvbox.sh and themes/rosepine.sh verbatim: the
  # point of this test is that nothing between the file and here reinterprets
  # them, so a literal is the assertion.
  assert_eq "$out" "True #b8bb26 #9ccfd8" "the shipped themes parse to their own hex"
}

test_a_theme_that_cannot_be_read_falls_back_instead_of_failing() {
  gui_available || return 0
  local out; out=$(_settings_drive "
built_in = '#' + pgui.theme.DEFAULT['ok']
print(pgui.theme.palette('definitely-not-a-theme')['ok'] == built_in,
      pgui.theme.palette('../../../etc/passwd')['ok'] == built_in,
      pgui.theme.palette('')['ok'] == built_in)
")
  # A name reaches this from $PITCREW_THEME, which is a string a person typed —
  # so 'not a theme' has to be an answer, not a traceback on a window that has
  # not been built yet.
  assert_eq "$out" "True True True" "an unknown, hostile or empty name is the built-in palette"
}

test_applying_a_theme_reaches_every_palette_the_app_draws_from() {
  gui_available || return 0
  local out; out=$(_settings_drive "
pgui.theme.apply('gruvbox', dark=True)
m = pgui.model
# The bars are the ramp; the dots and the verdict are the status roles. That
# split is the whole fix, in the terminal and here alike.
print(m.LEVEL['calm'], m.LEVEL['crit'],
      m.STATE_STYLE['up'][1], m.VERDICT_STYLE['crit'][0],
      m.SERIES_COLORS[1])
# And it has to reach what OTHER modules already imported: 'from .model import
# RAMP' binds the object, so rebinding here would leave widgets.py painting
# from the old palette — which is exactly what a half-applied theme looks like.
import pitcrewgui.widgets as w
print(w.LEVEL is m.LEVEL, w.RAMP is m.RAMP, w.STATE_STYLE is m.STATE_STYLE)
")
  assert_match "$out" '#8ec07c #fb4934 #b8bb26 #fb4934 #b8bb26' "every palette turned gruvbox"
  assert_match "$out" 'True True True' "and widgets.py is looking at the same objects"
}

test_graph_lines_stay_apart_in_every_theme() {
  gui_available || return 0
  # A palette has fewer distinct colours than a graph has lines: gruvbox's info
  # and g1 are one green, rosepine's accent and info are one teal, and mono is
  # four greys on purpose. Two services drawn in the same colour is a graph
  # that lies about which is which.
  local out; out=$(_settings_drive "
bad = []
for name in pgui.theme.available():
    for dark in (True, False):
        pgui.theme.apply(name, dark)
        colors = pgui.model.SERIES_COLORS
        if len(set(colors)) != len(colors):
            bad.append(f'{name}/dark={dark}')
print(' '.join(bad) or 'all-distinct')
")
  assert_eq "$out" "all-distinct" "no theme hands two graph lines the same colour"
}

test_a_dark_palette_is_darkened_for_a_light_desktop() {
  gui_available || return 0
  # Every theme pitcrew ships is a dark one, because a terminal is dark. The
  # window is whatever the desktop says, and #a6e3a1 on white is a green you
  # cannot read — which is why the log view used to carry a second, hand-picked
  # light palette. There is no hand-picked light variant of a theme nobody has
  # written yet, so the lightness comes down and the hue stays.
  local out; out=$(_settings_drive "
t = pgui.theme
green = '#a6e3a1'
print(t.legible(green, dark=True) == green,
      t.luminance(t.legible(green, dark=False)) <= t._LIGHT_MAX_LUMINANCE,
      max(t.luminance(v) for v in t.ansi_palette(t.palette('tokyonight'), False).values())
          <= t._LIGHT_MAX_LUMINANCE)
")
  assert_eq "$out" "True True True" "dark is left alone; light gets a palette it can read"
}

test_the_app_and_the_cli_share_one_saved_preference() {
  gui_available || return 0
  local pref; pref=$(mktemp)
  local out; out=$(PITCREW_THEME_FILE="$pref" _settings_drive "
t = pgui.theme
open(os.environ['PITCREW_THEME_FILE'], 'w').write('gruvbox\n')   # what \`pitcrew theme\` writes
first = t.active_name()
t.save('rosepine')                                                # what Preferences writes
print(first, open(os.environ['PITCREW_THEME_FILE']).read().strip(), t.active_name())
")
  rm -f "$pref"
  assert_eq "$out" "gruvbox rosepine rosepine" "one file, written and read from both sides"
}

test_the_env_override_beats_the_saved_preference() {
  gui_available || return 0
  local pref; pref=$(mktemp); printf 'gruvbox\n' > "$pref"
  local out; out=$(PITCREW_THEME_FILE="$pref" PITCREW_THEME=mono _settings_drive "
print(pgui.theme.active_name())
")
  rm -f "$pref"
  # The same precedence the CLI applies: an env var is a deliberate one-off.
  assert_eq "$out" "mono" "PITCREW_THEME wins for this run"
}

test_a_theme_picked_elsewhere_reaches_an_open_window() {
  gui_display || return 0
  # Two front ends, one preference file. `pitcrew theme rosepine` in a terminal
  # has to repaint a window that is already open, or the two disagree until it
  # is restarted.
  local pref; pref=$(mktemp); printf 'gruvbox\n' > "$pref"
  local out; out=$(PITCREW_THEME_FILE="$pref" _settings_drive "
import tempfile
from gi.repository import Adw, GLib
Adw.init()
# The value a palette entry ENDS UP with depends on whether the desktop is
# dark: a dark palette is darkened to stay legible on a light one (see
# theme.legible, and the test for it below). A CI runner has no desktop
# preference at all and counts as light, so asserting a raw theme colour here
# was really asserting what the machine's chrome happened to be. This test is
# about the file reaching the window, so the other variable is pinned.
Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.FORCE_DARK)
settings = pgui.Settings(path=pathlib.Path(tempfile.mktemp()))
win = pgui.Window('/bin/true', None, settings)
before = win._theme_name
open(os.environ['PITCREW_THEME_FILE'], 'w').write('rosepine\n')
loop = GLib.MainLoop()
GLib.timeout_add(1200, lambda: (loop.quit(), False)[1])
loop.run()
print(before, win._theme_name, pgui.model.LEVEL['crit'])
")
  rm -f "$pref"
  assert_eq "$out" "gruvbox rosepine #eb6f92" "the window followed the file it did not write"
}

test_a_repaint_reaches_the_lists_the_frame_does_not_build() {
  gui_display || return 0
  # Repainting replays the last frame, which rebuilds everything the STREAM
  # feeds. The Projects list is not one of those things — it comes from its own
  # `pitcrew projects --json` and is refreshed on a project switch or a stream
  # restart — so its state dots kept the palette they were built with, and a
  # theme switched from the terminal left them behind until you clicked away.
  local pref; pref=$(mktemp); printf 'gruvbox\n' > "$pref"
  local out; out=$(PITCREW_THEME_FILE="$pref" _settings_drive "
import tempfile
from gi.repository import Adw
Adw.init()
calls = []
pgui.Window._refresh_projects = lambda self: calls.append(1)
settings = pgui.Settings(path=pathlib.Path(tempfile.mktemp()))
win = pgui.Window('/bin/true', None, settings)
before = len(calls)
win._apply_theme('rosepine')
print(len(calls) > before)
")
  rm -f "$pref"
  assert_eq "$out" "True" "a theme change refreshes the Projects list too"
}

run_tests
