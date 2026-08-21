"""GUI preferences: `~/.config/pitcrew/gui`, in the house key=value format."""

from __future__ import annotations

import os
from pathlib import Path

from .platform import pitcrew_home


class Setting:
    """One preference: its choices, its default, and how to read it back.

    `choices` is a list for a pick-one setting, or an (lo, hi) tuple for a
    number. Either way `coerce` returns the default for anything it does not
    recognise — see `Settings.load`.
    """

    def __init__(self, key: str, default, choices, blurb: str):
        self.key = key
        self.default = default
        self.choices = choices
        self.blurb = blurb

    @property
    def numeric(self) -> bool:
        return isinstance(self.choices, tuple)

    def coerce(self, raw):
        if raw is None:
            return self.default
        if not self.numeric:
            return raw if raw in self.choices else self.default
        try:
            value = int(raw)
        except (TypeError, ValueError):
            return self.default
        lo, hi = self.choices
        return value if lo <= value <= hi else self.default

SETTINGS = (
    Setting("group", "app", ["app", "role", "flat"],
            "How the component list is grouped"),
    Setting("interval", 2, (1, 60),
            "Seconds between samples"),
    Setting("history", 120, (30, 600),
            "Samples kept per graph line"),
    Setting("stopped", "show", ["show", "hide"],
            "Whether stopped components are listed"),
    Setting("plot", "running", ["running", "all"],
            "Which components get a line in the graphs"),
    Setting("collapse", "auto", ["auto", "never"],
            "Fold up groups where nothing is running"),
    Setting("notify", "crash", ["crash", "none"],
            "Send a desktop notification when a component crashes"),
    # Window geometry is a preference like any other, and lives in the same file
    # rather than pulling in GSettings for three integers.
    Setting("width", 900, (600, 5000), "Remembered window width"),
    Setting("height", 680, (400, 4000), "Remembered window height"),
    Setting("tab", "overview",
            ["overview", "components", "resources", "logs", "projects"],
            "The view to open on"),
)
SETTINGS_BY_KEY = {setting.key: setting for setting in SETTINGS}

class Settings(dict):
    """`~/.config/pitcrew/gui`, in the same key=value shape as `render`.

    Deliberately the house format rather than GSettings: pitcrew already keeps
    `render`, `theme` and `current` here as plain text you can cat, diff and
    edit over ssh, and a schema that has to be compiled and installed would be
    the one part of this tool you could not just symlink into place.

    A value the running version does not recognise falls back to the default —
    the file is written by us, so an unknown value means it was hand-edited or
    written by a newer version, and neither is worth crashing over.
    """

    def __init__(self, path: Path | None = None):
        super().__init__((setting.key, setting.default) for setting in SETTINGS)
        self.path = path or (pitcrew_home() / "gui")
        self.load()

    def load(self) -> None:
        raw: dict[str, str] = {}
        try:
            for line in self.path.read_text(encoding="utf-8").splitlines():
                key, sep, value = line.partition("=")
                if sep:
                    raw[key.strip()] = value.strip()
        except OSError:
            pass                      # no file yet, or unreadable: all defaults
        for setting in SETTINGS:
            # An env var wins over the file, matching how PITCREW_GRAPH and
            # friends override `render`.
            override = os.environ.get(f"PITCREW_GUI_{setting.key.upper()}")
            self[setting.key] = setting.coerce(override or raw.get(setting.key))

    def save(self) -> bool:
        """Rewrite the whole file. Returns False if it could not be written."""
        body = "".join(f"{setting.key}={self[setting.key]}\n" for setting in SETTINGS)
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(body, encoding="utf-8")
        except OSError:
            return False              # read-only home; the session still works
        return True
