"""Reusable pieces of chrome: the status dot, the graph, a component row."""

from __future__ import annotations

import cairo
from gi.repository import Adw, Gtk

from .model import SERIES_COLORS, STATE_STYLE, UNKNOWN_STYLE, human_bytes, nice_max, rgb
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
        self.set_content_height(180)
        self.set_hexpand(True)
        self.set_draw_func(self._draw)

    def set_series(self, series: list[Series], history: int) -> None:
        self._series = series
        self._history = max(2, history)
        self.queue_draw()

    def _draw(self, _area, cr, width, height) -> None:
        fg = self.get_color()        # follows the theme; grid is the same ink, faded
        cr.select_font_face("sans-serif")
        cr.set_font_size(10)

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

class ComponentRow(Adw.ActionRow):
    """One component: state, what it is using, and the buttons that act on it."""

    def __init__(self, name: str, color: str, on_action) -> None:
        # Component names and ports come from a config file, not from us.
        super().__init__(title=name, use_markup=False)
        self._name = name
        self._on_action = on_action

        self._dot = Dot(color)
        self.add_prefix(self._dot)

        self._badge = Gtk.Label(valign=Gtk.Align.CENTER)
        self._badge.add_css_class("caption")
        self._badge_class = ""
        self.add_suffix(self._badge)

        box = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
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

    def set_color(self, color: str) -> None:
        self._dot.set_color(color)

    def update(self, comp: dict) -> None:
        state = comp.get("state", "down")
        css, _ = STATE_STYLE.get(state, UNKNOWN_STYLE)
        if css != self._badge_class:
            if self._badge_class:
                self._badge.remove_css_class(self._badge_class)
            self._badge.add_css_class(css)
            self._badge_class = css
        self._badge.set_text(state)

        bits = [human_bytes(comp.get("rss"))]
        cpu = comp.get("cpu")
        bits.append("cpu —" if cpu is None else f"{cpu}% cpu")
        if comp.get("port"):
            bits.append(f":{comp['port']}")
        if comp.get("errors"):
            bits.append(f"{comp['errors']} errors")
        if state == "crashed" and comp.get("exit") is not None:
            bits.append(f"exit {comp['exit']}")
        self.set_subtitle("  ·  ".join(bits))

        running = state in ("up", "starting", "external")
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
