"""The pitcrew palette, read from the same theme files the terminal draws with.

The app used to follow the desktop theme and nothing else. That was a defensible
call — Adwaita's accent and light/dark are the user's choice, and inventing a
look beside them ages badly — but it left `pitcrew theme` meaning nothing here:
you picked Gruvbox, the dashboard turned Gruvbox, and the window it belongs to
did not move. Two front ends to one tool disagreeing about what the tool looks
like is not restraint, it is a missing feature.

So: Adwaita still owns the CHROME. The window, the rows, the buttons and the
light/dark decision are the desktop's, exactly as before. What comes from the
theme is what pitcrew actually draws — meters, graph series, state dots, the
verdict tint and the ANSI palette the log view renders with — which is the same
boundary the terminal draws at, and the same set of roles.

A theme file is bash, but the only thing in one is `T_ROLE=rrggbb` (see
themes/default.sh — five lines). Parsing that with a regex rather than running
bash is deliberate: this module has to work on a machine where the CLI is a
Windows-hosted checkout the GUI cannot execute, and a palette is not worth a
subprocess. Anything the regex does not recognise falls back to the built-in
value for that role, so a hand-written theme with one typo loses one colour.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from . import model
from .platform import find_pitcrew, pitcrew_home

# The built-in palette, role for role with lib/01-core.sh's theme_hex_defaults.
# Kept here rather than imported from anywhere: it is the answer when there is
# no theme file to read, which includes the case where there is no checkout.
DEFAULT: dict[str, str] = {
    "text": "cdd6f4",      # primary text — values you read
    "subtle": "9399b2",    # secondary text — names you scan
    "muted": "6c7086",     # chrome — ports, labels, separators
    "faint": "45475a",     # barely there — baselines, placeholders
    "surface": "313244",   # selected-row background
    "accent": "89b4fa",
    "accent2": "cba6f7",
    "ok": "a6e3a1",
    "warn": "f9e2af",
    "crit": "f38ba8",
    "info": "89dceb",
    # the graph ramp, bottom of the chart to the top
    "g1": "94e2d5", "g2": "a6e3a1", "g3": "f9e2af", "g4": "f38ba8",
}

# `T_OK=a6e3a1`, wherever it appears on a line — the shipped themes put five
# assignments on one line separated by semicolons, and a hand-written one may
# not. Six hex digits only: a role assigned from a variable or a shell
# expression is not something this parser will guess at.
_ASSIGN = re.compile(r"\bT_([A-Z0-9_]+)\s*=\s*['\"]?#?([0-9a-fA-F]{6})\b")


# ── where the themes are ────────────────────────────────────────────────────

def theme_dirs() -> list[Path]:
    """Yours first, then the ones pitcrew ships — the CLI's own search order."""
    dirs = [pitcrew_home() / "themes"]
    checkout = _checkout()
    if checkout is not None:
        dirs.append(checkout / "themes")
    # The package is installed inside the checkout (gui/pitcrewgui/), so this is
    # the same directory again in the normal case — and the only one that still
    # resolves when the CLI is not on this machine's PATH at all.
    dirs.append(Path(__file__).resolve().parents[2] / "themes")
    seen, unique = set(), []
    for directory in dirs:
        if directory not in seen:
            seen.add(directory)
            unique.append(directory)
    return unique


def _checkout() -> Path | None:
    """The repo the CLI lives in: `<repo>/bin/pitcrew` → `<repo>`.

    resolve() rather than the path as found, because install.sh puts a SYMLINK
    in ~/.local/bin and the themes are beside the real file, not beside the link.
    """
    found = find_pitcrew()
    if not found:
        return None
    try:
        real = Path(found).resolve(strict=True)
    except OSError:
        return None
    return real.parent.parent if real.parent.name == "bin" else None


def available() -> list[str]:
    """Every theme that can be loaded, yours first, deduped by name."""
    names: list[str] = []
    for directory in theme_dirs():
        try:
            entries = sorted(directory.glob("*.sh"))
        except OSError:
            continue
        for entry in entries:
            if entry.stem not in names:
                names.append(entry.stem)
    return names


# ── which one is active ─────────────────────────────────────────────────────

def theme_file() -> Path:
    return Path(os.environ.get("PITCREW_THEME_FILE") or (pitcrew_home() / "theme"))


def active_name() -> str:
    """`PITCREW_THEME`, else the saved preference, else the built-in palette.

    Two of the CLI's four sources, and the two that are not project-specific.
    A theme pinned in a project's own pitcrew.yaml is deliberately NOT read
    here: the app switches projects without restarting, and a palette that
    changed under you every time you changed project would be worse than one
    that never changes at all.
    """
    from_env = os.environ.get("PITCREW_THEME", "").strip()
    if from_env:
        return from_env
    try:
        saved = theme_file().read_text(encoding="utf-8").strip().splitlines()
    except OSError:
        return "default"
    return (saved[0].strip() if saved else "") or "default"


def save(name: str) -> bool:
    """Remember a choice where `pitcrew theme` will find it. False if unwritable."""
    path = theme_file()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"{name}\n", encoding="utf-8")
    except OSError:
        return False
    return True


# ── reading one ─────────────────────────────────────────────────────────────

def palette(name: str | None = None) -> dict[str, str]:
    """Every role as `#rrggbb`, with the built-in value wherever one is missing."""
    values = dict(DEFAULT)
    wanted = (name or active_name()).strip()
    if wanted and wanted != "default":
        text = _read(wanted)
        for role, hex_value in _ASSIGN.findall(text or ""):
            key = role.lower()
            if key in values:
                values[key] = hex_value.lower()
    return {role: f"#{value}" for role, value in values.items()}


def _read(name: str) -> str | None:
    # A theme NAME comes from a picker built out of the directory listing, but
    # it also comes from $PITCREW_THEME, which is a string a person typed.
    # `../../etc/passwd` is not a theme, and this is the one place that can be
    # told so.
    if "/" in name or "\\" in name or name.startswith("."):
        return None
    for directory in theme_dirs():
        candidate = directory / f"{name}.sh"
        try:
            return candidate.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
    return None


# ── making a dark palette legible on a light desktop ────────────────────────
#
# Every theme pitcrew ships is a dark one, because a terminal is dark. A window
# is whatever the user's desktop says, and #a6e3a1 on white is a green you
# cannot read — which is exactly why the log view carried a second, hand-picked
# light palette before this existed. Hand-picking a light variant of a theme
# nobody has written yet is not possible, so instead: keep the hue, take the
# lightness down until the colour has something to contrast against.
#
# Relative luminance (WCAG 2.1), not HSL lightness: a saturated yellow and a
# saturated blue at the same HSL lightness are nowhere near equally readable.

_LIGHT_MAX_LUMINANCE = 0.30


def _channel(value: float) -> float:
    return value / 12.92 if value <= 0.03928 else ((value + 0.055) / 1.055) ** 2.4


def luminance(color: str) -> float:
    red, green, blue = (int(color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return 0.2126 * _channel(red) + 0.7152 * _channel(green) + 0.0722 * _channel(blue)


def legible(color: str, dark: bool) -> str:
    """`color` as-is on a dark desktop; darkened enough to read on a light one."""
    if dark or luminance(color) <= _LIGHT_MAX_LUMINANCE:
        return color
    channels = [int(color[i:i + 2], 16) for i in (1, 3, 5)]
    # Scale all three together so the hue survives; sixteen halvings is far more
    # than enough to reach any target and bounds the loop unconditionally.
    for _ in range(16):
        channels = [int(c * 0.88) for c in channels]
        candidate = "#{:02x}{:02x}{:02x}".format(*channels)
        if luminance(candidate) <= _LIGHT_MAX_LUMINANCE:
            return candidate
    return "#000000"


def shift(color: str, amount: float, dark: bool) -> str:
    """`amount` further from the background: lighter on dark, darker on light.

    One function rather than a lighten() every caller would have to remember to
    invert, because every use of it means the same thing — "the same colour,
    with more contrast" — and which direction that is depends on the desktop,
    not on the caller.
    """
    amount = max(0.0, min(0.85, amount))
    channels = [int(color[i:i + 2], 16) for i in (1, 3, 5)]
    if dark:
        channels = [min(255, int(c + (255 - c) * amount)) for c in channels]
    else:
        channels = [max(0, int(c * (1 - amount))) for c in channels]
    return "#{:02x}{:02x}{:02x}".format(*channels)


# The palette roles a graph line can be, in the order they are handed out.
# Ordered so neighbours differ in hue as well as in lightness: a legend is read
# top to bottom, and two adjacent entries are the pair most often confused.
_SERIES_ROLES = ("accent", "ok", "warn", "crit", "accent2", "info", "g1", "g3")


def series_colors(ink: dict[str, str], dark: bool, count: int = 8) -> list[str]:
    """`count` line colours that stay apart.

    A palette has fewer distinct colours than a graph has lines, and the
    overlaps are real: Gruvbox's info and g1 are the same green, Rosé Pine's
    accent and info are the same teal, and mono is four greys on purpose. Two
    services drawn in one colour is a graph that lies about which is which, so
    the roles are taken in order without repeats and the remainder is filled by
    pushing what is already there further from the background.
    """
    out: list[str] = []
    for role in _SERIES_ROLES:
        if ink[role] not in out:
            out.append(ink[role])
    step = 0
    while len(out) < count and step < 4:
        step += 1
        for role in _SERIES_ROLES:
            candidate = shift(ink[role], 0.22 * step, dark)
            if candidate not in out:
                out.append(candidate)
                if len(out) == count:
                    break
    # A theme of one flat colour cannot yield eight of them, and a list short of
    # `count` here is an IndexError in the legend rather than a duller graph.
    return (out * count)[:count]


# ── making it true everywhere ───────────────────────────────────────────────

def ansi_palette(colors: dict[str, str], dark: bool) -> dict[str, str]:
    """The sixteen ANSI names a log can ask for, as this theme would draw them.

    A log's own colours were chosen by someone who assumed a dark terminal, so
    the mapping is onto ROLES rather than onto hues: `\\x1b[32m` in a Spring log
    means "this line is fine", and the theme already has a colour for that.

    Bright black is a real grey that logs use for timestamps and must not fold
    into black, so the two are separate roles rather than one lightened twice.
    """
    base = {
        "black": colors["faint"],
        "red": colors["crit"],
        "green": colors["ok"],
        "yellow": colors["warn"],
        "blue": colors["info"],
        "magenta": colors["accent2"],
        "cyan": colors["accent"],
        "white": colors["subtle"],
    }
    palette = {name: legible(value, dark) for name, value in base.items()}
    palette["bright-black"] = legible(colors["muted"], dark)
    for name in base:
        if name != "black":
            palette[f"bright-{name}"] = shift(palette[name], 0.25, dark)
    palette["bright-white"] = legible(colors["text"], dark)
    # The error tag is the log view's own, not an ANSI code: a line the error
    # pattern matched, whatever colour it painted itself.
    palette["error"] = palette["red"]
    return palette


def apply(name: str | None = None, dark: bool = True) -> dict[str, str]:
    """Repaint every palette the app draws from. Returns the resolved colours.

    Mutates in place rather than rebinding, because `from .model import RAMP`
    in three other modules has already captured these objects — rebinding here
    would leave every one of them pointing at the old palette, which is exactly
    the sort of half-applied theme that reads as "it did nothing".
    """
    colors = palette(name)
    ink = {role: legible(value, dark) for role, value in colors.items()}

    # Drawn quantities: the theme's own graph ramp, bottom to top.
    model.LEVEL.update(calm=ink["g1"], warn=ink["g3"], crit=ink["g4"])

    # Verdicts you read: the status roles, which is what those words mean.
    model.RAMP.update(calm=ink["muted"], ok=ink["ok"],
                      warn=ink["warn"], crit=ink["crit"])
    for level, (_old, css) in list(model.VERDICT_STYLE.items()):
        model.VERDICT_STYLE[level] = (model.RAMP[level], css)

    dots = {"up": "ok", "starting": "warn", "crashed": "crit",
            "external": "accent", "down": "muted"}
    for state, role in dots.items():
        css = model.STATE_STYLE[state][0]
        model.STATE_STYLE[state] = (css, ink[role])
    model.UNKNOWN_STYLE[1] = ink["muted"]

    model.SERIES_COLORS[:] = series_colors(ink, dark, len(model.SERIES_COLORS))
    return colors
