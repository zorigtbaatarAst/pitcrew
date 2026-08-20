"""Live tail of one component's log.

Reads the file directly rather than shelling out to `pitcrew logs`, because
that command is an interactive pager — but it does NOT know where logs live:
the path arrives in the stream as `logDir`, so this stays ignorant of pitcrew's
on-disk layout.
"""

from __future__ import annotations

import re

from gi.repository import Adw, Gio, GLib, Gtk

TAIL_LINES = 400          # what a fresh selection shows before following live
MAX_LINES = 5000          # ceiling per component, so a chatty dev server cannot
                          # grow the buffer until the window stops repainting


class LogView(Gtk.Box):
    def __init__(self, on_error):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self._on_error = on_error
        self._log_dir: str | None = None
        self._pattern: re.Pattern[str] | None = None
        self._all: list[dict] = []       # every component, with its role
        self._names: list[str] = []      # what the picker currently offers
        self._current: str | None = None
        self._proc: Gio.Subprocess | None = None
        self._cancel: Gio.Cancellable | None = None
        self._lines = 0
        # Every line as it arrived, so a filter can be changed without losing
        # what scrolled past — the file may already have been truncated.
        self._raw: list[str] = []

        self._picker = Gtk.DropDown(model=Gtk.StringList.new([]), hexpand=True)
        self._picker.connect("notify::selected", lambda *_: self._selection_changed())

        # Backends and frontends fail differently and you are usually looking for
        # one kind: a stack trace or a bundler error. Twelve names in one flat
        # list makes you read every one of them to find out which is which.
        self._roles = Adw.ToggleGroup()
        for name, label in (("all", "All"), ("be", "Backend"), ("fe", "Frontend")):
            self._roles.add(Adw.Toggle(name=name, label=label))
        self._roles.set_active_name("all")
        self._roles.connect("notify::active-name", lambda *_: self._refill())

        self._follow = Gtk.ToggleButton(icon_name="go-bottom-symbolic", active=True,
                                        tooltip_text="Follow new lines")
        # A tailer without a filter is half a tool: the line you want is one of
        # four hundred. Filtering hides lines as they arrive rather than
        # re-reading the file, so it works on a live tail.
        self._filter = Gtk.SearchEntry(placeholder_text="Filter lines", width_chars=18)
        self._filter.connect("search-changed", lambda _e: self._refilter())

        self._errors_only = Gtk.ToggleButton(icon_name="dialog-warning-symbolic",
                                             tooltip_text="Errors only")
        self._errors_only.connect("toggled", lambda _b: self._refilter())

        clear = Gtk.Button(icon_name="edit-clear-all-symbolic", tooltip_text="Clear")
        clear.connect("clicked", lambda _b: self._clear())

        bar = Gtk.Box(spacing=8, margin_top=10, margin_bottom=4,
                      margin_start=12, margin_end=12)
        bar.append(self._roles)
        bar.append(self._picker)
        bar.append(self._filter)
        bar.append(self._errors_only)
        bar.append(self._follow)
        bar.append(clear)

        self._buffer = Gtk.TextBuffer()
        # Two tags, because an error line you have to hunt for is a line you did
        # not see. `error` is the same set the dashboard counts.
        self._buffer.create_tag("error", foreground="#ff7b72", weight=700)
        self._buffer.create_tag("dim", foreground="#8b949e")
        view = Gtk.TextView(buffer=self._buffer, editable=False, monospace=True,
                            cursor_visible=False, top_margin=8, bottom_margin=8,
                            left_margin=10, right_margin=10)
        self._scroller = Gtk.ScrolledWindow(child=view, vexpand=True,
                                            margin_start=12, margin_end=12, margin_bottom=12)
        self._scroller.add_css_class("card")

        self._status = Gtk.Label(halign=Gtk.Align.START, margin_start=14, margin_bottom=8)
        self._status.add_css_class("caption")
        self._status.add_css_class("dim-label")

        self.append(bar)
        self.append(self._scroller)
        self.append(self._status)

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
        if components == self._all:
            return
        self._all = components
        self._refill()

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

    def show_component(self, name: str, errors_only: bool = False) -> None:
        """Open one component's log — how the Components view hands off."""
        if name in self._names:
            self._roles.set_active_name("all")
        if name not in self._names:
            return
        self._errors_only.set_active(errors_only)
        self._picker.set_selected(self._names.index(name))
        self._selection_changed()

    def focus_filter(self) -> None:
        self._filter.grab_focus()

    def stop(self) -> None:
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
            self._status.set_text(f"{name} has no log yet — it has not been started")
            return
        self._status.set_text(path)

        # `tail -n N -f` is POSIX and handles the truncate-on-restart that
        # launch_process does; re-implementing a follower here would be a second
        # thing to get wrong.
        self._cancel = Gio.Cancellable()
        try:
            self._proc = Gio.Subprocess.new(
                ["tail", "-n", str(TAIL_LINES), "-f", path],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE)
        except GLib.Error as error:
            self._on_error(f"cannot tail {name}: {error.message}")
            return
        self._read(Gio.DataInputStream.new(self._proc.get_stdout_pipe()))

    def _read(self, stream: Gio.DataInputStream) -> None:
        if self._cancel is None or self._cancel.is_cancelled():
            return
        stream.read_line_async(GLib.PRIORITY_LOW, self._cancel, self._on_line)

    def _on_line(self, stream: Gio.DataInputStream, result) -> None:
        try:
            data, length = stream.read_line_finish(result)
        except GLib.Error:
            return                       # cancelled, or the pipe went away
        # EOF is an EMPTY line here, never None; re-arming on it spins the main
        # loop and freezes the window. Same trap as the state stream.
        if data is None or length == 0:
            return
        self._append(data.decode("utf-8", "replace"))
        self._read(stream)

    def _shown(self, line: str) -> bool:
        needle = self._filter.get_text().strip().lower()
        if needle and needle not in line.lower():
            return False
        if self._errors_only.get_active():
            return bool(self._pattern and self._pattern.search(line))
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
        if self._follow.get_active():
            GLib.idle_add(self._scroll_to_end, priority=GLib.PRIORITY_LOW)

    def _insert(self, line: str) -> None:
        end = self._buffer.get_end_iter()
        tag = "error" if self._pattern and self._pattern.search(line) else "dim"
        self._buffer.insert_with_tags_by_name(end, line + "\n", tag)
        self._lines += 1
        if self._lines > MAX_LINES:
            start = self._buffer.get_start_iter()
            cut = self._buffer.get_iter_at_line(self._lines - MAX_LINES)[1]
            self._buffer.delete(start, cut)
            self._lines = MAX_LINES

    def _scroll_to_end(self) -> bool:
        adjustment = self._scroller.get_vadjustment()
        adjustment.set_value(adjustment.get_upper() - adjustment.get_page_size())
        return False

    def _clear(self) -> None:
        self._buffer.set_text("")
        self._lines = 0
        self._raw.clear()
