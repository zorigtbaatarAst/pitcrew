"""Dialogs that change pitcrew itself: adding a project, editing its config."""

from __future__ import annotations

from pathlib import Path

from gi.repository import Adw, GLib, Gtk

from .model import human_bytes, plain
from .registry import project_config_path
from .runner import Runner, bash_syntax_error, yaml_config_error
from .widgets import OutputView, ProcessTree, human_age


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
    """The project's config, as the file it actually is — YAML or bash.

    A form would be nicer to look at and wrong for the bash format: that config
    is a sourced shell script that may branch, loop or source something else,
    and a structured editor that cannot round-trip it would quietly drop what
    it did not understand. So: edit the text, and refuse to save something the
    tool itself cannot load — `bash -n` for a .sh, `pitcrew check` for a .yaml.
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

    def _problem(self, text: str) -> str:
        """Whatever stops this text from loading, in the config's own format."""
        if self._path.suffix in (".yaml", ".yml"):
            return yaml_config_error(self._runner.pitcrew, text)
        return bash_syntax_error(text)

    def _save(self) -> None:
        text = self._text()
        problem = self._problem(text)
        if problem:
            # Saving a config bash cannot parse breaks every pitcrew command for
            # this project, including the one that would tell you why.
            self._output.show_text(f"not saved — pitcrew could not load this:\n\n{problem}")
            return
        try:
            self._path.write_text(text, encoding="utf-8")
        except OSError as error:
            self._output.show_text(f"could not write {self._path}: {error}")
            return
        self._output.show_text(f"saved {self._path}")
        self._on_saved()

    def _check(self) -> None:
        problem = self._problem(self._text())
        if problem:
            self._output.show_text(f"pitcrew could not load this:\n\n{problem}")
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


class DetailDialog(Adw.Dialog):
    """Everything pitcrew knows about one component.

    Clicking a row used to do nothing, so "why is be-sales down" meant a tab
    switch and a picker. Facts come from the frame that is already on screen;
    the start command is asked for once, on open, because it lives in the config
    and not in the stream — and putting it in the stream would mean shipping
    every project's shell commands in every frame.
    """

    def __init__(self, runner: Runner, project: str, comp: dict, log_dir: str | None,
                 now: float, on_show_logs):
        super().__init__(title=comp["name"], content_width=560)
        name = comp["name"]

        self.comp_name = name
        facts = Adw.PreferencesGroup(title="State")
        self._status = self._row("Status", comp.get("state", "?"))
        facts.add(self._status)
        if comp.get("since") and now:
            facts.add(self._row("Started", f"{human_age(now - comp['since'])} ago"))
        if comp.get("restarts"):
            facts.add(self._row("Restarts", f"{comp['restarts']} in this crash streak"))
        if comp.get("pid"):
            facts.add(self._row("PID", str(comp["pid"])))
        if comp.get("exit") is not None:
            facts.add(self._row("Last exit", str(comp["exit"])))
        self._memory = self._row("Memory",
                                 f"{human_bytes(comp.get('rss'))} of "
                                 f"{human_bytes(comp.get('limit'))} "
                                 f"({comp.get('limitSource', 'role')})")
        facts.add(self._memory)
        if comp.get("url"):
            facts.add(self._link("URL", comp["url"]))
        if comp.get("health"):
            facts.add(self._link("Health", comp["health"]))
        if log_dir:
            facts.add(self._row("Log", f"{log_dir}/{name}.log"))

        actions = Adw.PreferencesGroup()
        logs = Adw.ActionRow(title="Show log", activatable=True)
        logs.add_suffix(Gtk.Image.new_from_icon_name("go-next-symbolic"))
        logs.connect("activated", lambda _r: (on_show_logs(name, False), self.close()))
        actions.add(logs)

        # The process tree. A `gradle bootRun` is a wrapper that forks a daemon
        # that forks the application, so "which of these is actually my
        # service" is the question, and the PID above answers it wrongly.
        self._procs = ProcessTree()
        procs_group = Adw.PreferencesGroup(
            title="Processes", description="Everything in this component's tree, biggest first")
        procs_group.add(self._procs)
        self._procs.set_processes(comp.get("processes") or [])

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                       margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
        body.append(facts)
        body.append(procs_group)
        body.append(actions)

        view = Adw.ToolbarView()
        view.add_top_bar(Adw.HeaderBar())
        view.set_content(Gtk.ScrolledWindow(child=body, propagate_natural_height=True))
        self.set_child(view)

    def update(self, comp: dict) -> None:
        """A later frame for the same component.

        The dialog is not a snapshot of the moment you opened it — watching a
        heap climb is exactly what someone opens this for. The window pushes
        every frame in while it is open.
        """
        self._procs.set_processes(comp.get("processes") or [])
        self._memory.set_subtitle(
            f"{human_bytes(comp.get('rss'))} of {human_bytes(comp.get('limit'))} "
            f"({comp.get('limitSource', 'role')})")
        self._status.set_subtitle(comp.get("state", "?"))

    @staticmethod
    def _row(title: str, value: str) -> Adw.ActionRow:
        return Adw.ActionRow(title=title, subtitle=plain(value), use_markup=False,
                             subtitle_selectable=True)

    @staticmethod
    def _link(title: str, url: str) -> Adw.ActionRow:
        row = Adw.ActionRow(title=title, subtitle=plain(url), use_markup=False,
                            activatable=True, subtitle_selectable=True)
        row.add_suffix(Gtk.Image.new_from_icon_name("web-browser-symbolic"))
        row.connect("activated", lambda _r: Gtk.UriLauncher.new(url).launch(None, None, None, None))
        return row


class DoctorDialog(Adw.Dialog):
    """`pitcrew doctor`, rendered rather than printed.

    doctor answers a different question from diagnose — "can this machine run
    pitcrew at all" rather than "is this stack healthy" — and it was the one
    command with no way into the desktop app. It has a --json mode already, so
    this shows the same facts as rows instead of pasting terminal output into a
    text box.
    """

    def __init__(self, runner: Runner, project: str):
        super().__init__(title="Doctor", content_width=520, content_height=560)
        self._page = Adw.PreferencesPage()
        self._group = Adw.PreferencesGroup(title="Checking…")
        self._page.add(self._group)

        view = Adw.ToolbarView()
        view.add_top_bar(Adw.HeaderBar())
        view.set_content(self._page)
        self.set_child(view)
        runner.run_json(["-p", project, "doctor", "--json"], self._show)

    def _show(self, state: dict | None, problem: str) -> None:
        self._page.remove(self._group)
        if state is None:
            self._group = Adw.PreferencesGroup(title="Could not run doctor")
            self._group.add(Adw.ActionRow(title=plain(problem), use_markup=False))
            self._page.add(self._group)
            return

        env = Adw.PreferencesGroup(title="Environment")
        env.add(self._fact("pitcrew", state.get("version", "?")))
        env.add(self._fact("OS", state.get("os", "?")))
        env.add(self._fact("bash", state.get("bash", "?")))
        env.add(self._fact("Collector", state.get("collector", "?"),
                           "how the meters are read: /proc, or ps"))
        self._page.add(env)

        caps = Adw.PreferencesGroup(title="RAM caps")
        # An unenforceable cap is worth saying out loud: the meters look
        # identical either way, so nothing else on screen distinguishes them.
        caps.add(self._verdict(
            "Enforced by the kernel", state.get("capsEnforced"),
            "measured against, but not applied — there is no cgroup equivalent here"))
        caps.add(self._verdict("The caps fit this machine", state.get("capsFit"),
                               state.get("capsWarning") or ""))
        self._page.add(caps)

        tools = Adw.PreferencesGroup(
            title="Optional tools", description="Each of these degrades with a message, not an error")
        for name, present in (state.get("tools") or {}).items():
            tools.add(self._verdict(name, present, "not installed"))
        self._page.add(tools)

        clashes = state.get("portClashes") or 0
        ports = Adw.PreferencesGroup(title="Ports")
        ports.add(self._verdict(
            "No ports claimed by another project", not clashes,
            f"{clashes} port(s) also claimed elsewhere — each project would report the "
            "other's services as its own"))
        self._page.add(ports)

        deps = state.get("deps") or []
        if deps:
            group = Adw.PreferencesGroup(title="Dependencies")
            for dep in deps:
                group.add(self._verdict(dep.get("name", "?"), dep.get("running"), "not running"))
            self._page.add(group)
        self._group = env

    @staticmethod
    def _fact(title: str, value, subtitle: str = "") -> Adw.ActionRow:
        row = Adw.ActionRow(title=title, subtitle=plain(subtitle), use_markup=False)
        label = Gtk.Label(label=plain(str(value)), valign=Gtk.Align.CENTER)
        label.add_css_class("dim-label")
        row.add_suffix(label)
        return row

    @staticmethod
    def _verdict(title: str, ok, why: str) -> Adw.ActionRow:
        row = Adw.ActionRow(title=plain(title), use_markup=False,
                            subtitle=plain("" if ok else why))
        icon = Gtk.Image(icon_name="object-select-symbolic" if ok else "dialog-warning-symbolic",
                         valign=Gtk.Align.CENTER)
        icon.add_css_class("success" if ok else "warning")
        row.add_suffix(icon)
        return row


class ToolsDialog(Adw.Dialog):
    """The three things that had no way into the GUI at all.

    Ports across every project, the plugins that are extending diagnostics, and
    the shells the project configured. None of them is worth a tab; all of them
    were unreachable without dropping to a terminal, which for a desktop app is
    the same as not existing.
    """

    def __init__(self, runner: Runner, project: str, shells: list[str], on_toast):
        super().__init__(title="Tools", content_width=560, content_height=560)
        self._runner = runner
        self._on_toast = on_toast

        page = Adw.PreferencesPage()

        self._ports = Adw.PreferencesGroup(
            title="Ports",
            description="Every port every registered project claims — and any claimed twice")
        self._ports_view = OutputView(height=180)
        self._ports_view.show_text("reading…")
        self._ports.add(self._ports_view)
        page.add(self._ports)

        self._plugins = Adw.PreferencesGroup(
            title="Plugins",
            description="Diagnostic checks loaded from ~/.config/pitcrew/plugins")
        self._plugins_view = OutputView(height=140)
        self._plugins_view.show_text("reading…")
        self._plugins.add(self._plugins_view)
        page.add(self._plugins)

        # A GTK app cannot host an interactive psql, and pretending otherwise
        # would be worse than not offering it. Handing over the exact command
        # is the honest version.
        if shells:
            group = Adw.PreferencesGroup(
                title="Shells",
                description="Configured in this project. Copy one and run it in a terminal.")
            for name in shells:
                row = Adw.ActionRow(title=plain(name), use_markup=False,
                                    subtitle=f"pitcrew -p {project} shell {name}",
                                    subtitle_selectable=True)
                button = Gtk.Button(icon_name="edit-copy-symbolic", valign=Gtk.Align.CENTER,
                                    tooltip_text="Copy the command")
                button.add_css_class("flat")
                button.connect("clicked", lambda _b, n=name: self._copy(
                    f"pitcrew -p {project} shell {n}"))
                row.add_suffix(button)
                group.add(row)
            page.add(group)

        view = Adw.ToolbarView()
        view.add_top_bar(Adw.HeaderBar())
        view.set_content(page)
        self.set_child(view)

        runner.run(["ports"], lambda ok, out: self._ports_view.show_text(
            out or ("no projects registered" if ok else "could not read the port map")))
        runner.run(["-p", project, "plugins"], lambda ok, out: self._plugins_view.show_text(
            out or ("no plugins" if ok else "could not list plugins")))

    def _copy(self, text: str) -> None:
        self.get_clipboard().set(text)
        self._on_toast("copied")


class ProfilesDialog(Adw.Dialog):
    """Saved sets of targets: start one, save what is running, delete one.

    The GUI could already START a profile from the menu and had no way to make
    or remove one, which meant profiles were a terminal feature that the desktop
    app happened to be able to trigger. Saving is the half that matters — the
    set you want is the set you have running right now, and naming it is the
    only step a person has to do.
    """

    def __init__(self, runner: Runner, project: str, running: list[str],
                 profiles: list[str], on_changed, on_toast):
        super().__init__(title="Profiles", content_width=520, content_height=460)
        self._runner = runner
        self._project = project
        self._running = running
        self._on_changed = on_changed
        self._on_toast = on_toast

        self._page = Adw.PreferencesPage()

        save = Adw.PreferencesGroup(
            title="Save what is running",
            description=(f"{len(running)} component(s): " + ", ".join(running))
            if running else "Nothing is running to save")
        self._name = Adw.EntryRow(title="Profile name")
        self._name.set_sensitive(bool(running))
        button = Gtk.Button(label="Save", valign=Gtk.Align.CENTER, sensitive=bool(running))
        button.add_css_class("suggested-action")
        button.connect("clicked", lambda _b: self._save())
        self._name.add_suffix(button)
        save.add(self._name)
        self._page.add(save)

        self._existing = Adw.PreferencesGroup(title="Saved")
        self._rows: list[Adw.ActionRow] = []
        self._fill(profiles)
        self._page.add(self._existing)

        view = Adw.ToolbarView()
        view.add_top_bar(Adw.HeaderBar())
        view.set_content(self._page)
        self.set_child(view)

    def _fill(self, profiles: list[str]) -> None:
        for row in self._rows:
            self._existing.remove(row)
        self._rows.clear()
        if not profiles:
            row = Adw.ActionRow(title="No profiles yet", use_markup=False,
                                subtitle="Start the components you want, then save them above")
            self._existing.add(row)
            self._rows.append(row)
            return
        for name in profiles:
            row = Adw.ActionRow(title=plain(f"@{name}"), use_markup=False)
            box = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
            start = Gtk.Button(icon_name="media-playback-start-symbolic",
                               tooltip_text=f"Start @{name}")
            start.add_css_class("flat")
            start.connect("clicked", lambda _b, n=name: self._start(n))
            box.append(start)
            delete = Gtk.Button(icon_name="user-trash-symbolic", tooltip_text="Delete")
            delete.add_css_class("flat")
            delete.connect("clicked", lambda _b, n=name: self._delete(n))
            box.append(delete)
            row.add_suffix(box)
            self._existing.add(row)
            self._rows.append(row)

    def _save(self) -> None:
        name = self._name.get_text().strip()
        if not name or not self._running:
            return
        self._runner.run(
            ["-p", self._project, "profile", "save", name, *self._running],
            lambda ok, out: self._done(ok, out, f"saved @{name}"))

    def _start(self, name: str) -> None:
        self._runner.run(["-p", self._project, "start", f"@{name}"],
                         lambda ok, out: self._done(ok, out, f"starting @{name}", refresh=False))

    def _delete(self, name: str) -> None:
        self._runner.run(["-p", self._project, "profile", "rm", name],
                         lambda ok, out: self._done(ok, out, f"deleted @{name}"))

    def _done(self, ok: bool, output: str, message: str, refresh: bool = True) -> None:
        if not ok:
            self._on_toast((output or "").strip().splitlines()[-1:][0] if output else "failed")
            return
        self._on_toast(message)
        self._name.set_text("")
        if refresh:
            self._fill(self._on_changed())

