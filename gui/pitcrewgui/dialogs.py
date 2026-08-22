"""Dialogs that change pitcrew itself: adding a project, editing its config."""

from __future__ import annotations

from pathlib import Path

from gi.repository import Adw, GLib, Gtk

from .model import human_bytes, plain
from .registry import project_config_path
from .runner import Runner, bash_syntax_error, yaml_config_error
from .widgets import OutputView, ProcessTree, human_age
from .yamledit import add_block, set_value


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

# The fields a component has, in the order they are worth reading: what it
# runs, then where, then how it is reached, then the switches. Each is one
# dotted path under `apps.<app>.<role>`.
_COMPONENT_FIELDS = (
    ("cmd",    "Command",    "what starts this component"),
    ("root",   "Checkout",   "its own repository — leave empty to use the project root"),
    ("dir",    "Directory",  "relative to the checkout above"),
    ("port",   "Port",       "how pitcrew tells whether it is up"),
    ("health", "Health path", "must answer UP before the component counts as up"),
    ("max",    "RAM cap",    "overrides the role default, e.g. 2G"),
)


class ConfigDialog(Adw.Dialog):
    """The project's config: as a form, and as the file it actually is.

    The form is the point — an app is an open GROUP of components now, and
    hand-indenting a fourth role into a YAML file is exactly the friction this
    is here to remove. But it edits FIELDS, and every save is a targeted line
    edit through yamledit.py rather than a regenerated file. A config is
    something people write and annotate, and an editor that rewrites it
    wholesale hands back a file with every comment gone.

    Two things the form cannot be, and both have the same answer — the YAML tab:

      * complete. A config may hold keys this form knows nothing about, and a
        form that could not round-trip them would quietly drop them.
      * the bash format. A pitcrew.config.sh is a sourced shell script that may
        branch, loop or source something else. There is no form for that, so
        a .sh config opens on the text and the form tab is not offered.

    Either way, nothing is saved that the tool itself cannot load: `pitcrew
    check` for a .yaml, `bash -n` for a .sh.
    """

    def __init__(self, runner: Runner, name: str, on_saved):
        super().__init__(title=f"{name} · config", content_width=820, content_height=680)
        self._runner = runner
        self._name = name
        self._on_saved = on_saved
        self._path = project_config_path(name)
        self._is_yaml = self._path.suffix in (".yaml", ".yml")
        self._config: dict | None = None
        self._rows: dict[tuple[str, ...], Gtk.Widget] = {}
        # The groups THIS dialog added. Adw.PreferencesPage.observe_children()
        # hands back its own scaffolding as well, so rebuilding the form from
        # that list removes the wrong widgets.
        self._groups: list[Adw.PreferencesGroup] = []
        self._loading = False

        self._buffer = Gtk.TextBuffer()
        try:
            self._buffer.set_text(self._path.read_text(encoding="utf-8"))
            editable = True
        except OSError as error:
            self._buffer.set_text(f"# cannot read {self._path}: {error}")
            editable = False
        self._editable = editable

        view = Gtk.TextView(buffer=self._buffer, monospace=True, editable=editable,
                            top_margin=10, bottom_margin=10, left_margin=10, right_margin=10)
        scroller = Gtk.ScrolledWindow(child=view, vexpand=True)
        scroller.add_css_class("card")

        self._output = OutputView(height=120)
        self._output.show_text(str(self._path))

        self._form = Adw.PreferencesPage()
        self._stack = Adw.ViewStack()
        if self._is_yaml:
            self._stack.add_titled_with_icon(self._form, "form", "Apps",
                                             "view-list-symbolic")
        self._stack.add_titled_with_icon(scroller, "yaml", "YAML",
                                         "text-x-generic-symbolic")

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10,
                       margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
        body.append(self._stack)
        self._stack.set_vexpand(True)
        body.append(self._output)

        wrapper = Adw.ToolbarView()
        wrapper.add_top_bar(self._header(editable))
        wrapper.set_content(body)
        self.set_child(wrapper)

        if self._is_yaml:
            self._reload_form()

    def _header(self, editable: bool) -> Adw.HeaderBar:
        save = Gtk.Button(label="Save", sensitive=editable)
        save.add_css_class("suggested-action")
        save.connect("clicked", lambda _b: self._save())
        check = Gtk.Button(label="Check")
        check.connect("clicked", lambda _b: self._check())

        header = Adw.HeaderBar()
        header.pack_end(save)
        header.pack_start(check)
        if self._is_yaml:
            header.set_title_widget(Adw.ViewSwitcher(stack=self._stack,
                                                     policy=Adw.ViewSwitcherPolicy.WIDE))
        else:
            # The way out of the text editor. A .sh config gets no form, and
            # the ones that most need one are exactly the ones a form cannot
            # touch — six apps built from a `for` loop over a `declare -A` of
            # ports is compact to write and unreadable to anyone asking what
            # port sales is on. The offer belongs where the problem is.
            convert = Gtk.Button(label="Convert to YAML")
            convert.set_tooltip_text("write the equivalent pitcrew.yaml, "
                                     "then edit it as a form")
            convert.connect("clicked", lambda _b: self._ask_convert())
            header.pack_start(convert)
        return header

    # ── the form ────────────────────────────────────────────────────────────
    #
    # Every value on it comes from `pitcrew config --json`, which is pitcrew
    # reading its own config. The GUI carrying a second YAML parser is how it
    # would come to accept a file the tool rejects.

    def _reload_form(self) -> None:
        self._runner.run_json(["-p", self._name, "config", "--json"], self._form_ready)

    def _form_ready(self, config: dict | None, problem: str) -> None:
        if config is None:
            self._output.show_text(
                f"could not read the config as a form — edit it as YAML instead\n\n{problem}")
            self._stack.set_visible_child_name("yaml")
            return
        self._config = config
        self._build_form(config)

    def _build_form(self, config: dict) -> None:
        self._loading = True
        for group in self._groups:
            self._form.remove(group)
        self._groups = []
        self._rows = {}

        project = Adw.PreferencesGroup(title="Project",
                                       description=str(self._path))
        project.add(self._entry(("name",), "Name", config.get("name") or "",
                                "shown in the header and the dashboard title"))
        project.add(self._entry(("emoji",), "Emoji", config.get("emoji") or "", ""))
        self._add_group(project)

        for app in config.get("apps") or []:
            self._add_group(self._app_group(app))

        add = Adw.PreferencesGroup()
        button = Gtk.Button(label="Add an app", halign=Gtk.Align.CENTER)
        button.connect("clicked", lambda _b: self._add_app())
        add.add(button)
        self._add_group(add)
        self._loading = False

    def _add_group(self, group: Adw.PreferencesGroup) -> None:
        self._form.add(group)
        self._groups.append(group)

    def _app_group(self, app: dict) -> Adw.PreferencesGroup:
        name = app["name"]
        components = app.get("components") or []
        roles = ", ".join(c["role"] for c in components) or "no components yet"
        group = Adw.PreferencesGroup(title=name, description=roles)

        add = Gtk.Button(icon_name="list-add-symbolic",
                         tooltip_text="add a component to this group")
        add.add_css_class("flat")
        add.connect("clicked", lambda _b, a=name: self._add_component(a))
        group.set_header_suffix(add)

        group.add(self._entry(("apps", name, "url_path"), "URL path",
                              app.get("urlPath") or "",
                              "appended to every non-frontend URL for this app"))
        group.add(self._entry(("apps", name, "root"), "Checkout",
                              app.get("root") or "",
                              "one repository for the whole group; a component can still differ"))
        for comp in components:
            group.add(self._component_row(name, comp))
        return group

    def _component_row(self, app: str, comp: dict) -> Adw.ExpanderRow:
        role = comp["role"]
        base = ("apps", app, role)
        row = Adw.ExpanderRow(title=role, subtitle=comp.get("cmd") or "no command")

        # The exclusion switch, on the row rather than buried inside it: it is
        # the one field you flip without wanting to read anything else.
        toggle = Gtk.Switch(active=bool(comp.get("enabled", True)),
                            valign=Gtk.Align.CENTER,
                            tooltip_text="off: skipped by `start all`, still listed")
        toggle.connect("notify::active", self._enabled_changed, base)
        row.add_suffix(toggle)

        for key, title, blurb in _COMPONENT_FIELDS:
            value = comp.get(key)
            row.add_row(self._entry((*base, key), title,
                                    "" if value in (None, "") else str(value), blurb))
        row.add_row(self._switch((*base, "protected"), "Protected",
                                 bool(comp.get("protected")),
                                 "never proposed for stopping to free memory"))

        remove = Adw.ActionRow(title="Remove this component")
        button = Gtk.Button(label="Remove", valign=Gtk.Align.CENTER)
        button.add_css_class("destructive-action")
        button.connect("clicked", lambda _b, a=app, r=role: self._remove_component(a, r))
        remove.add_suffix(button)
        row.add_row(remove)
        return row

    def _entry(self, path: tuple[str, ...], title: str, value: str,
               blurb: str) -> Adw.EntryRow:
        row = Adw.EntryRow(title=title, text=value)
        if blurb:
            row.set_tooltip_text(blurb)
        row.connect("apply", self._entry_applied, path)
        # `apply` fires on Enter; leaving the field has to count too, or a value
        # typed and then clicked away from is silently discarded.
        controller = Gtk.EventControllerFocus()
        controller.connect("leave", lambda _c, r=row, p=path: self._entry_applied(r, p))
        row.add_controller(controller)
        row.set_show_apply_button(True)
        self._rows[path] = row
        return row

    def _switch(self, path: tuple[str, ...], title: str, value: bool,
                blurb: str) -> Adw.SwitchRow:
        row = Adw.SwitchRow(title=title, subtitle=blurb, active=value)
        row.connect("notify::active", self._switch_changed, path)
        self._rows[path] = row
        return row

    # ── turning a changed field into an edit ────────────────────────────────

    def _entry_applied(self, row: Adw.EntryRow, path: tuple[str, ...]) -> None:
        if self._loading:
            return
        text = row.get_text().strip()
        self._apply(path, text or None)

    def _switch_changed(self, row: Adw.SwitchRow, _param,
                        path: tuple[str, ...]) -> None:
        if self._loading:
            return
        self._apply(path, "true" if row.get_active() else None)

    def _enabled_changed(self, switch: Gtk.Switch, _param,
                         base: tuple[str, ...]) -> None:
        if self._loading:
            return
        # `enabled: true` is the default, so switching it back ON removes the
        # key rather than writing a line that says nothing.
        self._apply((*base, "enabled"), None if switch.get_active() else "false")

    # The two fields the form writes itself rather than taking from a text box.
    # They go in unquoted, because `enabled: "false"` is correct YAML and not
    # something anybody would have typed.
    _BOOLEAN_KEYS = ("enabled", "protected")

    def _apply(self, path: tuple[str, ...], value: str | None) -> None:
        """One field → one line edit, checked before it is written."""
        current = self._text()
        try:
            updated = set_value(current, path, value,
                                literal=path[-1] in self._BOOLEAN_KEYS)
        except LookupError as missing:
            self._output.show_text(
                f"cannot edit {'.'.join(path)} from the form — {missing} is not "
                f"somewhere this can safely change.\nEdit it on the YAML tab.")
            return
        if updated == current:
            return
        self._set_text(updated)
        self._output.show_text(f"{'.'.join(path)} → {value if value is not None else '(removed)'}"
                               "   ·   not written yet — press Save")

    def _add_component(self, app: str) -> None:
        self._ask("Role name", "worker",
                  "letters, digits and _ — it becomes half of a component id",
                  lambda role: self._do_add_component(app, role))

    def _do_add_component(self, app: str, role: str) -> None:
        if not role.replace("_", "").isalnum():
            self._output.show_text(
                f"'{role}' cannot be a role: a component is named <role>-<app>, "
                "split on the first dash, so a role is letters, digits or _.")
            return
        try:
            updated = add_block(self._text(), ("apps", app, role),
                                [("cmd", "true")])
        except LookupError as error:
            self._output.show_text(f"could not add it: {error} — edit the YAML tab")
            return
        self._set_text(updated)
        self._output.show_text(f"added {role}-{app} with a placeholder command "
                               "— set it below, then Save")
        self._save(reload_form=True)

    def _remove_component(self, app: str, role: str) -> None:
        try:
            updated = set_value(self._text(), ("apps", app, role), None)
        except LookupError as error:
            self._output.show_text(f"could not remove it: {error}")
            return
        self._set_text(updated)
        self._save(reload_form=True)

    def _add_app(self) -> None:
        self._ask("App name", "shop", "the group these components belong to",
                  self._do_add_app)

    def _do_add_app(self, name: str) -> None:
        if not name or "." in name or " " in name:
            self._output.show_text("an app name cannot be empty or contain a dot or a space")
            return
        try:
            updated = add_block(self._text(), ("apps", name), [])
            updated = add_block(updated, ("apps", name, "be"), [("cmd", "true")])
        except LookupError as error:
            self._output.show_text(f"could not add it: {error} — edit the YAML tab")
            return
        self._set_text(updated)
        self._save(reload_form=True)

    def _ask(self, title: str, placeholder: str, blurb: str, on_ok) -> None:
        dialog = Adw.AlertDialog(heading=title, body=blurb)
        entry = Gtk.Entry(placeholder_text=placeholder, activates_default=True)
        dialog.set_extra_child(entry)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("ok", "Add")
        dialog.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("ok")
        dialog.connect("response",
                       lambda _d, r: r == "ok" and on_ok(entry.get_text().strip()))
        dialog.present(self)

    def _set_text(self, text: str) -> None:
        self._buffer.set_text(text)

    def _text(self) -> str:
        start, end = self._buffer.get_bounds()
        return self._buffer.get_text(start, end, False)

    def _problem(self, text: str) -> str:
        """Whatever stops this text from loading, in the config's own format."""
        if self._path.suffix in (".yaml", ".yml"):
            return yaml_config_error(self._runner.pitcrew, text)
        return bash_syntax_error(text)

    def _save(self, reload_form: bool = False) -> None:
        text = self._text()
        problem = self._problem(text)
        if problem:
            # Saving a config the tool cannot parse breaks every pitcrew command
            # for this project, including the one that would tell you why.
            self._output.show_text(f"not saved — pitcrew could not load this:\n\n{problem}")
            return
        try:
            self._path.write_text(text, encoding="utf-8")
        except OSError as error:
            self._output.show_text(f"could not write {self._path}: {error}")
            return
        self._output.show_text(f"saved {self._path}")
        self._on_saved()
        # Adding or removing a component changes the SHAPE of the form, so it
        # is rebuilt from what pitcrew now reads back — not from what this
        # dialog believes it just wrote.
        if reload_form and self._is_yaml:
            self._reload_form()

    # ── converting a bash config ────────────────────────────────────────────

    def _ask_convert(self) -> None:
        dialog = Adw.AlertDialog(
            heading="Convert to YAML?",
            body=("pitcrew has already run this config, so it can write out what "
                  "it actually says — every app a loop produced, spelled out.\n\n"
                  "The result is loaded and compared against this one field by "
                  "field before anything is written; nothing is written if they "
                  "differ. Your .sh file is left alone."))
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("go", "Convert")
        dialog.set_response_appearance("go", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("go")
        dialog.connect("response", lambda _d, r: r == "go" and self._convert())
        dialog.present(self)

    def _convert(self) -> None:
        self._output.show_text("converting…")
        self._runner.run(["-p", self._name, "migrate"], self._converted)

    def _converted(self, ok: bool, output: str) -> None:
        # pitcrew's own words, verbatim — including the warnings about what
        # YAML cannot carry, which are the parts somebody has to port by hand.
        self._output.show_text(output or ("converted" if ok else "conversion failed"))
        if not ok:
            return
        self._on_saved()
        # The dialog is bound to the .sh path it opened; the YAML is a
        # different file. Closing and letting it be reopened is honest, and
        # cheaper than re-resolving every path this dialog holds.
        GLib.timeout_add(1200, self._close_after_convert)

    def _close_after_convert(self) -> bool:
        self.close()
        return False

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

