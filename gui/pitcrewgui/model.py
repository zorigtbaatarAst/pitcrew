"""Pure presentation logic: colours, formatting, and the rolling history.

No GTK and no OS calls, so every rule about how a number is rendered or a
component is grouped can be tested without a display."""

from __future__ import annotations

from collections import deque
from typing import NamedTuple

from gi.repository import GLib

# Eight lines that have to stay apart on one graph. A LIST, not a tuple, and
# every palette below is rebound rather than replaced, because `from .model
# import SERIES_COLORS` binds the object: switching theme has to change what is
# already imported, not what a fresh import would see. See theme.apply.
SERIES_COLORS = [
    "#3584e4", "#33d17a", "#f6d32d", "#ff7800",
    "#e01b24", "#9141ac", "#00b8c4", "#986a44",
]

# state -> (libadwaita css class for the badge, dot colour)
# Same ramp again: "up" is the green the verdict uses, "crashed" is its red.
# A component and the stack it belongs to should not disagree about what red is.
STATE_STYLE = {
    "up":       ("success",   "#3fb950"),
    "starting": ("warning",   "#d29922"),
    "crashed":  ("error",     "#f85149"),
    "external": ("accent",    "#3584e4"),
    # The same grey the meters call "calm" — see RAMP below. A stopped
    # component and a meter with nothing to say mean the same thing, and they
    # were two greys close enough to look like a rendering artefact and far
    # enough to be one more colour to explain.
    "down":     ("dim-label", "#6e7681"),
}
UNKNOWN_STYLE = ["dim-label", "#6e7681"]

# Worst first. The same order lib/05a-dashboard.sh's _state_rank uses, because
# the desktop app and the terminal dashboard putting "what needs you" in two
# different orders would be two answers to one question.
STATE_RANK = {"crashed": 0, "starting": 1, "up": 2, "external": 3, "down": 4}

def state_rank(comp: dict) -> int:
    return STATE_RANK.get(comp.get("state") or "", 5)

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

    For anything that IS parsed. Paths and app names come out of a config file,
    so a checkout at /srv/a&b renders as nothing at all — with a warning on
    stderr nobody is reading — unless it is escaped.

    What is parsed, verified on this libadwaita rather than assumed:

      - AdwPreferencesGroup titles and descriptions: ALWAYS. No use-markup
        property exists to turn it off, so a value interpolated into one has to
        come through here.
      - AdwActionRow / AdwExpanderRow title AND subtitle: only when use-markup
        is true, which is the default.

    So a row built with `use_markup=False` must NOT be escaped: both its title
    and its subtitle are taken literally, and an apostrophe put through here
    shows up on screen as `&apos;`. An earlier version of this docstring said
    use-markup covered the title only and that subtitles were parsed
    regardless; it was wrong, and the Tools dialog rendered `JVM&apos;s` in a
    subtitle until it was checked.
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

    def recolor(self, color: str) -> None:
        """Take a new colour without losing the history drawn in the old one."""
        self.color = color
        self.rgb = rgb(color)

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

# Colour always answers the same question — how worried should I be? — and
# these were two systems that disagreed about it: stock GtkLevelBar orange for
# the meters, red/amber/green for severity, so orange-at-32%-RAM and amber-
# warning came out nearly the same hue meaning entirely different things.
#
# One ramp, then, but split by what the colour is FOR — the same split
# lib/04-meters.sh draws with, and for the same reason:
#
#   RAMP   a verdict you READ: a state dot, a badge, the banner tint. Green,
#          amber and red are words here, and a palette's ok/warn/crit roles
#          are exactly the roles that carry those words.
#   LEVEL  a quantity you LOOK AT: the fill of a meter, the used arc of the
#          share ring, a cap mark. Drawn from the palette's own graph ramp,
#          which is the part of a theme that is genuinely its own — every
#          theme's ok/warn/crit is some green, some amber and some red, so
#          bars painted from those looked identical in every theme.
#
# Both still agree about LEVEL: same thresholds, same direction. Only the ink
# differs, and it differs because one of them is a picture.
RAMP = {
    "calm": "#6e7681",     # nothing to say — deliberately grey, not green
    "ok":   "#3fb950",
    "warn": "#d29922",
    "crit": "#f85149",
}
LEVEL = {
    "calm": "#6e7681",
    "warn": "#d29922",
    "crit": "#f85149",
}

# Where a meter stops being calm. Matched to lib/19-diag.sh's own thresholds so
# the bar turns amber on the frame the finding appears, not before or after.
METER_WARN_PCT = 70
METER_CRIT_PCT = 88


def meter_level(percent: float) -> str:
    """calm / warn / crit for a 0-100 resource reading."""
    if percent >= METER_CRIT_PCT:
        return "crit"
    if percent >= METER_WARN_PCT:
        return "warn"
    return "calm"


# The verdict lib/19-diag.sh reached, as something to paint with. Same three
# levels, same meaning, and the dot colours match the terminal dashboard's so
# the two do not disagree about what amber means.
VERDICT_STYLE = {
    "ok":   (RAMP["ok"],   "success"),
    "warn": (RAMP["warn"], "warning"),
    "crit": (RAMP["crit"], "error"),
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


def merge_findings(live: list[dict], deep: list[dict]) -> list[dict]:
    """Stream findings plus the ones only a full run can produce.

    The stream carries the cheap checks; `pitcrew diagnose` also runs the slow
    ones (anything that has to fork — see lib/19-diag.sh). Merged rather than
    replaced, and de-duplicated on (id, scope), so asking for a full run adds
    what it found without the list flickering between two versions of the same
    finding every time a frame arrives.
    """
    seen = {(f.get("id"), f.get("scope")) for f in live}
    extra = [f for f in deep if (f.get("id"), f.get("scope")) not in seen]
    rank = {"crit": 0, "warn": 1, "info": 2}
    return sorted(live + extra, key=lambda f: rank.get(f.get("severity"), 3))


# Verbs a finding's suggested command is allowed to invoke from the GUI.
#
# A finding's `fix` is a string, and a plugin can put anything in it. So it is
# never handed to a shell: it is split, checked against this list, and run as
# argv through the pitcrew binary or not at all. Anything else is shown as
# selectable text for the person to run themselves — which is the right answer
# for `pitcrew limit`, and the only safe one for whatever a plugin invents.
RUNNABLE_FIXES = {
    "logs":    ("Logs", False),
    "start":   ("Start", False),
    "restart": ("Restart", True),
    "stop":    ("Stop", True),
    "stale":   ("Restart stale", True),
}

def fix_action(fix: str) -> tuple[str, list[str], str, bool] | None:
    """(verb, args, button label, needs confirming) for a runnable fix, else None."""
    parts = (fix or "").split()
    if len(parts) < 2 or parts[0] != "pitcrew":
        return None
    verb, args = parts[1], parts[2:]
    known = RUNNABLE_FIXES.get(verb)
    if known is None:
        return None
    # Nothing that looks like an option or a path gets through: every verb here
    # takes component names, and `stale` takes exactly --restart.
    if verb == "stale":
        if args != ["--restart"]:
            return None
    elif not args or any(a.startswith("-") or "/" in a for a in args):
        return None
    label, destructive = known
    return verb, args, label, destructive


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
        # Named, not "THIS". A four-letter shout in a column of RAM/CPU/SWAP
        # reads as another system metric rather than as "your stack's share".
        rows.append(("Stack", project_rss * 100 / total, human_bytes(project_rss)))
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


class ShareSlice(NamedTuple):
    """One wedge of the memory ring.

    `limit` is the component's RAM cap (0 when uncapped) and `members` names
    what an `other` wedge folded up — both are empty for an ordinary wedge, and
    both are what the wedge can say about itself when it is pointed at.
    """

    name: str
    value: float
    limit: float = 0.0
    members: tuple[str, ...] = ()


OTHER_NAME = "other"

# A wedge thinner than this is a sliver: too thin to see, and — now that the
# ring is something you point at — too thin to hit. Folding the tail into one
# `other` wedge is both more honest and more clickable than drawing nine
# sub-pixel slices nobody can tell apart.
SHARE_MIN = 0.015
SHARE_KEEP = 9


def share_slices(triples, min_share: float = SHARE_MIN,
                 keep: int = SHARE_KEEP) -> tuple[list[ShareSlice], float]:
    """(name, bytes, limit) triples as ring wedges: biggest first, with the total.

    Components using nothing are dropped rather than drawn as zero-width
    wedges, which would only add entries to the key for things that are not
    there.
    """
    rows = [ShareSlice(name, float(value), float(limit or 0))
            for name, value, limit in triples if value]
    rows.sort(key=lambda row: row.value, reverse=True)
    total = sum(row.value for row in rows)
    if not total:
        return [], 0.0

    head: list[ShareSlice] = []
    tail: list[ShareSlice] = []
    for row in rows:
        if len(head) < keep - 1 and row.value / total >= min_share:
            head.append(row)
        else:
            tail.append(row)
    # "other (1)" tells you less than the component's own name, at the same
    # cost in wedges. Only fold when folding actually buys something.
    if len(tail) == 1:
        head.append(tail[0])
    elif tail:
        head.append(ShareSlice(OTHER_NAME, sum(row.value for row in tail), 0.0,
                               tuple(row.name for row in tail)))
    return head, total


# ── the Tools dialog ────────────────────────────────────────────────────────
#
# Ports and plugins used to reach the window as the CLI's own TEXT, dropped into
# a monospace box. That is a terminal pane wearing a dialog: lines wrapped mid
# token, the port clashes — the only actionable thing in it — buried at the
# bottom of a 180px scroller inside a scrolling page, and the plugins box
# teaching `diag_register`, which is something you type in a shell, in a window
# that has no shell.
#
# These turn the two JSON payloads into rows. Pure, so they are tested here
# rather than by looking at a screenshot.

def port_conflicts(state: dict | None) -> list[dict]:
    """Ports that two registered projects both claim, listed once each.

    A clash is symmetric and `pitcrew projects --json` reports it from BOTH
    sides — project A names B, and B names A — so a straight read shows every
    conflict twice and the count is double what it is. Deduped on the unordered
    pair, because "A vs B" and "B vs A" are one fact.

    This matters more than it looks: pitcrew decides a component is up from its
    port, so two projects sharing one means each reports the other's services as
    its own. It is the reason this dialog exists, and it used to be the last
    thing in a box nobody scrolled.
    """
    seen: set[tuple] = set()
    out: list[dict] = []
    for project in (state or {}).get("projects") or []:
        name = project.get("name") or "?"
        for clash in project.get("clashes") or []:
            mine = f"{name}/{clash.get('component') or '?'}"
            theirs = f"{clash.get('project') or '?'}/{clash.get('theirs') or '?'}"
            port = clash.get("port")
            key = (port, *sorted((mine, theirs)))
            if key in seen:
                continue
            seen.add(key)
            out.append({"port": port, "a": mine, "b": theirs})
    return sorted(out, key=lambda c: c["port"] or 0)


def port_rows(state: dict | None) -> list[dict]:
    """Every registered project and the ports it claims, ports ascending.

    `clashing` is the set of this project's ports that are contested, so a row
    can carry the warning next to the port itself instead of making someone
    cross-reference two lists.
    """
    out: list[dict] = []
    for project in (state or {}).get("projects") or []:
        ports = sorted((project.get("ports") or []), key=lambda p: p.get("port") or 0)
        out.append({
            "name": project.get("name") or "?",
            "current": bool(project.get("current")),
            "ports": ports,
            "clashing": {c.get("port") for c in (project.get("clashes") or [])},
        })
    return out


def plugin_rows(state: dict | None) -> list[dict]:
    """Loaded plugin files, and what each one actually registered.

    `summary` is deliberately the CLI's own judgement rather than a count: a
    plugin that loaded but registered NOTHING is the interesting case — it looks
    installed and does nothing — and "0 checks" states that far more quietly
    than saying it.
    """
    out: list[dict] = []
    for plugin in (state or {}).get("plugins") or []:
        checks = plugin.get("checks") or []
        names = [c.get("name") or "?" for c in checks]
        slow = [c.get("name") or "?" for c in checks if c.get("slow")]
        if not names:
            summary = "registered no checks"
        else:
            # The tier is why a check can be absent from the dashboard and
            # present in `diagnose`, so it is said on the row rather than
            # left for someone to wonder about.
            summary = ", ".join(
                f"{n} (on demand)" if n in slow else n for n in names)
        out.append({
            "file": plugin.get("file") or "?",
            "checks": names,
            "slow": slow,
            "empty": not names,
            "summary": summary,
        })
    return out
