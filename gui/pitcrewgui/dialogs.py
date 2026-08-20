"""Dialogs that change pitcrew itself: adding a project, editing its config."""

from __future__ import annotations

from pathlib import Path

from gi.repository import Adw, GLib, Gtk

from .model import human_bytes, plain
from .registry import project_config_path
from .runner import Runner, bash_syntax_error
from .widgets import OutputView


class InitDialog(Adw.Dialog):
    """`pitcrew init` with the guessing left where it belongs — in pitcrew.

    Deliberately thin: it collects a directory and a name, shells out, and shows
    what came back verbatim. Re-implementing the detection would give the GUI a
    second opinion about a project, and two opinions is one too many.
    """

    def __init__(self, runner: Runner, on_created):
        super().__init__(title="Add project", content_width=520)
        self._runner = runner
        self._on_created = on_created
        self._folder: Path | None = None

        self._folder_row = Adw.ActionRow(
            title="Folder", subtitle="Choose the checkout to look at", use_markup=False)
        choose = Gtk.Button(label="Choose…", valign=Gtk.Align.CENTER)
        choose.connect("clicked", self._choose_folder)
        self._folder_row.add_suffix(choose)
        self._folder_row.set_activatable_widget(choose)

        self._name_row = Adw.EntryRow(title="Name")
        self._in_project = Adw.SwitchRow(
            title="Keep the config in the project",
            subtitle="Writes pitcrew.config.sh into the checkout, not the registry")
        self._force = Adw.SwitchRow(
            title="Replace an existing config",
            subtitle="Without this, init refuses rather than overwrite")

        group = Adw.PreferencesGroup()
        for row in (self._folder_row, self._name_row, self._in_project, self._force):
            group.add(row)

        self._output = OutputView(grow=True)
        self._output.set_visible(False)

        self._run_button = Gtk.Button(label="Look at it", sensitive=False)
        self._run_button.add_css_class("suggested-action")
        self._run_button.connect("clicked", lambda _b: self._run())

        header = Adw.HeaderBar()
        header.pack_end(self._run_button)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                       margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
        body.append(group)
        body.append(self._output)

        view = Adw.ToolbarView()
        view.add_top_bar(header)
        view.set_content(Gtk.ScrolledWindow(child=body, propagate_natural_height=True))
        self.set_child(view)

    def _choose_folder(self, _button) -> None:
        dialog = Gtk.FileDialog(title="Choose project folder")
        dialog.select_folder(self.get_root(), None, self._folder_chosen)

    def _folder_chosen(self, dialog: Gtk.FileDialog, result) -> None:
        try:
            folder = dialog.select_folder_finish(result)
        except GLib.Error:
            return                    # dismissed; not an error worth reporting
        if folder is None or folder.get_path() is None:
            return
        self._folder = Path(folder.get_path())
        self._folder_row.set_subtitle(plain(str(self._folder)))
        if not self._name_row.get_text():
            self._name_row.set_text(self._folder.name)
        self._run_button.set_sensitive(True)

    def _run(self) -> None:
        if self._folder is None:
            return
        args = ["init", "--name", self._name_row.get_text() or self._folder.name]
        if self._in_project.get_active():
            args.append("--in-project")
        if self._force.get_active():
            args.append("--force")
        args.append(str(self._folder))

        self._run_button.set_sensitive(False)
        self._output.set_visible(True)
        self._output.show_text("Looking…")
        self._runner.run(args, self._done)

    def _done(self, ok: bool, output: str) -> None:
        self._run_button.set_sensitive(True)
        # init exits non-zero when it recognises nothing, and says why. Show its
        # own words rather than inventing a friendlier, less useful message.
        self._output.show_text(output or ("done" if ok else "init failed"))
        if not ok:
            return
        self._run_button.set_label("Done")
        self._on_created()

class ConfigDialog(Adw.Dialog):
    """The project's config, as the bash file it actually is.

    A form over `pitcrew_app` calls would be nicer to look at and wrong: a config
    is a sourced shell script that may branch, loop or source something else, and
    a structured editor that cannot round-trip that would quietly drop it. So:
    edit the text, and refuse to save something bash cannot even parse.
    """

    def __init__(self, runner: Runner, name: str, on_saved):
        super().__init__(title=f"{name} · config", content_width=760, content_height=620)
        self._runner = runner
        self._name = name
        self._on_saved = on_saved
        self._path = project_config_path(name)

        self._buffer = Gtk.TextBuffer()
        try:
            self._buffer.set_text(self._path.read_text(encoding="utf-8"))
            editable = True
        except OSError as error:
            self._buffer.set_text(f"# cannot read {self._path}: {error}")
            editable = False

        view = Gtk.TextView(buffer=self._buffer, monospace=True, editable=editable,
                            top_margin=10, bottom_margin=10, left_margin=10, right_margin=10)
        scroller = Gtk.ScrolledWindow(child=view, vexpand=True)
        scroller.add_css_class("card")

        self._output = OutputView(height=120)
        self._output.show_text(str(self._path))

        save = Gtk.Button(label="Save", sensitive=editable)
        save.add_css_class("suggested-action")
        save.connect("clicked", lambda _b: self._save())
        check = Gtk.Button(label="Check")
        check.connect("clicked", lambda _b: self._check())

        header = Adw.HeaderBar()
        header.pack_end(save)
        header.pack_start(check)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10,
                       margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
        body.append(scroller)
        body.append(self._output)

        wrapper = Adw.ToolbarView()
        wrapper.add_top_bar(header)
        wrapper.set_content(body)
        self.set_child(wrapper)

    def _text(self) -> str:
        start, end = self._buffer.get_bounds()
        return self._buffer.get_text(start, end, False)

    def _save(self) -> None:
        text = self._text()
        problem = bash_syntax_error(text)
        if problem:
            # Saving a config bash cannot parse breaks every pitcrew command for
            # this project, including the one that would tell you why.
            self._output.show_text(f"not saved — bash cannot parse this:\n\n{problem}")
            return
        try:
            self._path.write_text(text, encoding="utf-8")
        except OSError as error:
            self._output.show_text(f"could not write {self._path}: {error}")
            return
        self._output.show_text(f"saved {self._path}")
        self._on_saved()

    def _check(self) -> None:
        problem = bash_syntax_error(self._text())
        if problem:
            self._output.show_text(f"bash cannot parse this:\n\n{problem}")
            return
        self._output.show_text("running pitcrew doctor…")
        self._runner.run(["-p", self._name, "doctor"],
                         lambda ok, out: self._output.show_text(out or "doctor said nothing"))


# Sizes offered in the picker. A free-text box would let you type "8gb" and be
# told no by a CLI you cannot see; a list cannot be typo'd. "Default" is first
# because clearing an override is the commonest thing after setting one.
LIMIT_CHOICES = ("default", "256M", "512M", "1G", "2G", "3G", "4G", "6G", "8G", "12G", "16G")


class LimitsDialog(Adw.Dialog):
    """Per-component RAM caps.

    Writes nothing itself: every change goes through `pitcrew limit`, the same
    way adding a project goes through `pitcrew init`. One place knows the file
    format, and it is not the GUI.
    """

    def __init__(self, runner: Runner, project: str, components: list[dict], on_changed):
        super().__init__(title=f"{project} · RAM caps", content_width=560, content_height=620)
        self._runner = runner
        self._project = project
        self._on_changed = on_changed
        self._rows: dict[str, Adw.ComboRow] = {}

        group = Adw.PreferencesGroup(
            title="Caps",
            description="Applied when a component starts — restart one to change its cap")
        for comp in components:
            group.add(self._row_for(comp))

        self._output = OutputView(height=110)
        self._output.show_text(
            "A cap is a property of this machine, not the project: these are stored "
            "locally, not in the config the repo shares.")

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                       margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
        body.append(group)
        body.append(self._output)

        view = Adw.ToolbarView()
        view.add_top_bar(Adw.HeaderBar())
        view.set_content(Gtk.ScrolledWindow(child=body, propagate_natural_height=True))
        self.set_child(view)

    def _row_for(self, comp: dict) -> Adw.ComboRow:
        name = comp["name"]
        source = comp.get("limitSource") or "role"
        effective = human_bytes(comp.get("limit")) if comp.get("limit") else "—"
        subtitle = {
            "override": f"{effective} · set here",
            "app": f"{effective} · from the project config",
        }.get(source, f"{effective} · role default")

        row = Adw.ComboRow(title=name, subtitle=subtitle, use_markup=False,
                           model=Gtk.StringList.new(list(LIMIT_CHOICES)))
        # Only an override selects a value; anything inherited sits on "default"
        # so picking it again is a no-op rather than a silent re-assertion.
        current = _size_label(comp.get("limit")) if source == "override" else "default"
        row.set_selected(LIMIT_CHOICES.index(current) if current in LIMIT_CHOICES else 0)
        row.connect("notify::selected", self._chosen, name)
        self._rows[name] = row
        return row

    def _chosen(self, row: Adw.ComboRow, _param, name: str) -> None:
        value = LIMIT_CHOICES[row.get_selected()]
        self._output.show_text(f"setting {name} to {value}…")
        self._runner.run(["-p", self._project, "limit", name, value],
                         lambda ok, out: self._done(ok, out, name))

    def _done(self, ok: bool, output: str, name: str) -> None:
        lines = [line.strip() for line in (output or "").splitlines() if line.strip()]
        self._output.show_text(lines[-1] if lines else f"{name} updated")
        if ok:
            self._on_changed()


def _size_label(size_bytes: int | None) -> str:
    """Bytes back to the label the picker uses, or "" if it is not one of them."""
    if not size_bytes:
        return ""
    for label in LIMIT_CHOICES:
        if label == "default":
            continue
        unit, number = label[-1], int(label[:-1])
        scale = 1024 ** 3 if unit == "G" else 1024 ** 2
        if number * scale == size_bytes:
            return label
    return ""
