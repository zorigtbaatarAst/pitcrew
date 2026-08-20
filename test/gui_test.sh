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
"

_drive() { # $1 = python body, with Stream / Counting / GLib in scope
  "$PY_WITH_GI" -c "
import sys
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gio, GLib
$_PRELUDE

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

run_tests
