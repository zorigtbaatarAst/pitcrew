"""Dialogs that change pitcrew itself: adding a project, editing its config."""

from __future__ import annotations

from pathlib import Path

from gi.repository import Adw, GLib, Gtk

from .model import human_bytes, plain, plugin_rows, port_conflicts, port_rows
from .registry import project_config_path
from .runner import Runner, bash_syntax_error, yaml_config_error
from .widgets import OutputView, ProcessTree, code_view, human_age
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



def _plain_subtitle(row, text: str, lines: int = 1) -> None:
    """A subtitle that is TEXT, not markup.

    Adw renders a row's subtitle as Pango markup by default, and a real start
    command has `&&` in it — which is not an entity, so the whole line failed
    to parse and rendered as nothing at all. The order matters: setting the
    subtitle in the constructor happens before `use-markup` gets there.
    """
    row.set_use_markup(False)
    row.set_subtitle(text)
    row.set_subtitle_lines(lines)

def _detected_summary(app: dict) -> str:
    """One line describing what pitcrew would write for a detected app."""
    parts = []
    for comp in app.get("components") or []:
        port = comp.get("port")
        parts.append(f"{comp['role']}: {comp.get('cmd') or '?'}"
                     + (f"  ·  :{port}" if port else ""))
    return "\n".join(parts) or "nothing to start"


def _detected_fields(comp: dict) -> list[tuple[str, str]]:
    """A detected component, in the order `pitcrew init` writes the same keys."""
    fields: list[tuple[str, str]] = []
    if comp.get("dir"):
        fields.append(("dir", comp["dir"]))
    fields.append(("cmd", comp.get("cmd") or "true"))
    if comp.get("port"):
        fields.append(("port", str(comp["port"])))
    if comp.get("health"):
        fields.append(("health", comp["health"]))
    return fields

# An Adw.Dialog cannot be resized by the user, so its size is a decision made
# here, once. Wide enough for a `--be-cmd` line without wrapping, and tall
# enough that the editor and the output panel below it are both usable.
CONFIG_WIDTH = 820
CONFIG_HEIGHT = 680

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

    def __init__(self, runner: Runner, name: str, on_saved, on_converted=None):
        super().__init__(title=f"{name} · config",
                         content_width=CONFIG_WIDTH, content_height=CONFIG_HEIGHT)
        self._runner = runner
        self._name = name
        self._on_saved = on_saved
        # Reopens this dialog on whatever the config turned into. Optional: the
        # conversion is the only thing that needs it.
        self._on_converted = on_converted
        self._converted_to: Path | None = None
        self._convert: Gtk.Button | None = None
        self._path = project_config_path(name)
        self._is_yaml = self._path.suffix in (".yaml", ".yml")
        self._config: dict | None = None
        self._rows: dict[tuple[str, ...], Gtk.Widget] = {}
        # The groups THIS dialog added. Adw.PreferencesPage.observe_children()
        # hands back its own scaffolding as well, so rebuilding the form from
        # that list removes the wrong widgets.
        self._groups: list[Adw.PreferencesGroup] = []
        self._loading = False

        try:
            text = self._path.read_text(encoding="utf-8")
            editable = True
        except OSError as error:
            text = f"# cannot read {self._path}: {error}"
            editable = False
        self._editable = editable

        # Highlighted as what it IS. A pitcrew.config.sh is a shell script and
        # a pitcrew.yaml is YAML, and the tab that opens on a .sh config used
        # to be the same undifferentiated grey as the one that opens on YAML.
        view, self._buffer = code_view(text, "yaml" if self._is_yaml else "sh",
                                       editable)
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

        # A dialog cannot be resized, and what lands in the output panel is not
        # a line or two: `doctor` reports every port this machine argues with
        # itself about, and `migrate` reports what it could not carry over. A
        # fixed strip meant reading those six lines at a time, so the two share
        # the height and the handle between them belongs to whoever is reading.
        # Neither half can be collapsed onto the other — a panel you can lose
        # by dragging is a panel somebody will lose.
        body = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL,
                         resize_start_child=True, resize_end_child=False,
                         shrink_start_child=False, shrink_end_child=False,
                         margin_top=12, margin_bottom=12,
                         margin_start=12, margin_end=12)
        self._stack.set_vexpand(True)
        body.set_start_child(self._stack)
        body.set_end_child(self._output)
        body.set_position(CONFIG_HEIGHT - 230)

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
            convert.connect("clicked", lambda _b: self._convert_clicked())
            header.pack_start(convert)
            self._convert = convert
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
        row = Adw.ExpanderRow(title=role)
        _plain_subtitle(row, comp.get("cmd") or "no command")

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

    # ── adding an app ───────────────────────────────────────────────────────
    #
    # Asking for a name and writing `cmd: "true"` under it left the actual work
    # — `./gradlew :backend:bootRun`, the port, the health path — to be typed
    # by hand into a form, for a project pitcrew can read. So this asks pitcrew
    # what is in the checkout first, and offers that.
    #
    # `pitcrew detect --json`, not a scan written here: `init` guesses from the
    # same function, and an app that offered a component `init` would never
    # write is a second opinion about somebody's project.

    def _add_app(self) -> None:
        root = (self._config or {}).get("root") or str(self._path.parent)
        self._output.show_text(f"looking at {root} …")
        self._runner.run_json(["detect", "--json", root], self._detected)

    def _detected(self, found: dict | None, problem: str) -> None:
        # Nothing recognisable is not a failure — plenty of projects are
        # started by a command no detector could guess. It just means the empty
        # app is the only thing left to offer.
        if found is None:
            self._output.show_text(f"could not look at the project:\n\n{problem}")
            self._ask_app_name()
            return
        known = {app["name"] for app in (self._config or {}).get("apps") or []}
        fresh = [app for app in (found.get("apps") or []) if app["name"] not in known]
        if not fresh:
            self._output.show_text(
                "pitcrew found nothing here that this config does not already have")
            self._ask_app_name()
            return
        self._offer_detected(fresh)

    def _offer_detected(self, apps: list[dict]) -> None:
        group = Adw.PreferencesGroup()
        switches: list[tuple[dict, Adw.SwitchRow]] = []
        for app in apps:
            row = Adw.SwitchRow(title=app["name"], active=True)
            _plain_subtitle(row, _detected_summary(app), lines=2)
            group.add(row)
            switches.append((app, row))

        box = Gtk.ScrolledWindow(child=group, min_content_height=min(360, 84 * len(apps)),
                                 propagate_natural_height=True, hexpand=True)
        dialog = Adw.AlertDialog(
            heading="Add an app",
            body=("pitcrew read the checkout. These are the commands and ports it "
                  "would write for what it found — a guess, and an editable one."))
        dialog.set_extra_child(box)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("empty", "Empty app…")
        dialog.add_response("add", "Add")
        dialog.set_response_appearance("add", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("add")
        dialog.connect("response", lambda _d, r: self._offer_answered(r, switches))
        dialog.present(self)

    def _offer_answered(self, response: str, switches) -> None:
        if response == "empty":
            self._ask_app_name()
            return
        if response != "add":
            return
        chosen = [app for app, row in switches if row.get_active()]
        if chosen:
            self._add_detected(chosen)

    def _add_detected(self, apps: list[dict]) -> None:
        text = self._text()
        try:
            text = self._ensure_apps(text)
            for app in apps:
                text = add_block(text, ("apps", app["name"]), [])
                for comp in app.get("components") or []:
                    text = add_block(text, ("apps", app["name"], comp["role"]),
                                     _detected_fields(comp))
        except LookupError as error:
            self._output.show_text(f"could not add it: {error} — edit the YAML tab")
            return
        self._set_text(text)
        self._save(reload_form=True)
        self._output.show_text(
            "added " + ", ".join(app["name"] for app in apps)
            + "\n\nThe commands are pitcrew's guess at how this project starts. "
              "Check them here before you start anything with them.")

    def _ensure_apps(self, text: str) -> str:
        """`apps:` has to exist before an app can be added under it."""
        try:
            return add_block(text, ("apps",), [])
        except LookupError:                 # it is already there
            return text

    def _ask_app_name(self) -> None:
        self._ask("App name", "shop", "the group these components belong to",
                  self._do_add_app)

    def _do_add_app(self, name: str) -> None:
        if not name or "." in name or " " in name:
            self._output.show_text("an app name cannot be empty or contain a dot or a space")
            return
        try:
            updated = self._ensure_apps(self._text())
            updated = add_block(updated, ("apps", name), [])
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
                  "differ. Your .sh file is left alone.\n\n"
                  "It is written as pitcrew.yaml next to it, and this project's "
                  "registry entry is repointed at it — pitcrew reads the new "
                  "file from then on."))
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("go", "Convert")
        dialog.set_response_appearance("go", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("go")
        dialog.connect("response", lambda _d, r: r == "go" and self._run_convert())
        dialog.present(self)

    def _convert_clicked(self) -> None:
        if self._converted_to is None:
            self._ask_convert()
            return
        self._open_converted()

    def _run_convert(self) -> None:
        self._output.show_text("converting…")
        self._runner.run(["-p", self._name, "migrate"], self._converted)

    def _converted(self, ok: bool, output: str) -> None:
        # pitcrew's own words, verbatim — including the warnings about what
        # YAML cannot carry, which are the parts somebody has to port by hand.
        if not ok:
            self._output.show_text(output or "conversion failed")
            return
        self._on_saved()
        # Where the file went, asked of pitcrew rather than scraped out of that
        # output: the registry now points at the new config, so re-resolving
        # this project's config path IS the answer. It used to close itself a
        # second later, which threw away both the warnings and the one line
        # saying where to look — hence a button, pressed once they are read.
        path = project_config_path(self._name)
        self._converted_to = path if path != self._path else None
        headline = ""
        if self._converted_to is not None:
            headline = (f"wrote {self._converted_to}\n"
                        "pitcrew reads that file now — “Open the YAML” to edit it here.\n\n")
            if self._convert is not None:
                self._convert.set_label("Open the YAML")
                self._convert.set_tooltip_text(str(self._converted_to))
                self._convert.add_css_class("suggested-action")
        self._output.show_text(headline + (output or "converted"))

    def _open_converted(self) -> None:
        # This dialog is bound to the .sh path it opened; the YAML is a
        # different file, and one with a form tab the .sh cannot have. Reopening
        # on it is honest, and cheaper than re-resolving every path this dialog
        # holds.
        self.close()
        if self._on_converted is not None:
            self._on_converted()

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

    ── why this stopped being two text boxes ──

    Ports and plugins used to arrive as the CLI's own output, dropped verbatim
    into a 180px monospace scroller. That is a terminal pane wearing a dialog,
    and it was worse than the terminal in three specific ways:

      - Nested scrolling. Two short boxes inside a scrolling page, so reaching
        the bottom of either meant scrolling a thing inside a thing.
      - It wrapped mid-token. `property-registration-v2/be-notification-api`
        broke across lines at a character boundary, which is the one place a
        name must not break.
      - The port CLASHES — the only actionable thing in the whole dialog, and
        the reason to open it — were last, below the fold, in the smaller of
        the two boxes.

    And the plugins box rendered the CLI's onboarding paragraph, which teaches
    `diag_register my_check slow`: a thing you type in a shell, shown in a
    window that has no shell.

    Both are now read as JSON and rendered as rows. The shaping is in
    model.port_conflicts / port_rows / plugin_rows, which are pure and tested.
    """

    # ── escaping, which is the opposite of what it looks like ──
    #
    # `use_markup=False` means the string is NOT parsed, so it must NOT be
    # escaped: an apostrophe put through model.plain renders as the literal
    # `&apos;`. Verified on this libadwaita for AdwActionRow, AdwExpanderRow
    # and GtkLabel alike. Group titles and DESCRIPTIONS are a different matter
    # — they have no use-markup property, are always parsed, and do need
    # escaping when they carry a value rather than a literal.

    def __init__(self, runner: Runner, project: str, shells: list[str], on_toast):
        super().__init__(title="Tools", content_width=560, content_height=620)
        self._runner = runner
        self._on_toast = on_toast

        page = Adw.PreferencesPage()

        # Clashes lead. They are the finding, not a footnote to the port map,
        # and this group hides itself entirely when there are none rather than
        # standing there empty saying everything is fine.
        self._clashes = Adw.PreferencesGroup(
            title="Claimed twice",
            description=("pitcrew reads a component as up from its port, so running "
                         "both at once makes each report the other's services as its own."))
        self._clashes.set_visible(False)
        page.add(self._clashes)

        self._ports = Adw.PreferencesGroup(
            title="Ports",
            description="Every port every registered project claims")
        page.add(self._ports)

        self._plugins = Adw.PreferencesGroup(
            title="Plugins",
            description="Diagnostic checks loaded from ~/.config/pitcrew/plugins")
        page.add(self._plugins)

        self._clash_rows: list[Gtk.Widget] = []
        self._port_rows: list[Gtk.Widget] = []
        self._plugin_rows: list[Gtk.Widget] = []
        self._busy(self._ports, self._port_rows, "Reading the port map…")
        self._busy(self._plugins, self._plugin_rows, "Reading plugins…")

        # A GTK app cannot host an interactive psql, and pretending otherwise
        # would be worse than not offering it. Handing over the exact command
        # is the honest version.
        if shells:
            group = Adw.PreferencesGroup(
                title="Shells",
                description="Configured in this project. Copy one and run it in a terminal.")
            for name in shells:
                row = Adw.ActionRow(title=name, use_markup=False,
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

        # The port map is the registry's answer, not this project's — the same
        # payload the Projects page reads, so the two cannot disagree.
        runner.run_json(["projects", "--json"], self._render_ports)
        runner.run_json(["-p", project, "plugins", "--json"], self._render_plugins)

    # ── rows ────────────────────────────────────────────────────────────────

    @staticmethod
    def _clear(group, rows: list) -> None:
        for row in rows:
            group.remove(row)
        rows.clear()

    @staticmethod
    def _busy(group, rows: list, text: str) -> None:
        row = Adw.ActionRow(title=text, use_markup=False)
        row.add_css_class("dim-label")
        group.add(row)
        rows.append(row)

    def _render_ports(self, state: dict | None, problem: str) -> None:
        self._clear(self._ports, self._port_rows)
        self._clear(self._clashes, self._clash_rows)

        if problem:
            self._message(self._ports, self._port_rows, "Could not read the port map",
                          problem)
            return

        for clash in port_conflicts(state):
            # One claimant per line. Side by side with a "vs" between them the
            # pair runs to about eighty characters, which at this width wraps —
            # and it wraps INSIDE a name, splitting `fe-frontoffice` across two
            # lines at the hyphen. That was the original complaint about the
            # text box; reproducing it in a row would be no improvement at all.
            row = Adw.ActionRow(
                title=f"port {clash['port']}", use_markup=False,
                subtitle=f"{clash['a']}\n{clash['b']}")
            row.set_subtitle_lines(2)
            icon = Gtk.Image(icon_name="dialog-warning-symbolic", valign=Gtk.Align.CENTER)
            icon.add_css_class("warning")
            row.add_prefix(icon)
            self._clashes.add(row)
            self._clash_rows.append(row)
        self._clashes.set_visible(bool(self._clash_rows))

        projects = port_rows(state)
        if not projects:
            self._message(self._ports, self._port_rows, "No projects registered",
                          "Add one and its ports appear here")
            return

        for entry in projects:
            self._ports.add(self._project_ports_row(entry))

    def _project_ports_row(self, entry: dict) -> Adw.ExpanderRow:
        """One project, collapsed, with its ports inside.

        Collapsed by default because a monorepo claims a dozen ports and three
        registered projects would otherwise be forty rows before the Plugins
        heading. The current project opens itself — it is the one being asked
        about — and any project with a clash opens too, since a warning behind
        a closed expander is a warning nobody sees.
        """
        ports = entry["ports"]
        clashing = entry["clashing"]
        count = len(ports)
        row = Adw.ExpanderRow(
            title=entry["name"], use_markup=False,
            subtitle=(f"{count} port{'s' if count != 1 else ''}"
                      if count else "no ports configured"))
        row.set_expanded(bool(entry["current"] or clashing))

        # One box, or the badge and the icon sit flush against each other and
        # against the expander arrow.
        marks = Gtk.Box(spacing=8, valign=Gtk.Align.CENTER)
        if clashing:
            icon = Gtk.Image(icon_name="dialog-warning-symbolic", valign=Gtk.Align.CENTER)
            icon.add_css_class("warning")
            icon.set_tooltip_text("shares a port with another project")
            marks.append(icon)
        if entry["current"]:
            badge = Gtk.Label(label="current", valign=Gtk.Align.CENTER)
            badge.add_css_class("caption")
            badge.add_css_class("accent")
            marks.append(badge)
        row.add_suffix(marks)

        for port in ports:
            number = port.get("port")
            # Port as the title, component as a suffix, so a port is ONE row.
            # As title-over-subtitle each port cost two lines, and six ports
            # then filled the dialog on their own — the port map is a thing you
            # scan down, not read.
            child = Adw.ActionRow(title=str(number), use_markup=False)
            name = Gtk.Label(label=port.get("component") or "",
                             valign=Gtk.Align.CENTER, use_markup=False)
            name.add_css_class("dim-label")
            suffix = Gtk.Box(spacing=8, valign=Gtk.Align.CENTER)
            suffix.append(name)
            if number in clashing:
                warn = Gtk.Image(icon_name="dialog-warning-symbolic",
                                 valign=Gtk.Align.CENTER)
                warn.add_css_class("warning")
                warn.set_tooltip_text("another project claims this port too")
                suffix.append(warn)
            child.add_suffix(suffix)
            row.add_row(child)
        self._port_rows.append(row)
        return row

    def _render_plugins(self, state: dict | None, problem: str) -> None:
        self._clear(self._plugins, self._plugin_rows)

        if problem:
            self._message(self._plugins, self._plugin_rows, "Could not list plugins", problem)
            return

        rows = plugin_rows(state)
        if not rows:
            # Deliberately not the CLI's onboarding text, which is a shell
            # lesson. What a person can act on from a window is that something
            # ships with pitcrew and what it would tell them.
            self._message(
                self._plugins, self._plugin_rows, "No plugins loaded",
                "A plugin adds checks to Diagnostics. One ships with pitcrew: "
                "ext/jvm reports where a JVM's memory went and what is going to kill it.")
            return

        for plugin in rows:
            row = Adw.ActionRow(title=plugin["file"], use_markup=False,
                                subtitle=plugin["summary"])
            row.set_subtitle_lines(2)
            # A file that loaded and registered nothing looks installed and does
            # nothing. That is the one state worth an icon.
            if plugin["empty"]:
                icon = Gtk.Image(icon_name="dialog-warning-symbolic",
                                 valign=Gtk.Align.CENTER)
                icon.add_css_class("warning")
                icon.set_tooltip_text("loaded, but registered no checks")
            else:
                icon = Gtk.Image(icon_name="object-select-symbolic",
                                 valign=Gtk.Align.CENTER)
                icon.add_css_class("success")
            row.add_prefix(icon)
            self._plugins.add(row)
            self._plugin_rows.append(row)

    @staticmethod
    def _message(group, rows: list, title: str, subtitle: str) -> None:
        row = Adw.ActionRow(title=title, use_markup=False, subtitle=subtitle)
        row.set_subtitle_lines(0)
        group.add(row)
        rows.append(row)

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
                 profiles: list[dict], on_changed, on_toast):
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
        self._rows: list[Adw.PreferencesRow] = []
        self._fill(profiles)
        self._page.add(self._existing)

        view = Adw.ToolbarView()
        view.add_top_bar(Adw.HeaderBar())
        view.set_content(self._page)
        self.set_child(view)

    def _fill(self, profiles: list[dict]) -> None:
        for row in self._rows:
            self._existing.remove(row)
        self._rows.clear()
        if not profiles:
            row = Adw.ActionRow(title="No profiles yet", use_markup=False,
                                subtitle="Start the components you want, then save them above")
            self._existing.add(row)
            self._rows.append(row)
            return
        for profile in profiles:
            row = self._row_for(profile)
            self._existing.add(row)
            self._rows.append(row)

    def _row_for(self, profile: dict) -> Adw.ExpanderRow:
        """A profile, with what it covers rather than the word you saved.

        The list used to be names and two buttons, which meant deciding whether
        to press start on a set you named six weeks ago. Everything here is the
        stream's — pitcrew resolving its own target words — so it also knows
        when a profile has rotted and can no longer start at all.
        """
        name = profile["name"]
        up, total = profile.get("up", 0), profile.get("total", 0)
        missing = profile.get("missing") or []
        components = profile.get("components") or []

        bits = [f"{up}/{total} up" if total else "resolves to nothing"]
        if profile.get("rss"):
            bits.append(human_bytes(profile["rss"]))
        if profile.get("limit"):
            bits.append(f"commits {human_bytes(profile['limit'])}")

        row = Adw.ExpanderRow(title=plain(f"@{name}"), use_markup=False,
                              subtitle=plain(" · ".join(bits)))
        box = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
        start = Gtk.Button(icon_name="media-playback-start-symbolic",
                           tooltip_text=f"Start @{name}")
        start.add_css_class("flat")
        start.set_sensitive(not missing and total > 0)
        start.connect("clicked", lambda _b, n=name: self._start(n))
        box.append(start)
        delete = Gtk.Button(icon_name="user-trash-symbolic", tooltip_text="Delete")
        delete.add_css_class("flat")
        delete.connect("clicked", lambda _b, n=name: self._delete(n))
        box.append(delete)
        row.add_suffix(box)

        saved = " ".join(profile.get("targets") or [])
        row.add_row(Adw.ActionRow(title="Saved as", subtitle=plain(saved) or "—",
                                  use_markup=False, css_classes=["dim-label"]))
        for component in components:
            row.add_row(Adw.ActionRow(title=plain(component), use_markup=False,
                                      css_classes=["dim-label"]))
        for word in missing:
            # `pitcrew start @name` dies on a target that no longer exists, so
            # this is not a cosmetic note — the profile is unusable until it is
            # saved again.
            gone = Adw.ActionRow(
                title=plain(f"{word} no longer exists"), use_markup=False,
                subtitle="This profile cannot start until it is saved again")
            gone.add_prefix(Gtk.Image(icon_name="dialog-warning-symbolic",
                                      valign=Gtk.Align.CENTER))
            row.add_row(gone)

        return row

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

