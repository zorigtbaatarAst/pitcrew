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
        self._names: list[str] = []
        self._current: str | None = None
        self._proc: Gio.Subprocess | None = None
        self._cancel: Gio.Cancellable | None = None
        self._lines = 0

        self._picker = Gtk.DropDown(model=Gtk.StringList.new([]), hexpand=True)
        self._picker.connect("notify::selected", lambda *_: self._selection_changed())

        self._follow = Gtk.ToggleButton(icon_name="go-bottom-symbolic", active=True,
                                        tooltip_text="Follow new lines")
        clear = Gtk.Button(icon_name="edit-clear-all-symbolic", tooltip_text="Clear")
        clear.connect("clicked", lambda _b: self._clear())

        bar = Gtk.Box(spacing=8, margin_top=10, margin_bottom=4,
                      margin_start=12, margin_end=12)
        bar.append(self._picker)
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
    def update_sources(self, log_dir: str | None, names: list[str], pattern: str | None) -> None:
        if pattern:
            try:
                self._pattern = re.compile(pattern)
            except re.error:
                # A pattern pitcrew accepts that Python does not is possible;
                # losing the highlight beats losing the whole view.
                self._pattern = None
        self._log_dir = log_dir
        if names == self._names:
            return
        self._names = names
        model = Gtk.StringList.new(names)
        selected = names.index(self._current) if self._current in names else 0
        self._picker.set_model(model)
        if names:
            self._picker.set_selected(selected)

    def _selection_changed(self) -> None:
        index = self._picker.get_selected()
        if index == Gtk.INVALID_LIST_POSITION or index >= len(self._names):
            return
        name = self._names[index]
        if name != self._current:
            self._current = name
            self._open(name)

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

    def _append(self, line: str) -> None:
        end = self._buffer.get_end_iter()
        tag = "error" if self._pattern and self._pattern.search(line) else "dim"
        self._buffer.insert_with_tags_by_name(end, line + "\n", tag)
        self._lines += 1
        if self._lines > MAX_LINES:
            start = self._buffer.get_start_iter()
            cut = self._buffer.get_iter_at_line(self._lines - MAX_LINES)[1]
            self._buffer.delete(start, cut)
            self._lines = MAX_LINES
        if self._follow.get_active():
            GLib.idle_add(self._scroll_to_end, priority=GLib.PRIORITY_LOW)

    def _scroll_to_end(self) -> bool:
        adjustment = self._scroller.get_vadjustment()
        adjustment.set_value(adjustment.get_upper() - adjustment.get_page_size())
        return False

    def _clear(self) -> None:
        self._buffer.set_text("")
        self._lines = 0
