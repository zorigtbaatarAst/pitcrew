"""Live tail of one component's log.

Reads the file directly rather than shelling out to `pitcrew logs`, because
that command is an interactive pager — but it does NOT know where logs live:
the path arrives in the stream as `logDir`, so this stays ignorant of pitcrew's
on-disk layout.
"""

from __future__ import annotations

import re

from gi.repository import Adw, Gio, GLib, Gtk, Pango

from . import ansi, theme
from .runner import LineReader
from .widgets import SegmentedControl

TAIL_LINES = 400          # what a fresh selection shows before following live
MAX_LINES = 5000          # ceiling per component, so a chatty dev server cannot
                          # grow the buffer until the window stops repainting


class LogView(Gtk.Box):
    def __init__(self, on_error, on_detach=None, on_component=None):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self._on_error = on_error
        # Set by the main window only. A detached window IS the detached view,
        # so it does not offer to detach itself again.
        self._on_detach = on_detach
        # Who is being shown, for a window that has to title itself.
        self._on_component = on_component
        self._log_dir: str | None = None
        self._pattern: re.Pattern[str] | None = None
        self._all: list[dict] = []       # every component, with its role
        self._shape: list[tuple] = []    # the part of that which affects the picker
        self._names: list[str] = []      # what the picker currently offers
        self._current: str | None = None
        self._proc: Gio.Subprocess | None = None
        self._cancel: Gio.Cancellable | None = None
        self._reader: LineReader | None = None
        # A component you selected before starting it has no log file to tail.
        # Remembered so the next frame can pick it up the moment one appears —
        # otherwise "open Logs, then start the stack" showed the same "no log
        # yet" line forever, which looks exactly like a frozen view.
        self._waiting: str | None = None
        self._lines = 0
        self._scroll_pending = False
        # Every line as it arrived, so a filter can be changed without losing
        # what scrolled past — the file may already have been truncated.
        self._raw: list[str] = []

        bar = self._build_bar()

        self._buffer = Gtk.TextBuffer()
        self._buffer.create_tag("bold", weight=700)
        self._buffer.create_tag("italic", style=Pango.Style.ITALIC)
        self._buffer.create_tag("underline", underline=Pango.Underline.SINGLE)
        self._apply_palette()
        # The palette has to change with the desktop theme, not with a restart:
        # the colours that make a Spring log readable on a dark background are
        # the ones that are illegible on a light one.
        Adw.StyleManager.get_default().connect(
            "notify::dark", lambda *_: self._apply_palette())
        self._view = Gtk.TextView(buffer=self._buffer, editable=False, monospace=True,
                                  cursor_visible=False, top_margin=8, bottom_margin=8,
                                  left_margin=10, right_margin=10)
        view = self._view
        self._apply_wrap()
        self._scroller = Gtk.ScrolledWindow(child=view, vexpand=True,
                                            margin_start=12, margin_end=12, margin_bottom=12)
        self._scroller.add_css_class("card")

        self._status = Gtk.Label(halign=Gtk.Align.START, margin_start=14, margin_bottom=8)
        self._status.add_css_class("caption")
        self._status.add_css_class("dim-label")

        self.append(bar)
        self.append(self._scroller)
        self.append(self._status)

    def _build_bar(self) -> Gtk.Widget:
        """The controls above the log. Its own method because the constructor
        was doing three jobs: the toolbar, the text view, and the state."""
        self._picker = Gtk.DropDown(model=Gtk.StringList.new([]), hexpand=True)
        self._picker.connect("notify::selected", lambda *_: self._selection_changed())

        # Backends and frontends fail differently and you are usually looking for
        # one kind: a stack trace or a bundler error. Twelve names in one flat
        # list makes you read every one of them to find out which is which.
        self._roles = SegmentedControl(on_change=self._refill)
        for name, label in (("all", "All"), ("be", "Backend"), ("fe", "Frontend")):
            self._roles.add_option(name, label)

        self._follow = Gtk.ToggleButton(icon_name="go-bottom-symbolic", active=True,
                                        tooltip_text="Follow new lines")
        # A tailer without a filter is half a tool: the line you want is one of
        # four hundred. Filtering hides lines as they arrive rather than
        # re-reading the file, so it works on a live tail.
        # Eighteen characters was a floor, not a size: it grows to fill the bar
        # anyway, and the only thing the number did was stop the whole window
        # from being resized narrow. Eight still shows enough of what you typed.
        self._filter = Gtk.SearchEntry(placeholder_text="Filter lines", width_chars=8,
                                       hexpand=True)
        self._filter.connect("search-changed", lambda _e: self._refilter())

        self._errors_only = Gtk.ToggleButton(icon_name="dialog-warning-symbolic",
                                             tooltip_text="Errors only")
        self._errors_only.connect("toggled", lambda _b: self._refilter())

        # Off by default: a log is read as columns — timestamp, level, logger —
        # and wrapping shuffles them. But a Spring line is 200 characters before
        # the message even starts, so the thing you are actually looking for is
        # off the right-hand edge until you ask for this.
        self._wrap = Gtk.ToggleButton(icon_name="format-justify-left-symbolic",
                                      tooltip_text="Wrap long lines")
        self._wrap.connect("toggled", lambda _b: self._apply_wrap())

        # Labelled, not an icon. It sat in a row of four unlabelled toggles and
        # its glyph reads as "copy" — the one control there that throws
        # something away was the one you could not identify.
        clear = Gtk.Button(label="Clear", tooltip_text="Empty this view (the log file is untouched)")
        clear.connect("clicked", lambda _b: self._clear())

        # A log is something you read WHILE doing something else — restarting
        # the thing that wrote it, editing the config that starts it. In one
        # tab of one window it is the only thing you can be looking at.
        self._detach = Gtk.Button(icon_name="window-new-symbolic",
                                  tooltip_text="Open this log in its own window")
        self._detach.connect("clicked", lambda _b: self._detach_current())

        bar = Gtk.Box(spacing=8, margin_top=10, margin_bottom=4,
                      margin_start=12, margin_end=12)
        # The role filter is the first thing to go in a narrow window: the
        # picker beside it already selects a component outright, so this is a
        # shortcut rather than the only way through. Hidden by the breakpoint
        # in window.py, which is where every other width decision lives.
        self._roles.set_visible(True)
        bar.append(self._roles)
        bar.append(self._picker)
        bar.append(self._filter)
        bar.append(self._errors_only)
        bar.append(self._wrap)
        bar.append(self._follow)
        if self._on_detach is not None:
            bar.append(self._detach)
        bar.append(clear)

        return bar

    def role_filter(self) -> Gtk.Widget:
        """The role segmented control, for the window's narrow breakpoint.

        Exposed rather than reached into: which control is expendable at a
        given width is this view's business, and the window only needs to know
        that there is one.
        """
        return self._roles

    def _detach_current(self) -> None:
        if self._current and self._on_detach is not None:
            self._on_detach(self._current)

    # ── colour ──────────────────────────────────────────────────────────────
    # The sixteen ANSI names come from the active pitcrew theme, so a log reads
    # in the same palette the dashboard draws in — see theme.ansi_palette. Two
    # hand-written tables used to live here, one for dark and one for light,
    # and the light one is now what theme.legible() derives: a dark palette on
    # a white background is not "the colours the app asked for", it is
    # unreadable, and pitcrew ships no light themes to pick from instead.

    def _apply_wrap(self) -> None:
        # WORD_CHAR, not WORD: a wrapped log line is usually a stack trace or a
        # URL, and WORD alone leaves an unbroken 300-character token running off
        # the edge anyway.
        self._view.set_wrap_mode(
            Gtk.WrapMode.WORD_CHAR if self._wrap.get_active() else Gtk.WrapMode.NONE)

    def refresh_palette(self) -> None:
        """The pitcrew theme changed. Text already in the buffer re-colours."""
        self._apply_palette()

    def _apply_palette(self) -> None:
        """Point the named colour tags at the palette for the current theme.

        The tags are updated in place, so text already in the buffer re-colours
        rather than needing the view to be rebuilt.
        """
        dark = Adw.StyleManager.get_default().get_dark()
        palette = theme.ansi_palette(theme.palette(), dark)
        table = self._buffer.get_tag_table()
        for name, colour in palette.items():
            tag = table.lookup(f"fg:{name}")
            if tag is None:
                tag = self._buffer.create_tag(f"fg:{name}")
            tag.set_property("foreground", colour)

    def _tag_names(self, span_tags: tuple[str, ...], is_error: bool) -> list[str]:
        """The tags to apply to one span, with the conflicts already resolved.

        A GtkTextTag either sets a foreground or does not, and two that both do
        fight by priority rather than by intent — so at most one colour is
        chosen here:

          * the colour the log asked for, if it asked for one;
          * otherwise the dim grey, if the span was dim (which is how every
            Spring line prints its timestamp);
          * otherwise the error colour, if the line matched pitcrew's error
            pattern. A line the application already coloured is left alone —
            it has said what it thinks, and overriding it would lose the
            distinction between its WARN and its ERROR.
        """
        colour = next((t for t in span_tags if t.startswith("fg:")), None)
        if colour is None and "dim" in span_tags:
            colour = "fg:bright-black"
        if colour is None and is_error:
            colour = "fg:error"
        names = [colour] if colour else []
        names += [a for a in ("bold", "italic", "underline") if a in span_tags]
        return names

    def _ensure_tag(self, name: str) -> None:
        """Create a tag for a colour the palette does not name.

        24-bit and 256-colour sequences carry their own value, so they cannot be
        themed — they are used as given. Created once and reused, because a
        chatty process can emit thousands of spans a second.
        """
        table = self._buffer.get_tag_table()
        if table.lookup(name) is None:
            self._buffer.create_tag(name, foreground=name[3:])

    # ── what the stream tells us ────────────────────────────────────────────
    def update_sources(self, log_dir: str | None, components: list[dict],
                       pattern: str | None) -> None:
        if pattern:
            try:
                self._pattern = re.compile(pattern)
            except re.error:
                # A pattern pitcrew accepts that Python does not is possible;
                # losing the highlight beats losing the whole view.
                self._pattern = None
        self._log_dir = log_dir
        # Compare the SHAPE, not the frame: every component dict carries live
        # rss/cpu, so `components == self._all` was false on every single frame
        # and made this do its full rebuild work each time.
        shape = [(c["name"], c.get("role"), c.get("app")) for c in components]
        self._all = components
        if shape != self._shape:
            self._shape = shape
            self._refill()
        self._retry_waiting()

    def _retry_waiting(self) -> None:
        """Re-arm the tail whenever there is one to arm and nothing running it.

        Two ways to end up here. A component selected before it was started has
        no log file yet, and this picks it up the moment one appears. And the
        tailer can simply be GONE — `tail -F` survives a restart's log rotation,
        but `stop()` is called on this view every time the state stream is
        rebuilt: after a config save, after a sampling change, on reconnect.

        That used to be the end of it. The condition was "was I waiting for this
        file", and a view whose tail had been stopped rather than never started
        was not waiting for anything — so it sat there showing the run it had
        already read, forever, which is indistinguishable from a service that
        has gone quiet. The condition that matters is simply: nothing is
        reading, and there is something to read.
        """
        if self._current is None or self._log_dir is None:
            return
        if self._reader is not None and self._reader.running:
            return
        if GLib.file_test(f"{self._log_dir}/{self._current}.log", GLib.FileTest.EXISTS):
            self._open(self._current)

    def _refill(self) -> None:
        """Rebuild the picker for the selected role, backends first."""
        role = self._roles.get_active_name() or "all"
        wanted = [c for c in self._all if role in ("all", c.get("role"))]
        # Backends lead because they start first and are what a frontend is
        # usually failing to reach.
        wanted.sort(key=lambda c: (c.get("role") != "be", c.get("app") or c["name"]))
        names = [c["name"] for c in wanted]
        if names == self._names:
            return
        self._names = names
        self._picker.set_model(Gtk.StringList.new(
            [f"{c.get('role', '--')}  ·  {c.get('app') or c['name']}" for c in wanted]))
        if names:
            self._picker.set_selected(names.index(self._current) if self._current in names else 0)
            self._selection_changed()
        else:
            self._current = None
            self.stop()
            self._clear()
            self._status.set_text(f"no {role} components in this project")

    def _selection_changed(self) -> None:
        index = self._picker.get_selected()
        if index == Gtk.INVALID_LIST_POSITION or index >= len(self._names):
            return
        name = self._names[index]
        if name != self._current:
            self._current = name
            self._open(name)
            if self._on_component is not None:
                self._on_component(name)

    def show_component(self, name: str, errors_only: bool = False) -> bool:
        """Open one component's log — how the Components view hands off.

        False when this view does not (yet) know that component: the caller may
        be a window opened before the first frame arrived, and it has to know
        whether to try again.
        """
        if name in self._names:
            self._roles.set_active_name("all")
        if name not in self._names:
            return False
        self._errors_only.set_active(errors_only)
        self._picker.set_selected(self._names.index(name))
        self._selection_changed()
        return True

    def focus_filter(self) -> None:
        self._filter.grab_focus()

    def stop(self) -> None:
        if self._reader:
            self._reader.stop()
        self._reader = None
        if self._cancel:
            self._cancel.cancel()
        if self._proc:
            self._proc.force_exit()
        self._proc = None

    # ── tailing ─────────────────────────────────────────────────────────────
    def _open(self, name: str) -> None:
        self.stop()
        self._clear()
        if not self._log_dir:
            self._status.set_text("no log directory yet")
            return
        path = f"{self._log_dir}/{name}.log"
        if not GLib.file_test(path, GLib.FileTest.EXISTS):
            self._waiting = name
            self._status.set_text(
                f"{name} has not been started yet — this will follow its log as soon as it is")
            return
        self._waiting = None
        self._status.set_text(path)

        # -F, not -f: restarting a component ROTATES its log (see rotate_log in
        # lib/07a-start.sh), and plain -f goes on following the renamed file —
        # so after a restart the view sat there showing the old run and looking
        # frozen. -F re-opens by name. Both GNU and BSD tail have it, so this is
        # not a GNU-only flag.
        self._cancel = Gio.Cancellable()
        try:
            self._proc = Gio.Subprocess.new(
                ["tail", "-n", str(TAIL_LINES), "-F", path],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE)
        except GLib.Error as error:
            self._on_error(f"cannot tail {name}: {error.message}")
            return
        # PRIORITY_DEFAULT_IDLE, not PRIORITY_LOW: low sits BELOW GTK's redraw,
        # so a service logging hard could keep the reader from ever being
        # serviced. Idle still yields to painting without being starved by it.
        self._reader = LineReader(self._proc.get_stdout_pipe(), self._append,
                                  on_eof=self._tail_ended, cancellable=self._cancel,
                                  priority=GLib.PRIORITY_DEFAULT_IDLE)
        self._reader.start()

    def _tail_ended(self) -> None:
        """The tailer exited — say so instead of silently showing a dead view.

        `_retry_waiting` picks it up again on the next frame if the log is
        still there, so this is a note rather than a dead end.
        """
        if self._current is not None:
            self._waiting = self._current

    def _shown(self, line: str) -> bool:
        # Against the TEXT, never the raw line: a filter for "INFO" must not be
        # satisfied by the escape sequence that colours it, and must not be
        # defeated by one sitting in the middle of the word.
        text = ansi.plain(line)
        needle = self._filter.get_text().strip().lower()
        if needle and needle not in text.lower():
            return False
        if self._errors_only.get_active():
            return bool(self._pattern and self._pattern.search(text))
        return True

    def _refilter(self) -> None:
        self._buffer.set_text("")
        self._lines = 0
        for line in self._raw:
            if self._shown(line):
                self._insert(line)
        self._scroll_to_end()

    def _append(self, line: str) -> None:
        self._raw.append(line)
        if len(self._raw) > MAX_LINES:
            del self._raw[:len(self._raw) - MAX_LINES]
        if not self._shown(line):
            return
        self._insert(line)
        # One idle callback per burst, not per line. `npm install` arrives in
        # chunks of hundreds of lines, and queueing a scroll for each of them
        # put thousands of callbacks in front of the compositor — the view
        # filled in, but the window stopped feeling alive while it did.
        if self._follow.get_active() and not self._scroll_pending:
            self._scroll_pending = True
            GLib.idle_add(self._scroll_to_end, priority=GLib.PRIORITY_DEFAULT_IDLE)

    def _insert(self, line: str) -> None:
        pieces = ansi.spans(line)
        is_error = bool(self._pattern and self._pattern.search(
            "".join(text for text, _ in pieces)))
        for text, span_tags in pieces:
            names = self._tag_names(span_tags, is_error)
            for name in names:
                if name.startswith("fg:#"):
                    self._ensure_tag(name)
            end = self._buffer.get_end_iter()
            if names:
                self._buffer.insert_with_tags_by_name(end, text, *names)
            else:
                self._buffer.insert(end, text)
        self._buffer.insert(self._buffer.get_end_iter(), "\n")
        self._lines += 1
        if self._lines > MAX_LINES:
            start = self._buffer.get_start_iter()
            cut = self._buffer.get_iter_at_line(self._lines - MAX_LINES)[1]
            self._buffer.delete(start, cut)
            self._lines = MAX_LINES

    def _scroll_to_end(self) -> bool:
        self._scroll_pending = False
        adjustment = self._scroller.get_vadjustment()
        adjustment.set_value(adjustment.get_upper() - adjustment.get_page_size())
        return False

    def _clear(self) -> None:
        self._buffer.set_text("")
        self._lines = 0
        self._raw.clear()


class LogWindow(Adw.Window):
    """One component's log, in a window of its own.

    The same LogView the Logs tab uses, fed the same frames by the main window
    — a detached log that stopped updating the moment it was detached would be
    worse than not offering one. It keeps the whole toolbar (filter, errors
    only, wrap, follow), because the reason to pull a log out of the tab is to
    work in it while doing something else to the service that writes it.
    """

    def __init__(self, application, project: str, component: str,
                 on_closed, on_error):
        super().__init__(application=application,
                         title=f"{component} · {project}",
                         default_width=1000, default_height=640)
        self.project = project
        self.component = component
        self._on_closed = on_closed
        # Not bound until the first frame: the picker is built from the stream,
        # so a window opened before one arrives has nothing to select yet.
        self._bound = False

        self.view = LogView(on_error, on_component=self._retitle)
        wrapper = Adw.ToolbarView()
        wrapper.add_top_bar(Adw.HeaderBar())
        wrapper.set_content(self.view)
        self.set_content(wrapper)
        self.connect("close-request", self._closing)

    def feed(self, log_dir: str | None, components: list[dict],
             pattern: str | None) -> None:
        """One frame of the state stream, forwarded from the main window."""
        self.view.update_sources(log_dir, components, pattern)
        if not self._bound:
            self._bound = self.view.show_component(self.component)

    def _retitle(self, component: str) -> None:
        # The picker is still there, so the window can be pointed somewhere
        # else. A title naming the log it no longer shows is a lie.
        self.component = component
        self.set_title(f"{component} · {self.project}")

    def _closing(self, *_args) -> bool:
        self.view.stop()
        self._on_closed(self)
        return False
