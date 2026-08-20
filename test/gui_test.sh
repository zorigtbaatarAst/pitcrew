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

run_tests
