"""Reusable pieces of chrome: the status dot, the graph, a component row."""

from __future__ import annotations

import math

import cairo
import gi
from gi.repository import Adw, Gdk, Gtk, Pango

# GtkSourceView where the machine has it, a plain text view where it does not.
# The config editor is the one place in this app where you read a FILE rather
# than a report, and a wall of one-colour YAML is what "unreadable" meant. It
# stays OPTIONAL: the typelib is one more package on seven package managers,
# and an install without it has to keep opening configs.
try:
    gi.require_version("GtkSource", "5")
    from gi.repository import GtkSource
except (ImportError, ValueError):          # not installed, or only version 4
    GtkSource = None

from .model import (
    LEVEL,
    RAMP,
    STATE_STYLE,
    UNKNOWN_STYLE,
    Series,
    ShareSlice,
    fix_action,
    hover_index,
    human_bytes,
    meter_level,
    nice_max,
    rgb,
)
from .model import plain as plain_text
from .settings import SETTINGS_BY_KEY


class Dot(Gtk.DrawingArea):
    """A filled circle in a series' colour — ties a row or legend to its line."""

    def __init__(self, color: str, size: int = 12):
        super().__init__()
        self._rgb = rgb(color)
        self.set_content_width(size)
        self.set_content_height(size)
        self.set_valign(Gtk.Align.CENTER)
        self.set_draw_func(self._draw)

    def set_color(self, color: str) -> None:
        self._rgb = rgb(color)
        self.queue_draw()

    def _draw(self, _area, cr, width, height) -> None:
        radius = min(width, height) / 2
        cr.set_source_rgb(*self._rgb)
        cr.arc(width / 2, height / 2, radius, 0, 2 * 3.141592653589793)
        cr.fill()

class Graph(Gtk.DrawingArea):
    """Multi-series line graph — the Resources-tab idea, drawn with Cairo.

    GTK ships no chart widget, so this is the same approach gnome-system-monitor
    takes: a DrawingArea and a draw func over a fixed-length history.
    """

    def __init__(self, metric: str, floor: float, fmt, percentage: bool = False):
        super().__init__()
        self._metric = metric        # "cpu" or "rss" — the Series attribute to plot
        self._floor = floor
        self._percentage = percentage          # smallest sensible axis ceiling
        self._fmt = fmt
        self._series: list[Series] = []
        self._history = SETTINGS_BY_KEY["history"].default
        self._window_label = ""
        self._forced_ceiling: float | None = None
        # Geometry from the last paint, so the pointer can be mapped back to a
        # sample without re-deriving the layout (which depends on the measured
        # label gutter, and would drift if computed twice).
        self._geom: dict | None = None
        self._hover_x: float | None = None
        self.set_content_height(180)
        self.set_hexpand(True)
        self.set_draw_func(self._draw)

        motion = Gtk.EventControllerMotion()
        motion.connect("motion", self._on_motion)
        motion.connect("leave", lambda _c: self._set_hover(None))
        self.add_controller(motion)

    def _on_motion(self, _controller, x: float, _y: float) -> None:
        self._set_hover(x)

    def _set_hover(self, x: float | None) -> None:
        if x != self._hover_x:
            self._hover_x = x
            self.queue_draw()

    def set_ceiling(self, ceiling: float | None) -> None:
        """Pin the axis maximum, or None to scale to the data.

        Pinning it to the machine's RAM is the only way to see how much of the
        box a stack actually costs: auto-scaled, 1.6 GiB and 16 GiB draw the
        identical picture, which is exactly the question being asked.
        """
        if ceiling != self._forced_ceiling:
            self._forced_ceiling = ceiling
            self.queue_draw()

    def set_series(self, series: list[Series], history: int) -> None:
        self._series = series
        self._history = max(2, history)
        self.queue_draw()

    def set_window(self, label: str) -> None:
        """The time span the plot covers, e.g. "last 4 min"."""
        if label != self._window_label:
            self._window_label = label
            self.queue_draw()

    def _draw(self, _area, cr, width, height) -> None:
        fg = self.get_color()        # follows the theme; grid is the same ink, faded
        cr.select_font_face("sans-serif")
        cr.set_font_size(10)

        if self._forced_ceiling:
            ceiling = self._forced_ceiling
        else:
            peak = max((max(getattr(s, self._metric), default=0.0) for s in self._series), default=0.0)
            ceiling = nice_max(peak, self._floor)
        # A percentage axis stops at 100. nice_max rounds UP to a whole step, so
        # a CPU chart with a floor of 100 came out labelled 120% / 90% / 60% —
        # a quarter of the plot was headroom that cannot exist.
        if self._percentage:
            ceiling = min(ceiling, 100.0)
        labels = [self._fmt(ceiling * (4 - i) / 4) for i in range(5)]

        # The gutter is measured, not guessed: "858.3 MiB" is far wider than
        # "100%", and a fixed padding silently clipped the leading digit off
        # every memory label.
        gutter = max(cr.text_extents(text).width for text in labels)
        pad_left, pad_right, pad_top, pad_bottom = gutter + 16, 8, 10, 18
        plot_w = width - pad_left - pad_right
        plot_h = height - pad_top - pad_bottom
        if plot_w <= 0 or plot_h <= 0:
            return

        # Two samples is the minimum that can be a line. Until then, say what is
        # happening — an empty grid with axis labels looks like a chart that has
        # given up, and CPU is a delta so the first frame NEVER has a value.
        if not any(len(getattr(s, self._metric)) >= 2 for s in self._series):
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.45)
            message = ("collecting…" if self._series
                       else "nothing running to plot")
            extents = cr.text_extents(message)
            cr.move_to(pad_left + (plot_w - extents.width) / 2, pad_top + plot_h / 2)
            cr.show_text(message)
            return

        self._geom = {"pad_left": pad_left, "pad_top": pad_top,
                      "plot_w": plot_w, "plot_h": plot_h, "ceiling": ceiling}

        cr.set_line_width(1)
        for i, label in enumerate(labels):
            y = pad_top + plot_h * i / 4
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.10)
            cr.move_to(pad_left, y)
            cr.line_to(pad_left + plot_w, y)
            cr.stroke()
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.45)
            cr.move_to(pad_left - 8 - cr.text_extents(label).width, y + 3)
            cr.show_text(label)

        for series in self._series:
            self._draw_series(cr, series, pad_left, pad_top, plot_w, plot_h, ceiling)
        # How much time this is. Without it the plot is a shape with no scale:
        # the same squiggle means something different over 30 seconds and over
        # ten minutes, and nothing on screen said which.
        if self._window_label:
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.40)
            extents = cr.text_extents(self._window_label)
            cr.move_to(pad_left + plot_w - extents.width, height - 5)
            cr.show_text(self._window_label)

        self._draw_hover(cr, fg, pad_left, pad_top, plot_w, plot_h, ceiling)

    def _draw_series(self, cr, series, pad_left, pad_top, plot_w, plot_h, ceiling) -> None:
        points = getattr(series, self._metric)
        if len(points) < 2:
            return
        # The history is right-anchored: a series that just appeared draws from
        # the right edge inward rather than stretching across the whole window
        # and implying data it does not have.
        step = plot_w / (self._history - 1)
        start_x = pad_left + plot_w - step * (len(points) - 1)
            # Bound as defaults: a closure over the loop variables would be
        # re-read on the next series, which ruff is right to object to.
        def plot(index, value, _x0=start_x, _dx=step):
            return (_x0 + _dx * index,
                    pad_top + plot_h * (1 - min(value / ceiling, 1.0)))

        # Filled, then stroked. A 2px line at 4% CPU on a dark ground is a
        # scratch you have to hunt for; the area under it is what makes the
        # shape readable at a glance, and what tells two overlapping series
        # apart. Faint enough to stack several without turning to mud.
        cr.set_source_rgba(*series.rgb, 0.13)
        cr.move_to(*plot(0, points[0]))
        for index, value in enumerate(points):
            cr.line_to(*plot(index, value))
        cr.line_to(start_x + step * (len(points) - 1), pad_top + plot_h)
        cr.line_to(start_x, pad_top + plot_h)
        cr.close_path()
        cr.fill()

        cr.set_source_rgb(*series.rgb)
        cr.set_line_width(2)
        cr.set_line_join(cairo.LINE_JOIN_ROUND)
        for index, value in enumerate(points):
            cr.line_to(*plot(index, value)) if index else cr.move_to(*plot(index, value))
        cr.stroke()

    def _draw_hover(self, cr, fg, pad_left, pad_top, plot_w, plot_h, ceiling) -> None:
        """A crosshair and every series' value where the pointer is.

        A spike you can see but not measure is half an answer: the graph shows
        that something happened, and the readout says what and how much.
        """
        if self._hover_x is None or not self._series:
            return
        x = min(max(self._hover_x, pad_left), pad_left + plot_w)

        readings = []
        for series in self._series:
            points = getattr(series, self._metric)
            if len(points) < 2:
                continue
            step = plot_w / (self._history - 1)
            start_x = pad_left + plot_w - step * (len(points) - 1)
            index = hover_index(x, start_x, step, len(points))
            value = points[index]
            readings.append((series, value,
                             start_x + step * index,
                             pad_top + plot_h * (1 - min(value / ceiling, 1.0))))
        if not readings:
            return

        line_x = readings[0][2]
        cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.35)
        cr.set_line_width(1)
        cr.move_to(line_x, pad_top)
        cr.line_to(line_x, pad_top + plot_h)
        cr.stroke()
        for series, _value, px, py in readings:
            cr.set_source_rgb(*series.rgb)
            cr.arc(px, py, 3, 0, 2 * 3.141592653589793)
            cr.fill()

        # The panel flips to the other side of the crosshair near the right
        # edge, so the numbers never fall off the widget.
        cr.select_font_face("sans-serif")
        cr.set_font_size(11)
        rows = [(s, f"{s.name}  {self._fmt(v)}") for s, v, _px, _py in readings]
        text_w = max(cr.text_extents(t).width for _s, t in rows)
        box_w, box_h = text_w + 26, len(rows) * 15 + 10
        box_x = line_x + 10 if line_x + 10 + box_w < pad_left + plot_w else line_x - 10 - box_w
        box_y = min(pad_top + 4, pad_top + plot_h - box_h)

        cr.set_source_rgba(0, 0, 0, 0.72)
        cr.rectangle(box_x, box_y, box_w, box_h)
        cr.fill()
        for row, (series, text) in enumerate(rows):
            y = box_y + 18 + row * 15
            cr.set_source_rgb(*series.rgb)
            cr.arc(box_x + 9, y - 4, 3.5, 0, 2 * 3.141592653589793)
            cr.fill()
            cr.set_source_rgb(0.92, 0.92, 0.92)
            cr.move_to(box_x + 18, y)
            cr.show_text(text)

def human_age(seconds: float | None) -> str:
    """Compact uptime: 45s, 12m, 2h14m, 3d4h."""
    if not seconds or seconds < 0:
        return ""
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        hours, rest = divmod(seconds, 3600)
        return f"{hours}h{rest // 60:02d}m"
    days, rest = divmod(seconds, 86400)
    return f"{days}d{rest // 3600:02d}h"


class ShareChart(Gtk.DrawingArea):
    """Who is eating the stack, as a share of it — and of the machine.

    The line graphs answer "is this climbing"; they are bad at "which of these
    twelve is the problem", because a 3 GiB frontend and a 300 MiB cron worker
    are both just lines. A ring answers that in one look, and the wedges reuse
    the series colours so it reads against the legend and the row sparklines
    without a second key.

    Two rings, because "share of memory" is two questions and answering only
    the first one is what made the old chart a decoration. The thin outer track
    is the MACHINE, filled to what this project costs it; the donut inside it is
    how that cost splits between components. A stack that is 4% of the box and a
    stack that is 80% of it drew the identical picture before.

    Everything here is pointable. A wedge you can see but not interrogate is
    half an answer — the same reason Graph grew a crosshair — so hovering lifts
    a wedge and puts its numbers in the hole, clicking pins it, double-click or
    Enter opens the component, and the whole widget is keyboard-reachable.
    """

    TRACK_GAP = 13        # between the machine track and the breakdown donut
    TRACK_W = 4
    LIFT = 4              # how far the pointed-at wedge pops out — must stay
                          # inside TRACK_GAP or it paints over the track
    LEGEND_PITCH = 18
    LEGEND_MIN_W = 168    # under this there is no room for a key beside the ring
    DIM = 0.34            # everything that is not the pointed-at wedge

    def __init__(self, on_activate=None):
        super().__init__()
        self._slices: list[ShareSlice] = []
        self._colors: dict[str, tuple[float, float, float]] = {}
        self._total = 0.0
        self._machine = 0.0
        self._on_activate = on_activate
        # Geometry from the last paint, so the pointer can be mapped back to a
        # wedge without re-deriving a layout that depends on the measured width.
        self._geom: dict | None = None
        self._hover: int | None = None
        self._selected: str | None = None      # by NAME: a frame can reorder wedges
        self.set_content_height(210)
        self.set_hexpand(True)
        self.set_draw_func(self._draw)
        self.set_focusable(True)
        self.set_has_tooltip(True)
        self.connect("query-tooltip", self._on_tooltip)

        motion = Gtk.EventControllerMotion()
        motion.connect("motion", lambda _c, x, y: self._set_hover(self._at(x, y)))
        motion.connect("leave", lambda _c: self._set_hover(None))
        self.add_controller(motion)

        click = Gtk.GestureClick()
        click.connect("pressed", self._on_click)
        self.add_controller(click)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._on_key)
        self.add_controller(keys)

    # ── state ───────────────────────────────────────────────────────────────
    def set_slices(self, slices, total: float, colors: dict[str, str],
                   machine_total: float = 0.0) -> None:
        self._slices = list(slices)
        self._total = total
        self._machine = machine_total or 0.0
        self._colors = {name: rgb(value) for name, value in colors.items()}
        # A pinned wedge that stopped existing (the component was stopped, or
        # fell into `other`) has to let go, or the hole reads out a component
        # that is no longer on the chart.
        if self._selected is not None and self._index_of(self._selected) is None:
            self._selected = None
        self.queue_draw()

    def _index_of(self, name: str | None) -> int | None:
        for index, slice_ in enumerate(self._slices):
            if slice_.name == name:
                return index
        return None

    def _active(self) -> int | None:
        """The wedge being read: what the pointer is on, else what is pinned."""
        return self._hover if self._hover is not None else self._index_of(self._selected)

    def _colour(self, name: str) -> tuple[float, float, float]:
        # `other` has no series and must not borrow one's colour: it is the
        # absence of a distinction, and grey is what that looks like.
        return self._colors.get(name) or rgb(RAMP["calm"])

    # ── input ───────────────────────────────────────────────────────────────
    def _set_hover(self, index: int | None) -> None:
        if index == self._hover:
            return
        self._hover = index
        self.set_cursor_from_name("pointer" if index is not None else None)
        self.queue_draw()

    def _select(self, name: str | None) -> None:
        if name != self._selected:
            self._selected = name
            self.queue_draw()

    def _at(self, x: float, y: float) -> int | None:
        """Which wedge is under (x, y) — in the ring or in the key beside it."""
        geom = self._geom
        if geom is None:
            return None
        for index, (top, bottom) in enumerate(geom["rows"]):
            if top <= y < bottom and x >= geom["legend_x"] - 10:
                return index
        dx, dy = x - geom["cx"], y - geom["cy"]
        radius = math.hypot(dx, dy)
        if not geom["inner"] <= radius <= geom["outer"] + self.LIFT:
            return None
        # atan2 is zero at three o'clock and grows anticlockwise in maths but
        # clockwise on screen, where y points down — which is the direction the
        # wedges are laid out in. The quarter turn moves zero to twelve.
        angle = (math.atan2(dy, dx) + math.tau / 4) % math.tau
        swept = 0.0
        for index, slice_ in enumerate(self._slices):
            swept += math.tau * slice_.value / self._total
            if angle < swept:
                return index
        return None

    def _on_click(self, _gesture, n_press: int, x: float, y: float) -> None:
        self.grab_focus()
        index = self._at(x, y)
        if index is None:
            self._select(None)
            return
        slice_ = self._slices[index]
        # A second click OPENS rather than re-pins: pinning is how you read the
        # numbers, opening is what you do about them, and they should not be
        # the same gesture.
        if n_press >= 2:
            self._activate(slice_)
            return
        self._select(None if self._selected == slice_.name else slice_.name)

    def _on_key(self, _controller, keyval, _keycode, _state) -> bool:
        if not self._slices:
            return False
        index = self._index_of(self._selected)
        if keyval in (Gdk.KEY_Right, Gdk.KEY_Down):
            self._select(self._slices[0 if index is None else
                                      (index + 1) % len(self._slices)].name)
            return True
        if keyval in (Gdk.KEY_Left, Gdk.KEY_Up):
            self._select(self._slices[-1 if index is None else
                                      (index - 1) % len(self._slices)].name)
            return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
            if index is not None:
                self._activate(self._slices[index])
            return True
        if keyval == Gdk.KEY_Escape:
            self._select(None)
            return True
        return False

    def _activate(self, slice_: ShareSlice) -> None:
        # `other` is several components at once; there is no one detail view to
        # open for it, and guessing which of them you meant would be worse than
        # doing nothing.
        if slice_.members or self._on_activate is None:
            return
        self._on_activate(slice_.name)

    def _on_tooltip(self, _widget, x: int, y: int, keyboard: bool, tooltip) -> bool:
        index = self._index_of(self._selected) if keyboard else self._at(x, y)
        if index is None:
            return False
        slice_ = self._slices[index]
        lines = [f"<b>{plain_text(slice_.name)}</b>",
                 f"{human_bytes(slice_.value)}   "
                 f"{slice_.value / self._total * 100:.1f}% of the project"]
        if self._machine:
            lines.append(f"{slice_.value / self._machine * 100:.1f}% of this machine")
        if slice_.limit:
            lines.append(f"{human_bytes(slice_.value)} of {human_bytes(slice_.limit)} "
                         f"cap  ({slice_.value / slice_.limit * 100:.0f}%)")
        if slice_.members:
            lines.append(plain_text(", ".join(slice_.members)))
        tooltip.set_markup("\n".join(lines))
        return True

    # ── painting ────────────────────────────────────────────────────────────
    def _draw(self, _area, cr, width, height) -> None:
        fg = self.get_color()
        cr.select_font_face("sans-serif")
        cr.set_font_size(11)

        if not self._slices or self._total <= 0:
            self._geom = None
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.45)
            text = "nothing running"
            cr.move_to((width - cr.text_extents(text).width) / 2, height / 2)
            cr.show_text(text)
            return

        size = min(height - 10, 200)
        # Below this the hole cannot hold a readout and the wedges cannot be
        # pointed at, so there is nothing to draw that would be worth reading.
        # Same early return Graph makes when its plot area collapses.
        if size < 72:
            self._geom = None
            return
        track_r = size / 2 - 1
        outer = track_r - self.TRACK_GAP
        inner = outer * 0.60
        cx, cy = 14 + track_r, height / 2

        # The key needs a readable width or it is worse than no key. Where the
        # widget cannot give it one, the ring takes the whole width instead —
        # the series legend under the graphs still names everything.
        legend_x = cx + track_r + 24
        if width - legend_x < self.LEGEND_MIN_W:
            legend_x = 0.0
            cx = width / 2

        active = self._active()
        self._draw_machine_track(cr, fg, cx, cy, track_r)
        self._draw_wedges(cr, cx, cy, outer, inner, active)
        self._draw_hole(cr, fg, cx, cy, inner, active)
        rows = self._draw_legend(cr, fg, legend_x, cy, width, height, active) if legend_x else []
        self._geom = {"cx": cx, "cy": cy, "inner": inner, "outer": outer,
                      "legend_x": legend_x, "rows": rows}

    def _draw_machine_track(self, cr, fg, cx: float, cy: float, radius: float) -> None:
        """The project against the box it is running on, as a thin outer ring.

        Without it the donut is a proportion with no magnitude: the same
        picture for a stack costing 4% of the machine and one costing 80%.
        """
        if not self._machine:
            return
        share = min(self._total / self._machine, 1.0)
        cr.set_line_width(self.TRACK_W)
        cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.13)
        cr.arc(cx, cy, radius, 0, math.tau)
        cr.stroke()
        # Heavier than the empty track it sits in. `calm` is a grey by design,
        # so hue alone cannot be what separates "used" from "not used" here.
        cr.set_line_width(self.TRACK_W + 2)
        # The same ramp as every other meter in the app, so the colour of this
        # arc means what amber means everywhere else — and `calm` is grey, not
        # green: a stack using a tenth of the machine has nothing to say.
        cr.set_source_rgb(*rgb(LEVEL[meter_level(share * 100)]))
        cr.arc(cx, cy, radius, -math.tau / 4, -math.tau / 4 + math.tau * share)
        cr.stroke()

    def _draw_wedges(self, cr, cx: float, cy: float, outer: float, inner: float,
                     active: int | None) -> None:
        angle = -math.tau / 4                  # start at twelve o'clock
        for index, slice_ in enumerate(self._slices):
            sweep = math.tau * slice_.value / self._total
            lift = self.LIFT if index == active else 0
            red, green, blue = self._colour(slice_.name)
            alpha = 1.0 if active is None or index == active else self.DIM
            cr.set_source_rgba(red, green, blue, alpha)
            cr.move_to(cx, cy)
            cr.arc(cx, cy, outer + lift, angle, angle + sweep)
            cr.close_path()
            cr.fill()
            angle += sweep
        # Punch the middle out AFTER the wedges: a ring reads as proportion,
        # where a full pie invites reading the radius as a magnitude too.
        # CLEAR leaves real transparency, so the hole shows the themed window
        # behind it and stays right in both light and dark.
        cr.set_operator(cairo.OPERATOR_CLEAR)
        cr.arc(cx, cy, inner, 0, math.tau)
        cr.fill()
        cr.set_operator(cairo.OPERATOR_OVER)

    def _draw_hole(self, cr, fg, cx: float, cy: float, inner: float,
                   active: int | None) -> None:
        """The readout. The total, until you point at something."""
        if active is None:
            head, sub = human_bytes(self._total), ""
            if self._machine:
                sub = f"{self._total / self._machine * 100:.0f}% of machine"
        else:
            slice_ = self._slices[active]
            head = human_bytes(slice_.value)
            sub = f"{slice_.value / self._total * 100:.0f}%"

        if active is not None:
            name = self._fit(cr, self._slices[active].name, inner * 1.7, 11)
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.60)
            cr.move_to(cx - cr.text_extents(name).width / 2, cy - 14)
            cr.show_text(name)

        cr.set_font_size(15)
        cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.95)
        cr.move_to(cx - cr.text_extents(head).width / 2, cy + 4)
        cr.show_text(head)
        if sub:
            cr.set_font_size(10)
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.50)
            cr.move_to(cx - cr.text_extents(sub).width / 2, cy + 19)
            cr.show_text(sub)
        cr.set_font_size(11)

    def _draw_legend(self, cr, fg, left: float, cy: float, width: float,
                     height: float, active: int | None) -> list[tuple[float, float]]:
        """The key beside the ring, and the hit bands that make it pointable.

        Beside the ring rather than labels on it: twelve components means twelve
        wedges, and callouts on thin ones overlap into mush.
        """
        fits = max(1, int((height - 12) // self.LEGEND_PITCH))
        shown = self._slices[:fits]
        top = cy - len(shown) * self.LEGEND_PITCH / 2
        rows: list[tuple[float, float]] = []
        for index, slice_ in enumerate(shown):
            band_top = top + index * self.LEGEND_PITCH
            baseline = band_top + self.LEGEND_PITCH - 5
            rows.append((band_top, band_top + self.LEGEND_PITCH))

            if index == active:
                cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.08)
                cr.rectangle(left - 8, band_top, width - left + 2, self.LEGEND_PITCH)
                cr.fill()

            fade = 1.0 if active is None or index == active else 0.55
            red, green, blue = self._colour(slice_.name)
            cr.set_source_rgba(red, green, blue, fade)
            cr.arc(left, baseline - 4, 4, 0, math.tau)
            cr.fill()

            # Figures right-aligned against the edge and the name clipped to
            # what is left: a long component name must not push the number it
            # is there to carry off the widget.
            figures = (f"{human_bytes(slice_.value)}   "
                       f"{slice_.value / self._total * 100:.0f}%")
            warn = self._cap_level(slice_)
            right = width - 6
            if warn:
                self._cap_mark(cr, right - 8, baseline - 4, LEVEL[warn])
                right -= 16
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.85 * fade)
            figures_w = cr.text_extents(figures).width
            cr.move_to(right - figures_w, baseline)
            cr.show_text(figures)

            name = self._fit(cr, slice_.name, right - figures_w - left - 22, 11)
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.85 * fade)
            cr.move_to(left + 12, baseline)
            cr.show_text(name)
        return rows

    @staticmethod
    def _cap_mark(cr, cx: float, cy: float, color: str) -> None:
        """A small triangle: this component is pressing against its RAM cap.

        Drawn as a path rather than a glyph. Cairo's toy font API has no font
        fallback, so `▲` is a tofu box on any box whose default sans lacks it —
        which turned the one warning on this chart into a rendering artefact.
        """
        cr.set_source_rgb(*rgb(color))
        cr.move_to(cx, cy - 4.5)
        cr.line_to(cx + 4.5, cy + 3.5)
        cr.line_to(cx - 4.5, cy + 3.5)
        cr.close_path()
        cr.fill()

    @staticmethod
    def _cap_level(slice_: ShareSlice) -> str:
        """warn/crit when a wedge is pressing against its own RAM cap, else ""."""
        if not slice_.limit:
            return ""
        level = meter_level(slice_.value / slice_.limit * 100)
        return "" if level == "calm" else level

    @staticmethod
    def _fit(cr, text: str, room: float, size: float) -> str:
        """`text`, ellipsised to `room` pixels. Cairo will not do it for us."""
        cr.set_font_size(size)
        if room <= 0:
            return ""
        if cr.text_extents(text).width <= room:
            return text
        while text and cr.text_extents(text + "…").width > room:
            text = text[:-1]
        return text + "…" if text else ""


class SegmentedControl(Gtk.Box):
    """A row of linked toggle buttons where exactly one is active.

    This is `AdwToggleGroup`, written out. That widget arrived in libadwaita
    1.7 and Ubuntu 24.04 LTS — the current LTS — ships 1.5, where constructing
    it aborts the process. Two convenience widgets are not worth refusing to
    start on the distribution most people are running, and everything else in
    this app works on 1.5.

    Same tiny surface the ToggleGroup calls used: add_option, get_active_name,
    set_active_name, and one callback.
    """

    def __init__(self, on_change=None, **kwargs) -> None:
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, **kwargs)
        self.add_css_class("linked")
        self._on_change = on_change
        self._buttons: dict[str, Gtk.ToggleButton] = {}
        self._active: str | None = None
        self._settling = False

    def add_option(self, name: str, label: str) -> None:
        button = Gtk.ToggleButton(label=label)
        button.connect("toggled", self._toggled, name)
        self._buttons[name] = button
        self.append(button)
        if self._active is None:
            self.set_active_name(name)

    def get_active_name(self) -> str | None:
        return self._active

    def set_active_name(self, name: str) -> None:
        if name not in self._buttons or name == self._active:
            return
        self._apply(name)
        if self._on_change is not None:
            self._on_change()

    def _toggled(self, button: Gtk.ToggleButton, name: str) -> None:
        if self._settling:
            return
        if not button.get_active():
            # Clicking the active one again must not leave the group with
            # nothing selected — there is no "no filter" state to fall into.
            self._settling = True
            button.set_active(True)
            self._settling = False
            return
        self._apply(name)
        if self._on_change is not None:
            self._on_change()

    def _apply(self, name: str) -> None:
        self._settling = True
        for other, button in self._buttons.items():
            button.set_active(other == name)
        self._active = name
        self._settling = False


class Bar(Gtk.DrawingArea):
    """A flat rounded progress bar drawn to the shared ramp.

    Not a GtkLevelBar: that one is themed orange whatever it is measuring, and
    its three offset classes are styled by the platform rather than by us — so
    a meter at 32% and a warning badge came out nearly the same colour while
    meaning entirely different things.
    """

    HEIGHT = 8

    def __init__(self, expand: bool = False) -> None:
        # Opt in to expanding. As a meter it should fill its column; as a cell
        # in a row it must not, or it pushes the figure it belongs to across
        # the window and the two stop reading as one thing.
        super().__init__(hexpand=expand, valign=Gtk.Align.CENTER,
                         content_height=self.HEIGHT)
        self._fraction = 0.0
        self._color = RAMP["calm"]
        self.set_draw_func(self._draw)

    def set(self, fraction: float, color: str) -> None:
        self._fraction = max(0.0, min(1.0, float(fraction)))
        self._color = color
        self.queue_draw()

    def _draw(self, _area, cr, width, height) -> None:
        radius = height / 2
        self._rounded(cr, 0, 0, width, height, radius)
        cr.set_source_rgba(*rgb(RAMP["calm"]), 0.16)
        cr.fill()
        filled = width * self._fraction
        if filled < 1:
            return
        # Never narrower than its own cap radius, or 1% renders as a sliver
        # with the wrong shape.
        self._rounded(cr, 0, 0, max(filled, height), height, radius)
        cr.set_source_rgb(*rgb(self._color))
        cr.fill()

    @staticmethod
    def _rounded(cr, x, y, w, h, r) -> None:
        cr.new_sub_path()
        cr.arc(x + w - r, y + r, r, -1.5708, 1.5708)
        cr.arc(x + r, y + h - r, r, 1.5708, 4.7124)
        cr.close_path()


class Meter(Gtk.Box):
    """One labelled resource bar: what it is, how full, and the real figures.

    A bar on its own is a proportion with no units, and a pair of figures on
    their own makes you do the division. Both, on one line, is the whole point:
    the bar is for the glance and the numbers are for the decision.
    """

    def __init__(self, label: str) -> None:
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        name = Gtk.Label(label=label, xalign=0, width_chars=4)
        name.add_css_class("caption")
        name.add_css_class("dim-label")
        self.append(name)

        self._bar = Bar(expand=True)
        self.append(self._bar)

        self._value = Gtk.Label(xalign=1, width_chars=18)
        self._value.add_css_class("caption")
        self._value.add_css_class("numeric")
        self.append(self._value)

    def set(self, percent: float, text: str) -> None:
        self._bar.set(percent / 100.0, LEVEL[meter_level(percent)])
        self._value.set_text(text)


class FindingRow(Adw.ActionRow):
    """One diagnostic finding, exactly as lib/19-diag.sh reported it.

    Deliberately dumb: the severity, the title, the evidence and the suggested
    command all arrive in the stream. Nothing here decides what is wrong or how
    bad it is — that judgement lives in one place, in the shell, so the desktop
    app and the terminal dashboard can never disagree about it.
    """

    ICONS = {
        "crit": ("dialog-error-symbolic", "error"),
        "warn": ("dialog-warning-symbolic", "warning"),
        "info": ("dialog-information-symbolic", "accent"),
    }

    def __init__(self, finding: dict, on_logs=None, on_run=None) -> None:
        super().__init__(title=plain_text(finding.get("title", "")),
                         subtitle=plain_text(finding.get("detail", "")),
                         use_markup=False)
        severity = finding.get("severity", "info")
        icon_name, css = self.ICONS.get(severity, self.ICONS["info"])
        icon = Gtk.Image(icon_name=icon_name, valign=Gtk.Align.CENTER)
        icon.add_css_class(css)
        self.add_prefix(icon)
        # A rail down the left edge, so a column of these is scannable by
        # severity without reading a single word of it.
        self.add_css_class("finding")
        self.add_css_class(f"finding-{severity}")

        # A finding that suggests a command is one click from that command —
        # printing it for someone to retype in another window would be a strange
        # thing for a GUI to do. But only for verbs the GUI is willing to run as
        # argv (see fix_action); anything else stays selectable text, because a
        # `fix` string can come from a plugin and is not a shell script.
        fix = finding.get("fix") or ""
        action = fix_action(fix)
        if action and action[0] == "logs" and on_logs is not None:
            self._button("Logs", lambda: on_logs(action[1][0], False), False)
        elif action and on_run is not None:
            verb, args, label, destructive = action
            self._button(label, lambda: on_run(verb, args, destructive), destructive)
        elif fix:
            # Monospace, because it is a command to copy rather than a control.
            hint = Gtk.Label(label=fix, valign=Gtk.Align.CENTER, selectable=True)
            hint.add_css_class("caption")
            hint.add_css_class("dim-label")
            hint.add_css_class("monospace")
            self.add_suffix(hint)

    def _button(self, label: str, action, destructive: bool) -> None:
        # Framed, not flat. Next to it sits a suggested command that is NOT
        # clickable (`pitcrew limit …`, plain text you copy), and as flat text
        # the two were indistinguishable — the only way to find out which was
        # which was to click one.
        button = Gtk.Button(label=label, valign=Gtk.Align.CENTER)
        button.add_css_class("pill")
        if destructive:
            button.add_css_class("destructive-action")
        button.connect("clicked", lambda _b: action())
        self.add_suffix(button)


class ProcessTree(Gtk.Box):
    """A component's process tree: pid, command, memory, cpu — biggest first.

    The terminal dashboard has had this behind Enter since the beginning and the
    desktop app had nothing, which mattered most for exactly the case it exists
    for: a `gradle bootRun` is a wrapper that forks a daemon that forks the
    application, so the pid pitcrew launched is almost never the one holding the
    memory.

    The rows come from the state stream (`components[].processes`). Nothing here
    runs `ps` — that is the GUI's side of the bargain with the CLI.
    """

    def __init__(self) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self._rows: dict[int, Gtk.Widget] = {}
        self._empty = Gtk.Label(label="Not running", xalign=0, margin_top=6,
                                margin_bottom=6, margin_start=12)
        self._empty.add_css_class("dim-label")
        self._empty.add_css_class("caption")
        self.append(self._empty)

    def set_processes(self, procs: list[dict]) -> None:
        for row in self._rows.values():
            self.remove(row)
        self._rows.clear()
        self._empty.set_visible(not procs)
        if not procs:
            return
        total = sum(p.get("rss") or 0 for p in procs) or 1
        for index, proc in enumerate(procs):
            self.append(self._row(proc, index == len(procs) - 1, total))

    def _row(self, proc: dict, last: bool, total: float) -> Gtk.Widget:
        box = Gtk.Box(spacing=8, margin_top=3, margin_bottom=3,
                      margin_start=12, margin_end=6)

        branch = Gtk.Label(label="└" if last else "├", xalign=0)
        branch.add_css_class("dim-label")
        box.append(branch)

        pid = Gtk.Label(label=str(proc.get("pid") or "?"), xalign=1, width_chars=7)
        pid.add_css_class("caption")
        pid.add_css_class("numeric")
        pid.add_css_class("dim-label")
        box.append(pid)

        name = Gtk.Label(label=proc.get("cmd") or "?", xalign=0, hexpand=True,
                         ellipsize=Pango.EllipsizeMode.MIDDLE)
        name.add_css_class("caption")
        box.append(name)

        # A share bar, not a second copy of the figure: the question this view
        # answers is which ONE of these is the service, and a proportion answers
        # it faster than four numbers you have to compare.
        share = Gtk.ProgressBar(fraction=(proc.get("rss") or 0) / total,
                                valign=Gtk.Align.CENTER, hexpand=False)
        share.set_size_request(60, -1)
        box.append(share)

        rss = Gtk.Label(label=human_bytes(proc.get("rss")), xalign=1, width_chars=10)
        rss.add_css_class("caption")
        rss.add_css_class("numeric")
        box.append(rss)

        cpu = proc.get("cpu")
        cpu_label = Gtk.Label(label="—" if cpu is None else f"{cpu}%", xalign=1, width_chars=5)
        cpu_label.add_css_class("caption")
        cpu_label.add_css_class("numeric")
        cpu_label.add_css_class("dim-label")
        box.append(cpu_label)

        self._rows[proc.get("pid") or id(proc)] = box
        return box


class ComponentRow(Adw.ActionRow):
    """One component: state, what it is using, and the buttons that act on it."""

    # The column geometry, in one place, because a header that names these has
    # to line up with them exactly — and a header whose widths are guessed
    # separately is worse than none at all.
    W_BADGE, W_MEM, W_CPU, W_PORT, W_AGE, W_NOTE = 8, 16, 5, 7, 6, 10
    W_CAP = 58          # pixels, not characters: it is a bar
    W_ACTIONS = 11      # the icon buttons at the end, in characters

    @classmethod
    def header(cls) -> Adw.ActionRow:
        """A row of column names built from the same geometry as a real row.

        An AdwActionRow, not a Box, for the same reason: its internal padding
        and suffix spacing are what the rows below use, and reproducing those
        by hand is how a header ends up two columns out of step.
        """
        row = Adw.ActionRow(title="component", use_markup=False)
        row.add_css_class("table-head")
        row.set_activatable(False)
        for text, chars in (("state", cls.W_BADGE), ("memory / cap", cls.W_MEM),
                            ("", cls.W_CAP // 8), ("cpu", cls.W_CPU),
                            ("port", cls.W_PORT), ("up", cls.W_AGE),
                            ("", cls.W_NOTE), ("", cls.W_ACTIONS)):
            label = Gtk.Label(label=text, valign=Gtk.Align.CENTER, width_chars=chars,
                              xalign=0 if text == "state" else 1)
            row.add_suffix(label)
        return row

    def __init__(self, name: str, color: str, on_action, on_show_logs=None) -> None:
        # Component names and ports come from a config file, not from us.
        super().__init__(title=name, use_markup=False)
        self._name = name
        self._on_action = on_action
        self._on_show_logs = on_show_logs

        # STATE, not the series colour. It used to be the latter — the colour
        # this component's line has on the Resources graph — which meant a dot
        # in a status list was showing something that has no meaning on this
        # tab, and never changed when the service crashed. A green dot beside a
        # dead backend is worse than no dot.
        self._dot = Dot(STATE_STYLE["down"][1])
        self._series_color = color
        self.add_prefix(self._dot)

        # Aligned columns, not a subtitle. `27.4 MiB / 8.0 GiB · cpu — · :19801
        # · up 8s` at one weight is a sentence you have to read; the same
        # figures in fixed columns are a table you scan, and the outlier in a
        # stack of twelve is visible without reading any of it.
        # The badge first, so it packs immediately after the title. State was
        # appearing twice at opposite ends of the row — a dot on the left and
        # the word on the right, with six columns of figures between them.
        self._badge = Gtk.Label(valign=Gtk.Align.CENTER, xalign=0, width_chars=self.W_BADGE)
        self._badge.add_css_class("caption")
        self._badge_class = ""
        self.add_suffix(self._badge)

        self._mem = self._column(self.W_MEM)
        self._cap = Bar()
        self._cap.set_size_request(self.W_CAP, -1)
        self._cpu = self._column(self.W_CPU)
        self._port = self._column(self.W_PORT)
        self._age = self._column(self.W_AGE)
        self._note = self._column(self.W_NOTE)  # exit code, restarts — the exceptions
        for widget in (self._mem, self._cap, self._cpu, self._port, self._age, self._note):
            self.add_suffix(widget)

        # A gradle backend sits in `starting` for a minute. Something has to
        # move, or you cannot tell waiting from stuck.
        self._spinner = Gtk.Spinner(valign=Gtk.Align.CENTER)
        self._spinner.set_visible(False)
        self.add_suffix(self._spinner)

        box = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
        # The port has always been printed and never been usable. pitcrew knows
        # the real URL — including the --url-path every backend sits behind — so
        # this opens the right thing rather than a guess at localhost:PORT.
        # web-browser-symbolic, not adw-external-link-symbolic: the latter is
        # bundled in libadwaita's resources and only resolves after Adw.init(),
        # which makes it invisible anywhere the theme is queried earlier.
        self._open = Gtk.Button(icon_name="web-browser-symbolic", tooltip_text="Open")
        self._open.add_css_class("flat")
        self._open.set_visible(False)
        self._open.connect("clicked", lambda _b: self._launch())
        box.append(self._open)
        self._url = ""

        self._errors = Gtk.Button(icon_name="dialog-warning-symbolic",
                                  tooltip_text="Show the error lines")
        self._errors.add_css_class("flat")
        self._errors.set_visible(False)
        self._errors.connect(
            "clicked", lambda _b: self._on_show_logs and self._on_show_logs(self._name, True))
        box.append(self._errors)

        self._start = self._button(box, "media-playback-start-symbolic", "start", "Start")
        self._restart = self._button(box, "view-refresh-symbolic", "restart", "Restart")
        self._stop = self._button(box, "media-playback-stop-symbolic", "stop", "Stop")
        self.add_suffix(box)

    @staticmethod
    def _column(chars: int) -> Gtk.Label:
        label = Gtk.Label(xalign=1, width_chars=chars, valign=Gtk.Align.CENTER)
        label.add_css_class("caption")
        label.add_css_class("numeric")
        label.add_css_class("dim-label")
        return label

    def _button(self, box: Gtk.Box, icon: str, verb: str, tooltip: str) -> Gtk.Button:
        button = Gtk.Button(icon_name=icon, tooltip_text=tooltip)
        button.add_css_class("flat")
        button.connect("clicked", lambda _b: self._on_action(verb, self._name))
        box.append(button)
        return button

    def _launch(self) -> None:
        if self._url:
            Gtk.UriLauncher.new(self._url).launch(None, None, None, None)

    def set_color(self, color: str) -> None:
        """The colour of this component's line on the Resources graph.

        Not the dot — that shows state. Kept because the sparkline is drawn in
        the series colour and a rebuild can reassign it.
        """
        self._series_color = color

    def update(self, comp: dict, now: float = 0) -> None:
        state = comp.get("state", "down")
        running = state in ("up", "starting", "external")

        starting = state == "starting"
        self._spinner.set_visible(starting)
        (self._spinner.start if starting else self._spinner.stop)()
        css, dot = STATE_STYLE.get(state, UNKNOWN_STYLE)
        self._dot.set_color(dot)
        if css != self._badge_class:
            if self._badge_class:
                self._badge.remove_css_class(self._badge_class)
            self._badge.add_css_class(css)
            self._badge_class = css
        self._badge.set_text(state)

        # RSS alone does not tell you whether a service is near the cap that
        # will kill it, which is the number you actually want when the laptop
        # starts swapping. The bar is that ratio; the figures are the evidence.
        used, limit = comp.get("rss"), comp.get("limit")
        self._mem.set_text(f"{human_bytes(used)} / {human_bytes(limit)}"
                           if used and limit else human_bytes(used))
        if used and limit:
            percent = used * 100 / limit
            self._cap.set(used / limit, LEVEL[meter_level(percent)])
            self._cap.set_visible(True)
            self._cap.set_tooltip_text(f"{percent:.0f}% of this component's RAM cap")
        else:
            self._cap.set_visible(False)

        cpu = comp.get("cpu")
        self._cpu.set_text("—" if cpu is None else f"{cpu}%")
        self._port.set_text(f":{comp['port']}" if comp.get("port") else "")
        age = human_age(now - comp["since"]) if comp.get("since") and now else ""
        self._age.set_text(age)

        # One column for the exceptions, because they are mutually exclusive in
        # practice and a permanent column for "exit code" would be empty on
        # every healthy row.
        if state == "crashed" and comp.get("exit") is not None:
            self._note.set_text(f"exit {comp['exit']}")
        elif comp.get("restarts"):
            self._note.set_text(f"{comp['restarts']}× restart")
        else:
            self._note.set_text("")

        # "2 errors" that you cannot click is a dead end: the lines exist, in a
        # view one tab away, already highlighted.
        self._errors.set_visible(bool(comp.get("errors")) and self._on_show_logs is not None)
        if comp.get("errors"):
            self._errors.set_tooltip_text(f"{comp['errors']} error lines — show them")

        self._url = comp.get("url") or ""
        # Only offer to open something that is actually answering.
        self._open.set_visible(bool(self._url) and state in ("up", "external"))
        if self._url:
            self._open.set_tooltip_text(f"Open {self._url}")
        self.set_subtitle("")

        self._start.set_visible(not running)
        self._stop.set_visible(running)
        self._restart.set_visible(running)

class OutputView(Gtk.ScrolledWindow):
    """A monospace sink for whatever a pitcrew command had to say."""

    def __init__(self, height: int = 160, grow: bool = False):
        # `grow` only where the output IS the content. In the config editor it
        # sits under the text area and must not steal its room.
        super().__init__(min_content_height=height, vexpand=grow)
        self.set_max_content_height(height * 2)
        self._buffer = Gtk.TextBuffer()
        view = Gtk.TextView(buffer=self._buffer, editable=False, monospace=True,
                            top_margin=8, bottom_margin=8, left_margin=8, right_margin=8,
                            wrap_mode=Gtk.WrapMode.WORD_CHAR)
        self.set_child(view)
        self.add_css_class("card")

    def show_text(self, text: str) -> None:
        self._buffer.set_text(text or "")


# Style schemes, most preferred first per desktop theme. A scheme that is not
# installed is skipped rather than guessed at; the last resort is whatever the
# view already had, which is legible if plain.
_SCHEMES_DARK = ("Adwaita-dark", "solarized-dark", "oblivion", "classic")
_SCHEMES_LIGHT = ("Adwaita", "solarized-light", "tango", "classic")


def _source_scheme(buffer) -> None:
    dark = Adw.StyleManager.get_default().get_dark()
    manager = GtkSource.StyleSchemeManager.get_default()
    for name in (_SCHEMES_DARK if dark else _SCHEMES_LIGHT):
        scheme = manager.get_scheme(name)
        if scheme is not None:
            buffer.set_style_scheme(scheme)
            return


def code_view(text: str, language: str, editable: bool):
    """A monospace editor for one file, highlighted where that is available.

    Returns `(widget, buffer)`. The buffer is a plain `Gtk.TextBuffer` as far
    as every caller is concerned — `GtkSource.Buffer` is one — so nothing above
    this function needs to know which of the two it got.

    Spaces, never tabs: pitcrew's YAML loader REJECTS a tab used for
    indentation (lib/18-yaml.sh), so an editor that inserted one on Tab would
    write a file the tool then refused, from a keystroke nobody thinks about.
    """
    if GtkSource is None:
        buffer = Gtk.TextBuffer()
        buffer.set_text(text)
        view = Gtk.TextView(buffer=buffer, monospace=True, editable=editable,
                            top_margin=10, bottom_margin=10,
                            left_margin=10, right_margin=10)
        return view, buffer

    buffer = GtkSource.Buffer()
    lang = GtkSource.LanguageManager.get_default().get_language(language)
    if lang is not None:
        buffer.set_language(lang)
    buffer.set_highlight_syntax(True)
    _source_scheme(buffer)
    buffer.set_text(text)
    view = GtkSource.View(buffer=buffer, monospace=True, editable=editable,
                          show_line_numbers=True, highlight_current_line=editable,
                          auto_indent=True, insert_spaces_instead_of_tabs=True,
                          tab_width=2, indent_width=2,
                          top_margin=10, bottom_margin=10,
                          left_margin=10, right_margin=10)
    return view, buffer
