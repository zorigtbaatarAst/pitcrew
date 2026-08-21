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

# The GTK bindings live in the system python, which is what the app shebangs
# into — not whatever `python3` resolves to on $PATH (a Homebrew or pyenv
# python has no `gi`). No bindings, no GUI, nothing to test: skip, don't fail.
# The interpreter with the bindings is not the same one on every OS — that is
# the whole reason the app re-execs instead of pinning a shebang, and a test
# file that hardcodes /usr/bin/python3 would silently SKIP everything on macOS
# and report a green run for a GUI nobody checked.
PY_WITH_GI=""
for _candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 python3; do
  command -v "$_candidate" >/dev/null 2>&1 || continue
  if "$_candidate" -c 'import gi, cairo' >/dev/null 2>&1; then PY_WITH_GI=$_candidate; break; fi
done

gui_available() {
  [ -d "$GUI_DIR/pitcrewgui" ] && [ -n "$PY_WITH_GI" ]
}

# The GUI is a package now, so the whole public surface is assembled into one
# namespace here rather than rewriting every assertion below to know which
# module a name ended up in.
_PRELUDE="
import importlib, sys, types
sys.path.insert(0, '$GUI_DIR')
pgui = types.SimpleNamespace()
for _name in ('platform', 'model', 'registry', 'settings', 'runner', 'widgets',
              'dialogs', 'window', 'app'):
    _mod = importlib.import_module('pitcrewgui.' + _name)
    pgui.__dict__.update({k: v for k, v in vars(_mod).items() if not k.startswith('_')})
# As a module, not flattened: ansi.plain and model.plain are different functions
# with the same name, and one of them would silently win.
import pitcrewgui.ansi as _ansi_mod
pgui.ansi = _ansi_mod
"

_drive() { # $1 = python body, with Stream / Counting / GLib in scope
  "$PY_WITH_GI" -c "
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
  gui_available || return 0
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 0
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
d = pathlib.Path('$1')
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
  gui_available || return 0
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
  gui_available || return 0
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
  gui_available || return 0
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

test_the_picker_is_not_rebuilt_on_every_frame() {
  gui_available || return 0
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
  "$PY_WITH_GI" -c "
import os, pathlib, sys
import gi
gi.require_version('Gtk', '4.0')
$_PRELUDE
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
  gui_available || return 0
  # A smoke test over the real widget tree: every view is built, then one
  # synthetic frame is pushed through the same path the stream uses. A typo in
  # a rarely-taken render branch is otherwise only found by opening the app.
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 0
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
  gui_available || return 0
  # A candidate list that silently omits your biggest idle service reads as a
  # bug. The lock has to be visible.
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 0
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
  gui_available || return 0
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 0
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
  gui_available || return 0
  # The GUI must never run its own ps — the tree arrives in the state object.
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 0
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
  gui_available || return 0
  # Watching a heap climb is what someone opens this for. A dialog frozen at
  # the instant you clicked is a screenshot, not a monitor.
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 0
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
  gui_available || return 0
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 0
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

# ── project registry and config editing ─────────────────────────────────────

test_the_config_editor_follows_the_source_indirection() {
  gui_available || return 0
  # A registry entry for a repo that ships its own pitcrew.config.sh only sets
  # PITCREW_ROOT and sources it — editing that stub would change nothing pitcrew
  # reads, so the GUI has to open the file with the content in it.
  local home repo; home=$(mktemp -d); repo=$(mktemp -d)
  mkdir -p "$home/projects"
  # $PITCREW_ROOT stays literal on purpose — that is what init writes into the stub.
  # shellcheck disable=SC2016
  printf 'PITCREW_ROOT=%s\nsource "$PITCREW_ROOT/pitcrew.config.sh"\n' "$repo" > "$home/projects/stub.sh"
  printf 'PITCREW_APPS=(a)\n' > "$repo/pitcrew.config.sh"
  printf 'PITCREW_ROOT=%s\nPITCREW_APPS=(a)\n' "$repo" > "$home/projects/own.sh"

  local out; out=$(PITCREW_HOME=$home _settings_drive "
print(pgui.project_config_path('stub'))
print(pgui.project_config_path('own'))
print(pgui.declared_root(pgui.project_file('own')))
print(' '.join(pgui.known_projects()))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "$repo/pitcrew.config.sh" "stub resolves into the repo"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "$home/projects/own.sh" "a self-contained entry is edited in place"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "$repo" "PITCREW_ROOT is read without sourcing"
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
  printf 'root: %s\ninclude: pitcrew.yaml\n' "$repo" > "$home/projects/ystub.yaml"
  printf 'name: shipped\napps:\n  a:\n    be:\n      cmd: "true"\n' > "$repo/pitcrew.yaml"
  printf 'root: %s\nname: own\n' "$repo" > "$home/projects/yown.yaml"

  local out; out=$(PITCREW_HOME=$home _settings_drive "
print(pgui.project_config_path('ystub'))
print(pgui.project_config_path('yown'))
print(pgui.declared_root(pgui.project_file('yown')))
print(' '.join(pgui.known_projects()))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "$repo/pitcrew.yaml" "stub resolves into the repo"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "$home/projects/yown.yaml" "a self-contained entry is edited in place"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "$repo" "root: is read without loading the config"
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
  local out2; out2=$(PITCREW_HOME=/tmp/elsewhere _settings_drive "print(pgui.pitcrew_home())")
  assert_eq "$out2" "/tmp/elsewhere" "and PITCREW_HOME still overrides it"
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
  gui_available || return 0
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
  gui_available || return 0
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
  gui_available || return 0
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
  gui_available || return 0
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

test_a_profile_is_read_from_the_directory_pitcrew_writes() {
  gui_available || return 0
  local dir; dir=$(mktemp -d)
  printf 'sales\nbe-orders\n' > "$dir/morning"
  : > "$dir/empty"
  local out; out=$(_drive "
from pitcrewgui.profiles import profile_names, profile_targets
print(' '.join(profile_names('$dir')))
print(' '.join(profile_targets('$dir', 'morning')))
print(profile_names(None), profile_targets('$dir', 'nope'))
")
  rm -rf "$dir"
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "empty morning" "one entry per saved profile"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "sales be-orders" "targets, one per line"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "[] []" "no directory and no file are both empty, not errors"
}

test_every_icon_the_gui_asks_for_actually_exists() {
  gui_available || return 0
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
rows, total = share_slices([('a', 100), ('b', 300), ('c', 0), ('d', None)])
print(rows)
print(total)
print(share_slices([]))
print(round(rows[0][1] / total * 100))
")
  assert_eq "$(printf '%s' "$out" | sed -n 1p)" "[('b', 300.0), ('a', 100.0)]" \
    "biggest first, and nothing for a component using nothing"
  assert_eq "$(printf '%s' "$out" | sed -n 2p)" "400.0" "the total is the sum of the slices"
  assert_eq "$(printf '%s' "$out" | sed -n 3p)" "([], 0)" "an idle stack draws no ring"
  assert_eq "$(printf '%s' "$out" | sed -n 4p)" "75" "shares are of the drawn total"
}

run_tests
