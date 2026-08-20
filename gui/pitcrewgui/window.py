"""The main window: the three views and everything that keeps them current."""

from __future__ import annotations

from gi.repository import Adw, Gio, GLib, Gtk

from .dialogs import ConfigDialog, InitDialog
from .model import (SERIES_COLORS, STATE_STYLE, UNKNOWN_STYLE, Series, empty_message,
                    group_of, human_bytes, plain)
from .registry import current_project, declared_root, known_projects, project_file
from .runner import Runner, Stream
from .settings import SETTINGS, SETTINGS_BY_KEY, Settings
from .widgets import ComponentRow, Dot, Graph, OutputView

class Window(Adw.ApplicationWindow):
    def __init__(self, pitcrew: str, project: str | None, settings: Settings, **kwargs):
        super().__init__(**kwargs)
        self._pitcrew = pitcrew
        self._project = project
        self._settings = settings
        self._runner = Runner(pitcrew)
        self._stream: Stream | None = None
        self._series: dict[str, Series] = {}
        self._rows: dict[str, ComponentRow] = {}
        self._dep_rows: dict[str, Adw.ActionRow] = {}
        self._groups: list[Adw.PreferencesGroup] = []
        self._group_widgets: dict[str, Adw.PreferencesGroup] = {}
        # Rebuilding the list is only correct-and-cheap because it happens when
        # the SHAPE changes, not every frame. This is that shape.
        self._layout_key: tuple | None = None

        self.set_title("pitcrew")
        self.set_default_size(760, 620)

        self._stack = Adw.ViewStack()
        self._stack.add_titled_with_icon(
            self._build_components(), "components", "Components", "view-list-symbolic")
        self._stack.add_titled_with_icon(
            self._build_resources(), "resources", "Resources", "utilities-system-monitor-symbolic")
        self._stack.add_titled_with_icon(
            self._build_projects(), "projects", "Projects", "folder-symbolic")

        header = Adw.HeaderBar()
        header.set_title_widget(Adw.ViewSwitcher(stack=self._stack, policy=Adw.ViewSwitcherPolicy.WIDE))
        header.pack_start(self._build_project_button())
        header.pack_end(self._build_menu_button())

        self._banner = Adw.Banner(revealed=False)
        self._banner.set_button_label("Retry")
        self._banner.connect("button-clicked", lambda _b: self._restart_stream())

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        content.append(self._banner)
        content.append(self._stack)

        view = Adw.ToolbarView()
        view.add_top_bar(header)
        view.set_content(content)

        self._toasts = Adw.ToastOverlay()
        self._toasts.set_child(view)
        self.set_content(self._toasts)

        self._restart_stream()

    # ── construction ────────────────────────────────────────────────────────
    def _build_project_button(self) -> Gtk.Widget:
        self._project_button = Gtk.MenuButton(
            label=self._project or "no project", tooltip_text="Switch project")
        action = Gio.SimpleAction.new_stateful(
            "project", GLib.VariantType.new("s"),
            GLib.Variant.new_string(self._project or ""))
        action.connect("activate", self._on_project_chosen)
        self.add_action(action)
        self._project_action = action
        self._refresh_project_menu()
        return self._project_button

    def _refresh_project_menu(self) -> None:
        """The registry is not fixed at startup — init and forget change it."""
        projects = known_projects()
        self._project_button.set_sensitive(bool(projects))
        self._project_button.set_label(self._project or "no project")
        menu = Gio.Menu()
        for name in projects:
            item = Gio.MenuItem.new(name, None)
            item.set_action_and_target_value("win.project", GLib.Variant.new_string(name))
            menu.append_item(item)
        self._project_button.set_menu_model(menu)

    def _build_menu_button(self) -> Gtk.Widget:
        menu = Gio.Menu()
        menu.append("Preferences", "win.preferences")
        action = Gio.SimpleAction.new("preferences", None)
        action.connect("activate", lambda *_: self._show_preferences())
        self.add_action(action)
        app = self.get_application()
        if app is not None:
            app.set_accels_for_action("win.preferences", ["<Primary>comma"])
        return Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu,
                              tooltip_text="Main menu")

    def _build_components(self) -> Gtk.Widget:
        self._comp_page = Adw.PreferencesPage()
        # A filter that hides everything must say so. Without this, turning off
        # "show stopped" on a stack that is entirely down looks identical to the
        # app being broken.
        self._empty_label = Gtk.Label(wrap=True, justify=Gtk.Justification.CENTER,
                                      margin_top=24, margin_bottom=24)
        self._empty_label.add_css_class("dim-label")
        self._empty_group = Adw.PreferencesGroup(visible=False)
        self._empty_group.add(self._empty_label)
        self._dep_group = Adw.PreferencesGroup(title="Dependencies")
        self._comp_page.add(self._empty_group)
        self._comp_page.add(self._dep_group)
        return self._comp_page

    def _build_resources(self) -> Gtk.Widget:
        self._cpu_graph = Graph("cpu", floor=100, fmt=lambda v: f"{v:.0f}%")
        self._rss_graph = Graph("rss", floor=512 * 1024 ** 2, fmt=human_bytes)
        self._legend = Gtk.FlowBox(
            selection_mode=Gtk.SelectionMode.NONE, max_children_per_line=4,
            row_spacing=4, column_spacing=16)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                      margin_top=18, margin_bottom=18, margin_start=18, margin_end=18)
        for title, graph in (("CPU", self._cpu_graph), ("Memory", self._rss_graph)):
            label = Gtk.Label(label=title, halign=Gtk.Align.START)
            label.add_css_class("heading")
            box.append(label)
            frame = Gtk.Frame()
            frame.set_child(graph)
            box.append(frame)
        box.append(self._legend)

        scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER)
        scroller.set_child(box)
        return scroller

    def _build_projects(self) -> Gtk.Widget:
        self._projects_group = Adw.PreferencesGroup(
            title="Projects", description="Everything pitcrew knows about on this machine")
        add = Gtk.Button(icon_name="list-add-symbolic", tooltip_text="Add project",
                         valign=Gtk.Align.CENTER)
        add.add_css_class("flat")
        add.connect("clicked", lambda _b: self._add_project())
        self._projects_group.set_header_suffix(add)

        self._projects_page = Adw.PreferencesPage()
        self._projects_page.add(self._projects_group)
        self._project_rows: list[Adw.ActionRow] = []
        self._refresh_projects()
        return self._projects_page

    def _refresh_projects(self) -> None:
        for row in self._project_rows:
            self._projects_group.remove(row)
        self._project_rows.clear()

        names = known_projects()
        if not names:
            row = Adw.ActionRow(
                title="No projects yet",
                subtitle="Add one to have pitcrew look at a checkout and write its config")
            self._projects_group.add(row)
            self._project_rows.append(row)
            return

        for name in names:
            root = declared_root(project_file(name))
            row = Adw.ActionRow(title=name, use_markup=False,
                                subtitle=plain(str(root)) if root else "root unknown")
            if name == self._project:
                badge = Gtk.Label(label="current", valign=Gtk.Align.CENTER)
                badge.add_css_class("caption")
                badge.add_css_class("accent")
                row.add_prefix(badge)
            box = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
            box.append(self._project_button_for(
                "document-edit-symbolic", "Edit config", lambda n=name: self._edit_config(n)))
            box.append(self._project_button_for(
                "media-playback-start-symbolic", "Watch this project",
                lambda n=name: self._switch_to(n)))
            box.append(self._project_button_for(
                "user-trash-symbolic", "Forget", lambda n=name: self._confirm_forget(n)))
            row.add_suffix(box)
            self._projects_group.add(row)
            self._project_rows.append(row)

    @staticmethod
    def _project_button_for(icon: str, tooltip: str, action) -> Gtk.Button:
        button = Gtk.Button(icon_name=icon, tooltip_text=tooltip)
        button.add_css_class("flat")
        button.connect("clicked", lambda _b: action())
        return button

    def _add_project(self) -> None:
        InitDialog(self._runner, self._project_registry_changed).present(self)

    def _edit_config(self, name: str) -> None:
        # Saving a config only takes effect on the next read, and the stream is
        # a long-lived reader — restart it if we are looking at that project.
        def saved() -> None:
            self._toast(f"{name} config saved")
            if name == self._project:
                self._restart_stream()
        ConfigDialog(self._runner, name, saved).present(self)

    def _switch_to(self, name: str) -> None:
        self._project_action.activate(GLib.Variant.new_string(name))

    def _confirm_forget(self, name: str) -> None:
        dialog = Adw.AlertDialog(
            heading=f"Forget {name}?",
            body="pitcrew stops tracking it. The checkout and its files are untouched.")
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("forget", "Forget")
        dialog.set_response_appearance("forget", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.connect("response", lambda _d, response: (
            self._runner.run(["forget", name], lambda ok, out: self._forgotten(ok, out, name))
            if response == "forget" else None))
        dialog.present(self)

    def _forgotten(self, ok: bool, output: str, name: str) -> None:
        if not ok:
            self._toast(output.splitlines()[-1] if output else f"could not forget {name}")
            return
        self._toast(f"forgot {name}")
        if name == self._project:
            # Watching a project that no longer exists would just error forever.
            self._project = current_project()
            self._restart_stream()
        self._project_registry_changed()

    def _project_registry_changed(self) -> None:
        self._refresh_project_menu()
        self._refresh_projects()

    # ── preferences ─────────────────────────────────────────────────────────
    def _show_preferences(self) -> None:
        dialog = Adw.PreferencesDialog(title="Preferences")
        page = Adw.PreferencesPage()

        listing = Adw.PreferencesGroup(
            title="Component list", description="How the Components view is laid out")
        listing.add(self._choice_row(
            "group", "Group by", ["app", "role", "flat"],
            ["App (backend + frontend together)", "Role (backends, then frontends)",
             "Nothing — one flat list"]))
        listing.add(self._switch_row(
            "stopped", "Show stopped components", "hide", "show",
            "Off lists only what is running, starting, or external"))
        page.add(listing)

        sampling = Adw.PreferencesGroup(
            title="Sampling", description="Changing these restarts the stream")
        sampling.add(self._spin_row("interval", "Interval", "Seconds between samples"))
        sampling.add(self._spin_row("history", "Graph history", "Samples kept per line"))
        sampling.add(self._choice_row(
            "plot", "Plot", ["running", "all"],
            ["Only running components", "Every component"]))
        page.add(sampling)

        dialog.add(page)
        dialog.present(self)

    def _choice_row(self, key: str, title: str, values: list[str], labels: list[str]) -> Adw.ComboRow:
        row = Adw.ComboRow(title=title, model=Gtk.StringList.new(labels))
        row.set_selected(values.index(self._settings[key]))
        row.connect("notify::selected",
                    lambda r, _p: self._apply(key, values[r.get_selected()]))
        return row

    def _switch_row(self, key: str, title: str, off: str, on: str, subtitle: str) -> Adw.SwitchRow:
        row = Adw.SwitchRow(title=title, subtitle=subtitle)
        row.set_active(self._settings[key] == on)
        row.connect("notify::active",
                    lambda r, _p: self._apply(key, on if r.get_active() else off))
        return row

    def _spin_row(self, key: str, title: str, subtitle: str) -> Adw.SpinRow:
        lo, hi = SETTINGS_BY_KEY[key].choices
        row = Adw.SpinRow.new_with_range(lo, hi, 1)
        row.set_title(title)
        row.set_subtitle(subtitle)
        row.set_value(self._settings[key])
        row.connect("notify::value", lambda r, _p: self._apply(key, int(r.get_value())))
        return row

    def _apply(self, key: str, value) -> None:
        """Take a preference, persist it, and make it true on screen right now."""
        if self._settings.get(key) == value:
            return
        self._settings[key] = value
        if not self._settings.save():
            self._toast(f"Could not write {self._settings.path} — this session only")

        if key == "interval":
            self._restart_stream()        # the interval is an argv of the child
            return
        if key == "history":
            for series in self._series.values():
                series.resize(value)
            return
        if key in ("group", "stopped"):
            self._layout_key = None       # force the next frame to rebuild

    # ── stream lifecycle ────────────────────────────────────────────────────
    def _clear_lists(self) -> None:
        for group in self._groups:
            self._comp_page.remove(group)
        self._groups.clear()
        self._rows.clear()
        self._layout_key = None
        for row in list(self._dep_rows.values()):
            self._dep_group.remove(row)
        self._dep_rows.clear()

    def _restart_stream(self) -> None:
        if self._stream:
            self._stream.stop()
        self._series.clear()
        self._clear_lists()

        if not self._project:
            self._fail("No project selected — run `pitcrew init <dir>` or `pitcrew use <name>`.")
            return
        self._banner.set_revealed(False)
        self._stream = Stream(self._pitcrew, self._project, self._settings["interval"],
                              self._on_state, self._fail)
        self._stream.start()

    def _on_project_chosen(self, action: Gio.SimpleAction, target: GLib.Variant) -> None:
        name = target.get_string()
        if name == self._project:
            return
        action.set_state(target)
        self._project = name
        self._project_button.set_label(name)
        self._refresh_projects()
        self._restart_stream()

    def _fail(self, message: str) -> None:
        self._banner.set_title(message)
        self._banner.set_revealed(True)

    # ── rendering ───────────────────────────────────────────────────────────
    def _on_state(self, state: dict) -> None:
        self._banner.set_revealed(False)
        components = state.get("components", [])
        colors = {c["name"]: SERIES_COLORS[i % len(SERIES_COLORS)]
                  for i, c in enumerate(components)}
        history = self._settings["history"]

        for comp in components:
            name = comp["name"]
            series = self._series.get(name)
            if series is None:
                series = self._series[name] = Series(name, colors[name], history)
            series.push(comp.get("cpu"), comp.get("rss"))

        self._render_components(components, colors)
        self._render_deps(state.get("deps", []))
        self._render_graphs(components, history)

        summary = state.get("summary", {})
        counts = [f"{summary[k]} {k}" for k in ("up", "starting", "crashed", "down") if summary.get(k)]
        self.set_title(f"{state.get('project') or 'pitcrew'} — {' · '.join(counts)}")

    def _render_components(self, components: list[dict], colors: dict[str, str]) -> None:
        mode = self._settings["group"]
        total = len(components)
        if self._settings["stopped"] == "hide":
            components = [c for c in components
                          if c.get("state") in ("up", "starting", "external", "crashed")]

        buckets: dict[tuple[str, str], list[dict]] = {}
        for comp in components:
            buckets.setdefault(group_of(comp, mode), []).append(comp)
        ordered = sorted(buckets.items())
        self._show_empty_state(len(components), total)

        # Rebuild only when the shape changed — a new project, a settings change,
        # or a component appearing. Otherwise every frame would throw away and
        # recreate every widget, losing scroll position and focus twice a second.
        layout_key = (mode, tuple((heading, tuple(c["name"] for c in comps))
                                  for (_sort, heading), comps in ordered))
        if layout_key != self._layout_key:
            self._rebuild_components(ordered, colors)
            self._layout_key = layout_key

        for (_sort, heading), comps in ordered:
            for comp in comps:
                self._rows[comp["name"]].update(comp)
            group = self._group_widgets.get(heading)
            if group is not None:
                group.set_description(self._group_summary(comps))

    def _rebuild_components(self, ordered, colors: dict[str, str]) -> None:
        for group in self._groups:
            self._comp_page.remove(group)
        self._groups.clear()
        self._rows.clear()
        self._group_widgets.clear()

        # Lift the dependencies group out once, then put it back last, so it
        # stays pinned below the components however many groups there are.
        # AdwPreferencesPage only appends, so ordering means re-adding.
        self._comp_page.remove(self._dep_group)
        for (_sort, heading), comps in ordered:
            group = Adw.PreferencesGroup(title=plain(heading))
            for comp in comps:
                row = ComponentRow(comp["name"], colors[comp["name"]], self._run_action)
                group.add(row)
                self._rows[comp["name"]] = row
            self._comp_page.add(group)
            self._groups.append(group)
            self._group_widgets[heading] = group
        self._comp_page.add(self._dep_group)

    def _show_empty_state(self, shown: int, total: int) -> None:
        if shown:
            self._empty_group.set_visible(False)
            return
        self._empty_label.set_text(empty_message(total))
        self._empty_group.set_visible(True)

    @staticmethod
    def _group_summary(comps: list[dict]) -> str:
        up = sum(1 for c in comps if c.get("state") == "up")
        rss = sum(c.get("rss") or 0 for c in comps)
        parts = [f"{up}/{len(comps)} up"]
        if rss:
            parts.append(human_bytes(rss))
        return "  ·  ".join(parts)

    def _render_deps(self, deps: list[dict]) -> None:
        for dep in deps:
            row = self._dep_rows.get(dep["name"])
            if row is None:
                row = Adw.ActionRow(title=dep["name"], use_markup=False)
                row.add_prefix(Dot(STATE_STYLE.get(dep["state"], UNKNOWN_STYLE)[1]))
                self._dep_group.add(row)
                self._dep_rows[dep["name"]] = row
            row.set_subtitle(dep["state"])
        self._dep_group.set_visible(bool(self._dep_rows))

    def _render_graphs(self, components: list[dict], history: int) -> None:
        if self._settings["plot"] == "all":
            wanted = {c["name"] for c in components}
        else:
            # A dozen flat zeroes for stopped services hides the two you care about.
            wanted = {c["name"] for c in components
                      if c.get("state") in ("up", "starting", "external")}
        plotted = [s for name, s in self._series.items() if name in wanted]
        self._cpu_graph.set_series(plotted, history)
        self._rss_graph.set_series(plotted, history)
        self._rebuild_legend(plotted)

    def _rebuild_legend(self, series: list[Series]) -> None:
        child = self._legend.get_first_child()
        while child is not None:
            nxt = child.get_next_sibling()
            self._legend.remove(child)
            child = nxt
        for item in series:
            box = Gtk.Box(spacing=6)
            box.append(Dot(item.color, size=10))
            label = Gtk.Label(label=item.name)
            label.add_css_class("caption")
            box.append(label)
            self._legend.append(box)

    # ── actions ─────────────────────────────────────────────────────────────
    def _run_action(self, verb: str, component: str) -> None:
        argv = [self._pitcrew, "-p", self._project, verb, component]
        try:
            proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDERR_PIPE)
        except GLib.Error as error:
            self._toast(f"{verb} {component} failed: {error.message}")
            return
        self._toast(f"{verb}ing {component}…")
        proc.communicate_utf8_async(None, None, lambda p, r: self._on_action_done(p, r, verb, component))

    def _on_action_done(self, proc: Gio.Subprocess, result, verb: str, component: str) -> None:
        try:
            _, _, stderr = proc.communicate_utf8_finish(result)
        except GLib.Error as error:
            self._toast(f"{verb} {component} failed: {error.message}")
            return
        if proc.get_successful():
            self._toast(f"{component} {verb}ed")
            return
        last = (stderr or "").strip().splitlines()
        self._toast(f"{verb} {component} failed: {last[-1] if last else 'see logs'}"[:200])

    def _toast(self, message: str) -> None:
        self._toasts.add_toast(Adw.Toast.new(message))
