"""Reusable pieces of chrome: the status dot, the graph, a component row."""

from __future__ import annotations

import cairo
from gi.repository import Adw, Gtk

from .model import (
    STATE_STYLE,
    UNKNOWN_STYLE,
    Series,
    hover_index,
    human_bytes,
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

    def __init__(self, metric: str, floor: float, fmt):
        super().__init__()
        self._metric = metric        # "cpu" or "rss" — the Series attribute to plot
        self._floor = floor          # smallest sensible axis ceiling
        self._fmt = fmt
        self._series: list[Series] = []
        self._history = SETTINGS_BY_KEY["history"].default
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

    def _draw(self, _area, cr, width, height) -> None:
        fg = self.get_color()        # follows the theme; grid is the same ink, faded
        cr.select_font_face("sans-serif")
        cr.set_font_size(10)

        if self._forced_ceiling:
            ceiling = self._forced_ceiling
        else:
            peak = max((max(getattr(s, self._metric), default=0.0) for s in self._series), default=0.0)
            ceiling = nice_max(peak, self._floor)
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
            points = getattr(series, self._metric)
            if len(points) < 2:
                continue
            # The history is right-anchored: a series that just appeared draws
            # from the right edge inward rather than stretching across the whole
            # window and implying data it does not have.
            step = plot_w / (self._history - 1)
            start_x = pad_left + plot_w - step * (len(points) - 1)
            cr.set_source_rgb(*series.rgb)
            cr.set_line_width(2)
            cr.set_line_join(cairo.LINE_JOIN_ROUND)
            for index, value in enumerate(points):
                x = start_x + step * index
                y = pad_top + plot_h * (1 - min(value / ceiling, 1.0))
                cr.line_to(x, y) if index else cr.move_to(x, y)
            cr.stroke()

        self._draw_hover(cr, fg, pad_left, pad_top, plot_w, plot_h, ceiling)

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

class Sparkline(Gtk.DrawingArea):
    """A component's recent memory, in the row you are already looking at.

    The terminal dashboard has drawn one of these per row from the start; the
    GUI showed a number and made you switch to Resources and find the line in a
    legend to answer "is this climbing". The samples are already in memory —
    they were only ever read by the graphs.
    """

    def __init__(self, width: int = 76, height: int = 22):
        super().__init__()
        self._series: Series | None = None
        self._ceiling = 0.0
        self.set_content_width(width)
        self.set_content_height(height)
        self.set_valign(Gtk.Align.CENTER)
        self.set_draw_func(self._draw)

    def set_source(self, series: Series | None, ceiling: float) -> None:
        self._series = series
        self._ceiling = ceiling or 0.0
        self.queue_draw()

    def _draw(self, _area, cr, width, height) -> None:
        series = self._series
        points = list(series.rss) if series else []
        if len(points) < 2:
            return
        # Scaled to the CAP, not to the series' own range: the question in a
        # component row is "how close am I to the limit", and a range-scaled
        # sparkline makes an idle service look as busy as a leaking one.
        ceiling = self._ceiling or max(points) or 1.0
        # Fills the width, unlike the Resources graphs, which are right-anchored
        # so several series share one time axis. A row sparkline is about shape,
        # and anchoring it would leave a stub for the first four minutes.
        step = width / max(1, len(points) - 1)
        start_x = 0.0

        cr.set_source_rgba(*series.rgb, 0.22)
        cr.move_to(start_x, height)
        for index, value in enumerate(points):
            cr.line_to(start_x + step * index, height * (1 - min(value / ceiling, 1.0)))
        cr.line_to(start_x + step * (len(points) - 1), height)
        cr.close_path()
        cr.fill()

        cr.set_source_rgb(*series.rgb)
        cr.set_line_width(1.5)
        for index, value in enumerate(points):
            x = start_x + step * index
            y = height * (1 - min(value / ceiling, 1.0))
            cr.line_to(x, y) if index else cr.move_to(x, y)
        cr.stroke()


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
    """Who is eating the stack, as a share of it.

    The line graphs answer "is this climbing"; they are bad at "which of these
    twelve is the problem", because a 3 GiB frontend and a 300 MiB cron worker
    are both just lines. A ring answers that in one look, and the slices reuse
    the series colours so it reads against the legend and the row sparklines
    without a second key.
    """

    def __init__(self):
        super().__init__()
        self._slices: list[tuple[str, float, tuple[float, float, float]]] = []
        self._total = 0.0
        self.set_content_height(190)
        self.set_hexpand(True)
        self.set_draw_func(self._draw)

    def set_slices(self, slices, total: float) -> None:
        self._slices = list(slices)
        self._total = total
        self.queue_draw()

    def _draw(self, _area, cr, width, height) -> None:
        fg = self.get_color()
        cr.select_font_face("sans-serif")
        cr.set_font_size(11)

        if not self._slices or self._total <= 0:
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.45)
            text = "nothing running"
            cr.move_to((width - cr.text_extents(text).width) / 2, height / 2)
            cr.show_text(text)
            return

        tau = 6.283185307179586
        outer = min(height, 150) / 2 - 6
        inner = outer * 0.58
        cx, cy = 12 + outer, height / 2

        angle = -tau / 4                       # start at twelve o'clock
        for _name, value, rgb_ in self._slices:
            sweep = tau * value / self._total
            cr.set_source_rgb(*rgb_)
            cr.move_to(cx, cy)
            cr.arc(cx, cy, outer, angle, angle + sweep)
            cr.close_path()
            cr.fill()
            angle += sweep

        # Punch the middle out AFTER the slices: a ring reads as proportion,
        # where a full pie invites reading the radius as a magnitude too.
        # CLEAR leaves real transparency, so the hole shows the themed window
        # behind it and stays right in both light and dark.
        cr.set_operator(cairo.OPERATOR_CLEAR)
        cr.arc(cx, cy, inner, 0, tau)
        cr.fill()
        cr.set_operator(cairo.OPERATOR_OVER)

        cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.92)
        cr.set_font_size(13)
        total = human_bytes(self._total)
        cr.move_to(cx - cr.text_extents(total).width / 2, cy + 4)
        cr.show_text(total)

        # A legend beside the ring rather than labels on it: twelve components
        # means twelve slices, and callouts on thin slices overlap into mush.
        cr.set_font_size(11)
        left = cx + outer + 22
        top = cy - min(len(self._slices), 8) * 8
        for row, (name, value, rgb_) in enumerate(self._slices[:8]):
            y = top + row * 17
            cr.set_source_rgb(*rgb_)
            cr.arc(left, y - 4, 4, 0, tau)
            cr.fill()
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.85)
            cr.move_to(left + 12, y)
            cr.show_text(f"{name}   {human_bytes(value)}   "
                         f"{value / self._total * 100:.0f}%")
        if len(self._slices) > 8:
            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.45)
            cr.move_to(left + 12, top + 8 * 17)
            cr.show_text(f"+{len(self._slices) - 8} more")


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

        self._bar = Gtk.LevelBar(hexpand=True, valign=Gtk.Align.CENTER)
        self._bar.set_min_value(0)
        self._bar.set_max_value(100)
        # The named offsets are what make a LevelBar change colour at a
        # threshold instead of being a blue rectangle all the way to 100%.
        self._bar.add_offset_value(Gtk.LEVEL_BAR_OFFSET_LOW, 70)
        self._bar.add_offset_value(Gtk.LEVEL_BAR_OFFSET_HIGH, 88)
        self._bar.add_offset_value(Gtk.LEVEL_BAR_OFFSET_FULL, 100)
        self.append(self._bar)

        self._value = Gtk.Label(xalign=1, width_chars=18)
        self._value.add_css_class("caption")
        self._value.add_css_class("numeric")
        self.append(self._value)

    def set(self, percent: float, text: str) -> None:
        self._bar.set_value(max(0.0, min(100.0, float(percent))))
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

    def __init__(self, finding: dict, on_logs=None) -> None:
        super().__init__(title=plain_text(finding.get("title", "")),
                         subtitle=plain_text(finding.get("detail", "")),
                         use_markup=False)
        icon_name, css = self.ICONS.get(finding.get("severity", "info"),
                                        self.ICONS["info"])
        icon = Gtk.Image(icon_name=icon_name, valign=Gtk.Align.CENTER)
        icon.add_css_class(css)
        self.add_prefix(icon)

        # A finding that names a component and suggests looking at its log is
        # one click away from that log — printing the command for someone to
        # retype in another window would be a strange thing for a GUI to do.
        scope, fix = finding.get("scope") or "", finding.get("fix") or ""
        if scope and fix.startswith("pitcrew logs") and on_logs is not None:
            button = Gtk.Button(label="Logs", valign=Gtk.Align.CENTER)
            button.add_css_class("flat")
            button.connect("clicked", lambda _b: on_logs(scope, False))
            self.add_suffix(button)
        elif fix:
            hint = Gtk.Label(label=fix, valign=Gtk.Align.CENTER, selectable=True)
            hint.add_css_class("caption")
            hint.add_css_class("dim-label")
            self.add_suffix(hint)


class ComponentRow(Adw.ActionRow):
    """One component: state, what it is using, and the buttons that act on it."""

    def __init__(self, name: str, color: str, on_action, on_show_logs=None) -> None:
        # Component names and ports come from a config file, not from us.
        super().__init__(title=name, use_markup=False)
        self._name = name
        self._on_action = on_action
        self._on_show_logs = on_show_logs

        self._dot = Dot(color)
        self.add_prefix(self._dot)

        self._spark = Sparkline()
        self._spark.set_visible(False)
        self.add_suffix(self._spark)

        # A gradle backend sits in `starting` for a minute. Something has to
        # move, or you cannot tell waiting from stuck.
        self._spinner = Gtk.Spinner(valign=Gtk.Align.CENTER)
        self._spinner.set_visible(False)
        self.add_suffix(self._spinner)

        self._badge = Gtk.Label(valign=Gtk.Align.CENTER)
        self._badge.add_css_class("caption")
        self._badge_class = ""
        self.add_suffix(self._badge)

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
        self._dot.set_color(color)

    def update(self, comp: dict, series=None, now: float = 0) -> None:
        state = comp.get("state", "down")
        running = state in ("up", "starting", "external")

        self._spark.set_source(series, comp.get("limit") or 0)
        self._spark.set_visible(bool(series) and state == "up")

        starting = state == "starting"
        self._spinner.set_visible(starting)
        (self._spinner.start if starting else self._spinner.stop)()
        css, _ = STATE_STYLE.get(state, UNKNOWN_STYLE)
        if css != self._badge_class:
            if self._badge_class:
                self._badge.remove_css_class(self._badge_class)
            self._badge.add_css_class(css)
            self._badge_class = css
        self._badge.set_text(state)

        # RSS alone does not tell you whether a service is near the cap that will
        # kill it, which is the number you actually want when the laptop starts
        # swapping. Show both, and only once there is a reading to compare.
        used, limit = comp.get("rss"), comp.get("limit")
        if used and limit:
            bits = [f"{human_bytes(used)} / {human_bytes(limit)}"]
        else:
            bits = [human_bytes(used)]
        cpu = comp.get("cpu")
        bits.append("cpu —" if cpu is None else f"{cpu}% cpu")
        if comp.get("port"):
            bits.append(f":{comp['port']}")
        if comp.get("health"):
            bits.append("health ✓" if state == "up" else "health")
        if comp.get("errors"):
            bits.append(f"{comp['errors']} errors")
        # "2 errors" that you cannot click is a dead end: the lines exist, in a
        # view one tab away, already highlighted.
        self._errors.set_visible(bool(comp.get("errors")) and self._on_show_logs is not None)
        age = human_age(now - comp["since"]) if comp.get("since") and now else ""
        if age:
            # `up` says nothing about whether it has been up three hours or
            # twenty seconds, which is the whole question when something flaps.
            bits.append(f"{'starting' if starting else 'up'} {age}")
        if comp.get("restarts"):
            bits.append(f"restarted {comp['restarts']}×")
        if state == "crashed" and comp.get("exit") is not None:
            bits.append(f"exit {comp['exit']}")

        self._url = comp.get("url") or ""
        # Only offer to open something that is actually answering.
        self._open.set_visible(bool(self._url) and state in ("up", "external"))
        if self._url:
            self._open.set_tooltip_text(f"Open {self._url}")
        self.set_subtitle("  ·  ".join(bits))

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
