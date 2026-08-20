"""The application object and the command line."""

from __future__ import annotations

import sys

from gi.repository import Adw, Gio

from .platform import find_pitcrew
from .registry import current_project
from .settings import SETTINGS, SETTINGS_BY_KEY, Settings
from .window import Window

APP_ID = "mn.zb.PitcrewGui"

class Application(Adw.Application):
    def __init__(self, pitcrew: str, project: str | None, settings: Settings):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.NON_UNIQUE)
        self._pitcrew = pitcrew
        self._project = project
        self._settings = settings

    def do_activate(self) -> None:
        window = self.props.active_window
        if window is None:
            window = Window(self._pitcrew, self._project, self._settings, application=self)
            # The "Show logs" button on a crash notification is an APP action:
            # it has to work when the notification is clicked long after the
            # window lost focus.
            window._crashes.install_action()
        window.present()

USAGE = """usage: pitcrew-gui [-p NAME] [OPTION...]

  -p, --project NAME   project to watch (default: whatever `pitcrew use` selected)
  -i, --interval N     alias for --interval
  -h, --help           this

Preferences live in ~/.config/pitcrew/gui and are editable in-app (Ctrl+,).
Any of them can be overridden for one run:
"""

def main(argv: list[str]) -> int:
    settings = Settings()
    project = current_project()

    # Every preference is also a flag, so a launcher or a one-off can pin one
    # without touching the saved file — the same deal `pitcrew render` offers.
    overrides: dict[str, object] = {}
    args = argv[1:]
    while args:
        arg = args.pop(0)
        if arg in ("-h", "--help"):
            print(USAGE)
            for setting in SETTINGS:
                allowed = (f"{setting.choices[0]}-{setting.choices[1]}"
                           if setting.numeric else "|".join(setting.choices))
                print(f"  --{setting.key:<10} {allowed:<28} {setting.blurb}"
                      f" (default: {setting.default})")
            return 0
        if arg in ("-p", "--project"):
            if not args:
                print("--project needs a name", file=sys.stderr)
                return 2
            project = args.pop(0)
            continue
        # -i is the one short alias kept, because it shipped documented.
        key = {"-i": "interval"}.get(arg) or (arg[2:] if arg.startswith("--") else None)
        if key in SETTINGS_BY_KEY:
            if not args:
                print(f"--{key} needs a value", file=sys.stderr)
                return 2
            raw, setting = args.pop(0), SETTINGS_BY_KEY[key]
            value = setting.coerce(raw)
            # A flag is an explicit instruction. Silently substituting the
            # default for a typo is exactly the "errors pass quietly" failure
            # the settings FILE is allowed to have and a command line is not.
            if str(value) != str(raw):
                allowed = (f"{setting.choices[0]}-{setting.choices[1]}"
                           if setting.numeric else ", ".join(setting.choices))
                print(f"--{key}: {raw!r} is not valid (expected {allowed})", file=sys.stderr)
                return 2
            overrides[key] = value
            continue
        print(f"unknown argument: {arg}", file=sys.stderr)
        return 2

    settings.update(overrides)

    pitcrew = find_pitcrew()
    if not pitcrew:
        # Fail loudly here rather than opening a window that can never populate.
        print("pitcrew not found on $PATH or in ~/.local/bin", file=sys.stderr)
        return 1
    return Application(pitcrew, project, settings).run([argv[0]])
