"""Pure presentation logic: colours, formatting, and the rolling history.

No GTK and no OS calls, so every rule about how a number is rendered or a
component is grouped can be tested without a display."""

from __future__ import annotations

from collections import deque

from gi.repository import GLib

SERIES_COLORS = (
    "#3584e4", "#33d17a", "#f6d32d", "#ff7800",
    "#e01b24", "#9141ac", "#00b8c4", "#986a44",
)

# state -> (libadwaita css class for the badge, dot colour)
STATE_STYLE = {
    "up":       ("success",   "#33d17a"),
    "starting": ("warning",   "#f6d32d"),
    "crashed":  ("error",     "#e01b24"),
    "external": ("accent",    "#3584e4"),
    "down":     ("dim-label", "#77767b"),
}
UNKNOWN_STYLE = ("dim-label", "#77767b")

def rgb(hex_color: str) -> tuple[float, float, float]:
    return tuple(int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))

def human_bytes(n: float | None) -> str:
    """Bytes for humans. None means "we have no reading"; 0 means zero — an axis
    label of "—" at the bottom of a graph is a bug, not a blank."""
    if n is None:
        return "—"
    value = float(n)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024:
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TiB"

def nice_max(observed: float, floor: float) -> float:
    """A round axis ceiling above what we've seen, never below `floor`.

    Rounded up to a multiple of FOUR steps so the four gridline labels land on
    whole steps — otherwise a ceiling of 130 prints 98%/65%/32% down the side.
    """
    target = max(observed, floor, 1.0)
    step = 4 * 10 ** max(0, len(str(int(target))) - 2)
    return max(floor, (int(target / step) + 1) * step)

def plain(text: str) -> str:
    """Escape text destined for a widget that parses Pango markup.

    AdwPreferencesRow:use-markup covers the TITLE only — subtitles, and group
    titles and descriptions, are parsed regardless. Paths and app names come out
    of a config file, so a checkout at /srv/a&b renders as nothing at all
    (with a warning on stderr nobody is reading) unless it is escaped.
    """
    return GLib.markup_escape_text(text)

class Series:
    """One component's rolling history."""

    def __init__(self, name: str, color: str, size: int):
        self.name = name
        self.color = color
        self.rgb = rgb(color)
        self.size = size
        self.cpu: deque[float] = deque(maxlen=size)
        self.rss: deque[float] = deque(maxlen=size)

    def resize(self, size: int) -> None:
        """Change the window without losing what we already have."""
        if size == self.size:
            return
        self.size = size
        self.cpu = deque(self.cpu, maxlen=size)
        self.rss = deque(self.rss, maxlen=size)

    def push(self, cpu: float | None, rss: float | None) -> None:
        # cpu is null until the stream has a baseline; carry the last known
        # value rather than drawing a phantom drop to zero.
        self.cpu.append(float(cpu) if cpu is not None else (self.cpu[-1] if self.cpu else 0.0))
        self.rss.append(float(rss or 0))

def empty_message(total: int) -> str:
    """Why the component list is empty — never leave it blank and ambiguous."""
    if not total:
        return "This project has no components configured."
    plural = "s" if total != 1 else ""
    return (f"Nothing is running.\n{total} stopped component{plural} "
            f"hidden by “Show stopped components”.")

# The verdict lib/19-diag.sh reached, as something to paint with. Same three
# levels, same meaning, and the dot colours match the terminal dashboard's so
# the two do not disagree about what amber means.
VERDICT_STYLE = {
    "ok":   ("#33d17a", "success"),
    "warn": ("#f6d32d", "warning"),
    "crit": ("#e01b24", "error"),
}

def verdict_of(state: dict) -> tuple[str, str, str]:
    """(level, colour, headline) for the whole stack.

    Read straight out of the stream. The GUI deliberately does not work this
    out from the component list: that judgement is a product decision, it lives
    in one place (the shell), and a second implementation here would drift from
    it the first time either side gained a check.

    Falls back to the component counts only when talking to a pitcrew too old
    to send a verdict — a blank header is worse than an approximate one.
    """
    health = state.get("health") or {}
    level = health.get("verdict")
    if level in VERDICT_STYLE:
        return level, VERDICT_STYLE[level][0], health.get("headline") or ""
    summary = state.get("summary") or {}
    if summary.get("crashed"):
        return "crit", VERDICT_STYLE["crit"][0], f"{summary['crashed']} crashed"
    if summary.get("starting"):
        return "warn", VERDICT_STYLE["warn"][0], f"{summary['starting']} starting"
    return "ok", VERDICT_STYLE["ok"][0], f"{summary.get('up', 0)} up"


def findings_of(state: dict) -> list[dict]:
    """Findings worst-first, which is the order they need to be read in."""
    health = state.get("health") or {}
    rank = {"crit": 0, "warn": 1, "info": 2}
    return sorted(health.get("findings") or [],
                  key=lambda f: rank.get(f.get("severity"), 3))


def machine_meters(machine: dict, project_rss: float) -> list[tuple[str, float, str]]:
    """(label, percent, figures) for the machine gauges.

    Swap is included only when the machine has any: a row reading "0 B / 0 B"
    on a swapless container is noise, and its absence is not a fact worth a
    line of screen.
    """
    rows: list[tuple[str, float, str]] = []
    total = machine.get("memTotal") or 0
    used = machine.get("memUsed") or 0
    if total:
        rows.append(("RAM", used * 100 / total,
                     f"{human_bytes(used)} / {human_bytes(total)}"))
    rows.append(("CPU", machine.get("cpuPercent") or 0,
                 f"{machine.get('cpuPercent') or 0}%"))
    swap_total = machine.get("swapTotal") or 0
    if swap_total:
        swap_used = machine.get("swapUsed") or 0
        rows.append(("SWAP", swap_used * 100 / swap_total,
                     f"{human_bytes(swap_used)} / {human_bytes(swap_total)}"))
    if total:
        rows.append(("THIS", project_rss * 100 / total,
                     f"{human_bytes(project_rss)} of this machine"))
    return rows


def top_consumers(components: list[dict], limit: int = 5) -> list[tuple[str, float, float]]:
    """(name, bytes, share-of-this-project) for the biggest components.

    "What is eating my RAM" is the question the Resources view answers with a
    ring chart you have to hover; it deserves a plain ranked list too, because
    reading an ordered list of numbers is faster than comparing arc lengths.
    """
    rows = [(c["name"], float(c.get("rss") or 0)) for c in components if c.get("rss")]
    rows.sort(key=lambda row: row[1], reverse=True)
    total = sum(value for _name, value in rows) or 1.0
    return [(name, value, value * 100 / total) for name, value in rows[:limit]]


def group_of(comp: dict, mode: str) -> tuple[str, str]:
    """(sort key, heading) for a component under the chosen grouping.

    pitcrew's unit is `<role>-<app>` and the stream already carries `app` and
    `role` separately, so this never has to parse a component name.
    """
    if mode == "app":
        app = comp.get("app") or comp["name"]
        return app, app
    if mode == "role":
        role = comp.get("role")
        # Sorted so backends lead, which is the order they start in.
        return {"be": "0", "fe": "1"}.get(role, "2"), \
            {"be": "Backends", "fe": "Frontends"}.get(role, "Other")
    return "", "Components"


def hover_index(x: float, start_x: float, step: float, count: int) -> int:
    """Which sample the pointer is nearest, clamped into the series.

    Clamped rather than rejected: with a few minutes of history the line only
    occupies the right edge of the plot, and hovering the empty left half should
    read the first sample rather than showing nothing at all.
    """
    if count <= 0:
        return 0
    index = round((x - start_x) / step) if step else 0
    return max(0, min(index, count - 1))


def group_is_idle(comps: list[dict]) -> bool:
    """True when nothing in a group wants attention.

    `crashed` counts as wanting attention — folding away the one group that
    just died would be exactly backwards.
    """
    return not any(c.get("state") in ("up", "starting", "external", "crashed") for c in comps)


def share_slices(pairs) -> tuple[list[tuple[str, float]], float]:
    """(name, bytes) pairs as ring slices: biggest first, with the total.

    Components using nothing are dropped rather than drawn as zero-width
    slices, which would only add entries to the key for things that are not
    there.
    """
    rows = [(name, float(value)) for name, value in pairs if value]
    rows.sort(key=lambda row: row[1], reverse=True)
    return rows, sum(value for _name, value in rows)
