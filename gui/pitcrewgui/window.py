"""The main window: the three views and everything that keeps them current."""

from __future__ import annotations

from gi.repository import Adw, Gio, GLib, Gtk

from .dialogs import (
    ConfigDialog,
    DetailDialog,
    DoctorDialog,
    InitDialog,
    LimitsDialog,
    ProfilesDialog,
    ToolsDialog,
)
from .logview import LogView
from .model import (
    RAMP,
    SERIES_COLORS,
    STATE_STYLE,
    UNKNOWN_STYLE,
    VERDICT_STYLE,
    Series,
    empty_message,
    findings_of,
    group_is_idle,
    group_of,
    human_bytes,
    machine_meters,
    merge_findings,
    plain,
    share_slices,
    top_consumers,
    verdict_of,
)
from .notify import CrashWatcher
from .platform import cli_argv
from .profiles import profile_names
from .registry import current_project, declared_root, known_projects, project_file
from .runner import Runner, Stream
from .settings import SETTINGS_BY_KEY, Settings
from .style import install as install_css
from .widgets import (
    Bar,
    ComponentRow,
    Dot,
    FindingRow,
    Graph,
    Meter,
    SegmentedControl,
    ShareChart,
    human_age,
)


class Window(Adw.ApplicationWindow):
    def __init__(self, pitcrew: str, project: str | None, settings: Settings, **kwargs):
        super().__init__(**kwargs)
        self._pitcrew = pitcrew
        self._project = project
        self._settings = settings
        self._runner = Runner(pitcrew)
        self._init_state()

        install_css()
        self.set_title("pitcrew")
        # Remembered across runs: reopening at 900x680 on every launch, on the
        # tab you were not using, is a small insult repeated daily.
        self.set_default_size(settings["width"], settings["height"])
        self.connect("close-request", self._remember_geometry)

        self._crashes = CrashWatcher(kwargs.get("application"), self._show_logs_for)
        self._crashes.enabled = settings["notify"] == "crash"

        self._stack = Adw.ViewStack()
        # Overview leads because it answers the question you opened the window
        # to ask. Components is a list, and a list is evidence, not an answer.
        self._stack.add_titled_with_icon(
            self._build_overview(), "overview", "Overview", "dialog-information-symbolic")
        self._stack.add_titled_with_icon(
            self._build_components(), "components", "Components", "view-list-symbolic")
        self._stack.add_titled_with_icon(
            self._build_resources(), "resources", "Resources", "power-profile-performance-symbolic")
        self._stack.add_titled_with_icon(
            self._build_logs(), "logs", "Logs", "text-x-generic-symbolic")
        self._stack.add_titled_with_icon(
            self._build_projects(), "projects", "Projects", "folder-symbolic")

        header = Adw.HeaderBar()
        # NARROW stacks the icon over the label, which is what makes four views
        # fit: WIDE puts them side by side and truncated every title to "Comp…"
        # the moment a fourth tab arrived.
        header.set_title_widget(
            Adw.ViewSwitcher(stack=self._stack, policy=Adw.ViewSwitcherPolicy.NARROW))
        header.pack_start(self._build_project_button())
        header.pack_start(self._build_running_pill())
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

        # Two columns above ~880px, stacked below it. Without this the Overview
        # is unusable in a half-screen window: two 440px columns of meters and
        # findings both truncate rather than one of them wrapping.
        breakpoint_ = Adw.Breakpoint.new(
            Adw.BreakpointCondition.parse("max-width: 880px"))
        breakpoint_.add_setter(self._columns, "orientation", Gtk.Orientation.VERTICAL)
        self.add_breakpoint(breakpoint_)

        self._install_shortcuts()
        if settings["tab"] in ("overview", "components", "resources", "logs", "projects"):
            self._stack.set_visible_child_name(settings["tab"])
        self._restart_stream()

    def _init_state(self) -> None:
        """Everything the frame loop reads, in one place rather than scattered
        through a constructor that also builds the entire UI."""
        self._stream: Stream | None = None
        self._series: dict[str, Series] = {}
        self._rows: dict[str, ComponentRow] = {}
        self._dep_rows: dict[str, tuple] = {}
        self._groups: list[Adw.PreferencesGroup] = []
        self._group_widgets: dict[str, Adw.PreferencesGroup] = {}
        self._group_toggles: dict[str, Gtk.Button] = {}
        self._group_rows: dict[str, list] = {}
        self._collapsed: dict[str, bool] = {}
        self._pinned: set[str] = set()          # headings the user has toggled
        self._colors: dict[str, str] = {}
        self._hidden: set[str] = set()          # series muted from the legend
        # Rebuilding the list is only correct-and-cheap because it happens when
        # the SHAPE changes, not every frame. This is that shape.
        self._layout_key: tuple | None = None
        # Until the first sample lands there is nothing to draw and no error to
        # report. An empty list looks identical to a broken app, and a stream
        # interval of 10s means someone stares at it for ten seconds.
        self._have_frame = False
        # Findings from the last explicit full run. Cleared on project switch —
        # they describe a project we are no longer looking at.
        self._deep_findings: list[dict] = []
        self._live_findings: list[dict] = []
        self._last_components: list[dict] = []
        self._last_log_dir: str | None = None
        self._last_profile_dir: str | None = None
        self._shells: list[str] = []
        self._detail: object | None = None
        self._machine_total = 0
        self._last_at = 0

    # ── keyboard ────────────────────────────────────────────────────────────
    def _install_shortcuts(self) -> None:
        """A GUI you must reach for the mouse in is one you open twice.

        The terminal dashboard is entirely keyboard-driven; this is the same
        vocabulary where it maps, and GTK conventions where it does not.
        """
        app = self.get_application()
        if app is None:
            return

        views = ("overview", "components", "resources", "logs", "projects")
        switch = Gio.SimpleAction.new("view", GLib.VariantType.new("s"))
        switch.connect("activate", lambda _a, t: self._stack.set_visible_child_name(t.get_string()))
        self.add_action(switch)

        focus = Gio.SimpleAction.new("focusfilter", None)
        focus.connect("activate", lambda *_: self._focus_filter())
        self.add_action(focus)

        shortcuts = Gio.SimpleAction.new("shortcuts", None)
        shortcuts.connect("activate", lambda *_: self._show_shortcuts())
        self.add_action(shortcuts)

        for index, view in enumerate(views, start=1):
            app.set_accels_for_action(f"win.view::{view}", [f"<Primary>{index}"])
        app.set_accels_for_action("win.focusfilter", ["slash", "<Primary>f"])
        app.set_accels_for_action("win.shortcuts", ["<Primary>question", "question"])
        app.set_accels_for_action("win.limits", ["<Primary>m"])
        app.set_accels_for_action("win.up", ["<Primary>Return"])
        app.set_accels_for_action("win.stopall", ["<Primary><Shift>Return"])

    def _focus_filter(self) -> None:
        if self._stack.get_visible_child_name() == "logs":
            self._logs.focus_filter()
        else:
            self._stack.set_visible_child_name("logs")
            self._logs.focus_filter()

    def _show_shortcuts(self) -> None:
        dialog = Adw.Dialog(title="Keyboard shortcuts", content_width=460)
        page = Adw.PreferencesPage()
        group = Adw.PreferencesGroup(title="Shortcuts")
        for keys, what in (
            ("Ctrl+1 … Ctrl+5", "Overview / Components / Resources / Logs / Projects"),
            ("/  or  Ctrl+F", "Filter the log"),
            ("Ctrl+M", "RAM caps"),
            ("Ctrl+,", "Preferences"),
            ("Ctrl+Enter", "Start everything"),
            ("Ctrl+Shift+Enter", "Stop everything"),
            ("?", "This list"),
        ):
            group.add(Adw.ActionRow(title=what, subtitle=keys, use_markup=False))
        page.add(group)
        dialog.set_child(page)
        dialog.present(self)

    def _remember_geometry(self, *_args) -> bool:
        width, height = self.get_default_size()
        self._settings["width"] = max(600, width)
        self._settings["height"] = max(400, height)
        self._settings["tab"] = self._stack.get_visible_child_name() or "overview"
        self._settings.save()
        return False        # let the window close

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

    def _build_running_pill(self) -> Gtk.Widget:
        """How much is up, in the header.

        The window TITLE already carried this — and was invisible, because the
        view switcher occupies the title slot. A count you have to open a tab to
        read is not a status indicator.
        """
        self._running_dot = Dot(STATE_STYLE["down"][1], size=9)
        self._running_label = Gtk.Label(label="—")
        self._running_label.add_css_class("caption")
        box = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
        box.append(self._running_dot)
        box.append(self._running_label)
        button = Gtk.Button(child=box, valign=Gtk.Align.CENTER, margin_start=6)
        button.add_css_class("flat")
        button.set_tooltip_text("Components up / configured")
        button.connect("clicked",
                       lambda _b: self._stack.set_visible_child_name("overview"))
        self._running_pill = button
        return button

    def _update_running_pill(self, state: dict, components: list[dict], summary: dict) -> None:
        up = summary.get("up", 0) + summary.get("external", 0)
        starting = summary.get("starting", 0)
        crashed = summary.get("crashed", 0)
        total = len(components)

        # Coloured by the VERDICT, not by the worst component state. Those are
        # not the same question: every component can be up while the machine is
        # swapping, and a green dot over that is a lie the header has no excuse
        # for telling when the stream carries the real answer.
        level, colour, headline = verdict_of(state)
        self._running_dot.set_color(colour)

        text = f"{up}/{total} up"
        if starting:
            text += f" · {starting} starting"
        if crashed:
            text += f" · {crashed} crashed"
        self._running_label.set_text(text)
        self._running_pill.set_tooltip_text(
            headline or "Components up / configured")
        # Clicking the health indicator goes to the health page. Anything else
        # would be a status light that resents being asked about itself.
        self._running_pill.set_visible(True)

    def _build_menu_button(self) -> Gtk.Widget:
        menu = Gio.Menu()

        stack_section = Gio.Menu()
        stack_section.append("Start everything", "win.up")
        stack_section.append("Stop everything", "win.stopall")
        menu.append_section(None, stack_section)

        self._profiles_menu = Gio.Menu()
        menu.append_submenu("Profiles", self._profiles_menu)
        self._profiles_menu_end = Gio.Menu()
        self._profiles_menu_end.append("Manage profiles…", "win.profiles")

        for name, handler in (("up", lambda: self._run_action("start", "all")),
                              ("stopall", lambda: self._run_action("stop", "all"))):
            act = Gio.SimpleAction.new(name, None)
            act.connect("activate", lambda *_a, h=handler: h())
            self.add_action(act)

        profile_action = Gio.SimpleAction.new("profile", GLib.VariantType.new("s"))
        profile_action.connect(
            "activate", lambda _a, t: self._run_action("start", f"@{t.get_string()}"))
        self.add_action(profile_action)

        menu.append("RAM caps…", "win.limits")
        menu.append("Doctor…", "win.doctor")
        menu.append("Ports, plugins & shells…", "win.tools")
        menu.append("Preferences", "win.preferences")
        menu.append("Keyboard shortcuts", "win.shortcuts")
        for name, handler in (("doctor", self._show_doctor),
                              ("tools", self._show_tools),
                              ("profiles", self._show_profiles)):
            act = Gio.SimpleAction.new(name, None)
            act.connect("activate", lambda *_a, h=handler: h())
            self.add_action(act)
        limits = Gio.SimpleAction.new("limits", None)
        limits.connect("activate", lambda *_: self._show_limits())
        self.add_action(limits)
        action = Gio.SimpleAction.new("preferences", None)
        action.connect("activate", lambda *_: self._show_preferences())
        self.add_action(action)
        app = self.get_application()
        if app is not None:
            app.set_accels_for_action("win.preferences", ["<Primary>comma"])
        return Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu,
                              tooltip_text="Main menu")

    # ── overview ────────────────────────────────────────────────────────────
    def _build_verdict_banner(self) -> None:
        """The verdict is a BANNER, not a card.

        It is the answer; the four things under it are the evidence. Rendering
        both as identical rounded rectangles gave everything the same weight,
        so nothing was read first — which for the one line that says whether
        you can go back to work is the whole job undone.
        """
        self._verdict_dot = Dot(VERDICT_STYLE["ok"][0], size=16)
        self._verdict_title = Gtk.Label(xalign=0, wrap=True, hexpand=True)
        self._verdict_title.add_css_class("title-2")
        self._verdict_sub = Gtk.Label(xalign=0, wrap=True, label="waiting for the first sample…")
        self._verdict_sub.add_css_class("dim-label")

        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3, hexpand=True)
        text.append(self._verdict_title)
        text.append(self._verdict_sub)

        dot_box = Gtk.Box(valign=Gtk.Align.START, margin_top=6)
        dot_box.append(self._verdict_dot)

        self._verdict_banner = Gtk.Box(spacing=14)
        self._verdict_banner.add_css_class("verdict")
        self._verdict_banner.add_css_class("verdict-ok")
        self._verdict_class = "verdict-ok"
        self._verdict_banner.append(dot_box)
        self._verdict_banner.append(text)


    def _build_overview(self) -> Gtk.Widget:
        """Health, then resources, then what to do about it — in that order.

        Everything on this page is read from the stream's `health` object, which
        lib/19-diag.sh produced. None of it is worked out here: the desktop app
        and the terminal dashboard show the same verdict because there is only
        one thing computing it.

        Laid out by hand rather than in an AdwPreferencesPage. That widget
        clamps its content to about 600px whatever the window is doing, which
        on a 1000px window left nearly half the screen empty and on a monitor
        left most of it — a monitoring tool that cannot use the space it was
        given reads as a phone settings screen. Here the clamp is wide enough
        for two columns, and a breakpoint folds them back for a narrow window.
        """
        self._build_verdict_banner()

        # Machine and findings side by side: "how much room is left" and "what
        # is wrong" are read together, and stacking them meant scrolling
        # between two halves of one thought.
        self._meters_group = Adw.PreferencesGroup(title="Machine", hexpand=True)
        self._meter_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10,
                                  margin_top=6, margin_bottom=6)
        self._meters: dict[str, Meter] = {}
        self._meters_group.add(self._meter_box)

        self._findings_group = Adw.PreferencesGroup(
            title="Needs attention", hexpand=True)
        # The stream only carries the cheap checks — anything that has to fork
        # (a jcmd, a docker inspect) is skipped there so the dashboard's frame
        # loop stays free of it. Asking for the rest is therefore an explicit
        # act, and this is the button that performs it. A framed button, not
        # bare text: at the right of a group header, text reads as a title.
        self._deep_button = Gtk.Button(valign=Gtk.Align.CENTER)
        self._deep_button.set_child(Adw.ButtonContent(
            icon_name="system-search-symbolic", label="Full diagnostics"))
        self._deep_button.set_tooltip_text(
            "Also run the checks that are too slow to run every frame")
        self._deep_button.connect("clicked", lambda _b: self._run_deep())
        self._findings_group.set_header_suffix(self._deep_button)
        self._finding_rows: list[Adw.ActionRow] = []
        # Shown even when empty, unlike the groups below: "nothing needs your
        # attention" is the answer someone came here for, and a section that
        # vanishes when things are fine makes you wonder if it is broken.
        self._findings_ok = Adw.ActionRow(
            title="Nothing needs your attention", use_markup=False)
        self._findings_ok.add_prefix(Gtk.Image(icon_name="object-select-symbolic",
                                               valign=Gtk.Align.CENTER))
        self._findings_ok.add_css_class("dim-label")

        # NOT homogeneous. Four meters and a list of findings are not the same
        # size and never will be, and splitting the width evenly left half the
        # Machine column empty while the findings wrapped to two lines each.
        self._meters_group.set_size_request(360, -1)
        self._meters_group.set_hexpand(False)
        self._columns = Gtk.Box(spacing=24)
        self._columns.append(self._meters_group)
        self._columns.append(self._findings_group)

        # Recovery: the review step. Every candidate is named, with what it is
        # holding and the evidence for calling it idle, and only then is there
        # a button. pitcrew never picks victims off-screen.
        self._recover_group = Adw.PreferencesGroup(
            title="Recoverable",
            description="Idle, and what stopping them gives back", visible=False)
        # Protected components get their own group rather than a greyed-out row
        # in the list above: they are not candidates you cannot pick, they are
        # deliberately not candidates, and the two read very differently.
        self._protected_group = Adw.PreferencesGroup(
            title="Protected",
            description="Idle too — the config says never propose these", visible=False)
        self._protected_rows: list[Adw.ActionRow] = []
        self._recover_button = Gtk.Button(valign=Gtk.Align.CENTER)
        self._recover_button.add_css_class("destructive-action")
        self._recover_button.connect("clicked", lambda _b: self._stop_recoverable())
        self._recover_group.set_header_suffix(self._recover_button)
        self._recover_rows: list[Adw.ActionRow] = []
        self._recoverable: list[str] = []

        # And the plain ranked answer to "what is eating my RAM".
        self._consumers_group = Adw.PreferencesGroup(title="Largest consumers", visible=False)
        self._consumer_rows: list[Adw.ActionRow] = []

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=22,
                       margin_top=20, margin_bottom=24, margin_start=18, margin_end=18)
        body.append(self._verdict_banner)
        body.append(self._columns)
        body.append(self._recover_group)
        body.append(self._protected_group)
        body.append(self._consumers_group)

        clamp = Adw.Clamp(maximum_size=1240, tightening_threshold=900, child=body)
        return Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, child=clamp)

    def _render_overview(self, state: dict) -> None:
        components = state.get("components", [])
        level, colour, headline = verdict_of(state)
        self._verdict_dot.set_color(colour)
        self._verdict_title.set_text(headline or "—")
        wanted = f"verdict-{level}"
        if wanted != self._verdict_class:
            self._verdict_banner.remove_css_class(self._verdict_class)
            self._verdict_banner.add_css_class(wanted)
            self._verdict_class = wanted

        health = state.get("health") or {}
        counts = health.get("counts") or {}
        summary = state.get("summary") or {}
        bits = [f"{summary.get('up', 0)} of {len(components)} components up"]
        for key, word in (("crit", "critical"), ("warn", "warning"), ("info", "note")):
            n = counts.get(key) or 0
            if n:
                bits.append(f"{n} {word}{'s' if n != 1 else ''}")
        self._verdict_sub.set_text("   ·   ".join(bits))

        project_rss = sum(c.get("rss") or 0 for c in components)
        for label, percent, figures in machine_meters(state.get("machine") or {}, project_rss):
            meter = self._meters.get(label)
            if meter is None:
                meter = self._meters[label] = Meter(label)
                self._meter_box.append(meter)
            meter.set(percent, figures)

        health_now = state.get("health") or {}
        # A full run's extra findings are kept until the next one is asked for:
        # they came from checks the stream does not run, so dropping them on the
        # next frame would make the button look like it did nothing.
        self._deep_button.set_visible(not health_now.get("deep"))
        self._live_findings = findings_of(state)
        self._render_findings(merge_findings(self._live_findings, self._deep_findings))
        self._render_recoverable(health.get("recoverable") or {}, components)
        self._render_protected(health.get("recoverable") or {}, components)
        self._render_consumers(components)

    def _render_findings(self, findings: list[dict]) -> None:
        for row in self._finding_rows:
            self._findings_group.remove(row)
        self._finding_rows.clear()
        if not findings:
            # Kept visible with a positive answer, unlike the groups below. A
            # section that disappears when things are fine makes you check
            # whether it is working.
            self._findings_group.add(self._findings_ok)
            self._finding_rows.append(self._findings_ok)
            return
        for finding in findings:
            row = FindingRow(finding, self._show_logs_for, self._run_fix)
            self._findings_group.add(row)
            self._finding_rows.append(row)

    def _render_recoverable(self, recoverable: dict, components: list[dict]) -> None:
        names = recoverable.get("components") or []
        for row in self._recover_rows:
            self._recover_group.remove(row)
        self._recover_rows.clear()
        self._recoverable = list(names)
        if not names:
            self._recover_group.set_visible(False)
            return
        by_name = {c["name"]: c for c in components}
        for name in names:
            comp = by_name.get(name, {})
            idle = comp.get("idle")
            bits = [human_bytes(comp.get("rss"))]
            if idle is not None:
                bits.append(f"quiet {human_age(idle)}")
            if comp.get("since") and self._last_at:
                bits.append(f"up {human_age(self._last_at - comp['since'])}")
            row = Adw.ActionRow(title=plain(name), subtitle="   ·   ".join(bits),
                                use_markup=False)
            row.add_prefix(Dot(STATE_STYLE["up"][1]))
            self._recover_group.add(row)
            self._recover_rows.append(row)
        self._recover_button.set_label(
            f"Stop these {len(names)} · frees {human_bytes(recoverable.get('bytes') or 0)}")
        self._recover_group.set_visible(True)

    def _run_fix(self, verb: str, args: list[str], destructive: bool) -> None:
        """Run a finding's suggested command — as argv, never through a shell.

        `fix_action` has already refused anything outside a small set of verbs,
        so what arrives here is a pitcrew subcommand over component names.
        Destructive ones still ask: a button that stops services because a
        diagnostic suggested it is not something to do on one click.
        """
        if not destructive:
            self._run_action(verb, *args)
            return
        target = " ".join(args) if args else "everything"
        dialog = Adw.AlertDialog(
            heading=f"{verb.capitalize()}?",
            body=f"pitcrew {verb} {target}")
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("go", verb.capitalize())
        dialog.set_response_appearance("go", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.connect("response", lambda _d, r: (
            self._run_action(verb, *args) if r == "go" else None))
        dialog.present(self)

    def _render_protected(self, recoverable: dict, components: list[dict]) -> None:
        names = recoverable.get("protected") or []
        for row in self._protected_rows:
            self._protected_group.remove(row)
        self._protected_rows.clear()
        by_name = {c["name"]: c for c in components}
        for name in names:
            comp = by_name.get(name, {})
            row = Adw.ActionRow(title=plain(name), use_markup=False,
                                subtitle=f"{human_bytes(comp.get('rss'))}   ·   "
                                         "protected in this project's config")
            row.add_prefix(Gtk.Image(icon_name="changes-prevent-symbolic",
                                     valign=Gtk.Align.CENTER))
            self._protected_group.add(row)
            self._protected_rows.append(row)
        self._protected_group.set_visible(bool(names))

    def _run_deep(self) -> None:
        if not self._project:
            return
        self._deep_button.set_sensitive(False)
        self._deep_button.set_label("Running…")
        self._runner.run_json(["-p", self._project, "diagnose", "--json"], self._deep_done)

    def _deep_done(self, state: dict | None, problem: str) -> None:
        self._deep_button.set_sensitive(True)
        self._deep_button.set_label("Full diagnostics")
        if state is None:
            self._toast(f"full diagnostics failed: {problem}")
            return
        self._deep_findings = (state.get("health") or {}).get("findings") or []
        extra = len(merge_findings(self._live_findings, self._deep_findings)) \
            - len(self._live_findings)
        # Re-render now rather than waiting for the next frame: a button whose
        # effect appears up to `interval` seconds later reads as broken.
        self._render_findings(merge_findings(self._live_findings, self._deep_findings))
        self._toast(f"full diagnostics found {extra} more"
                    if extra else "full diagnostics found nothing the stream missed")

    def _stop_recoverable(self) -> None:
        """Apply, after the review. The dialog names every component again:
        the list is right there on screen, but a destructive action confirmed
        against a list you have to scroll back to is not really confirmed."""
        if not self._recoverable:
            return
        names = list(self._recoverable)
        dialog = Adw.AlertDialog(
            heading=f"Stop {len(names)} idle components?",
            body="\n".join(names) + "\n\nThey can be started again at any time.")
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("stop", "Stop them")
        dialog.set_response_appearance("stop", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.connect("response", lambda _d, response: (
            self._run_action("stop", *names) if response == "stop" else None))
        dialog.present(self)

    def _render_consumers(self, components: list[dict]) -> None:
        rows = top_consumers(components)
        for row in self._consumer_rows:
            self._consumers_group.remove(row)
        self._consumer_rows.clear()
        # A share as a BAR, not as "25% of what this project is holding" written
        # out on every row. Four rows all saying 25% is four copies of a
        # sentence that told you nothing; four bars of equal length say the same
        # thing instantly, and an outlier is visible without reading.
        biggest = rows[0][1] if rows else 1.0
        for name, value, share in rows:
            row = Adw.ActionRow(title=plain(name), use_markup=False)
            bar = Bar()
            bar.set_size_request(140, -1)
            bar.set(value / biggest if biggest else 0, RAMP["calm"])
            bar.set_tooltip_text(f"{share:.0f}% of what this project is holding")
            row.add_suffix(bar)
            label = Gtk.Label(label=human_bytes(value), valign=Gtk.Align.CENTER,
                              xalign=1, width_chars=10)
            label.add_css_class("numeric")
            row.add_suffix(label)
            row.set_activatable(True)
            row.connect("activated", lambda _r, n=name: self._show_detail(n))
            self._consumers_group.add(row)
            self._consumer_rows.append(row)
        self._consumers_group.set_visible(bool(rows))

    def _build_components(self) -> Gtk.Widget:
        # Twelve rows plus six headings is a lot of scrolling to answer "is
        # sales up". The terminal dashboard has `/` for exactly this.
        self._comp_filter = Gtk.SearchEntry(placeholder_text="Filter components",
                                            margin_top=10, margin_bottom=2,
                                            margin_start=12, margin_end=12)
        self._comp_filter.connect("search-changed", lambda _e: self._filter_changed())

        # A Box, not an AdwPreferencesPage: that widget carries its own clamp
        # at about 600px which cannot be widened, and it was what squeezed
        # every component's figures into a run-on subtitle while half the
        # window sat empty. The groups inside are unchanged.
        self._comp_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18,
                                  margin_top=6, margin_bottom=24,
                                  margin_start=12, margin_end=12)
        # A filter that hides everything must say so. Without this, turning off
        # "show stopped" on a stack that is entirely down looks identical to the
        # app being broken.
        self._empty_label = Gtk.Label(wrap=True, justify=Gtk.Justification.CENTER,
                                      margin_top=24, margin_bottom=24)
        self._empty_label.add_css_class("dim-label")
        self._empty_group = Adw.PreferencesGroup(visible=False)
        self._empty_group.add(self._empty_label)
        self._dep_group = Adw.PreferencesGroup(title="Dependencies")
        self._comp_page.append(self._empty_group)
        self._comp_page.append(self._dep_group)

        # AdwPreferencesPage clamps to ~600px whatever the window is doing,
        # which on a wide screen leaves most of it empty and squeezes the
        # figures on every row into a run-on subtitle. Its own clamp, set wide
        # enough for the columns below to line up.
        clamp = Adw.Clamp(maximum_size=1240, tightening_threshold=900,
                          child=self._comp_page)
        scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER,
                                      child=clamp, vexpand=True)
        # The filter stays put while the list scrolls under it — a search box
        # you have to scroll back up to reach is one you stop using.
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(Adw.Clamp(maximum_size=1240, tightening_threshold=900,
                             child=self._comp_filter))
        box.append(scroller)
        return box

    def _filter_changed(self) -> None:
        self._layout_key = None            # the visible set changed; rebuild
        if self._last_components:
            self._render_components(self._last_components, self._colors)

    def _build_resources(self) -> Gtk.Widget:
        self._cpu_graph = Graph("cpu", floor=100, fmt=lambda v: f"{v:.0f}%", percentage=True)
        # A 512 MiB floor squashed a small stack into the bottom tenth of the
        # plot — four node processes at 110 MiB total drew a flat line on the
        # axis. The floor is there to stop the scale jumping about, and 128 MiB
        # does that without pretending the machine is busier than it is.
        self._rss_graph = Graph("rss", floor=128 * 1024 ** 2, fmt=human_bytes)
        self._legend = Gtk.FlowBox(
            selection_mode=Gtk.SelectionMode.NONE, max_children_per_line=4,
            row_spacing=4, column_spacing=16)

        self._scale_toggle = SegmentedControl(on_change=self._apply_scale,
                                              halign=Gtk.Align.END)
        self._scale_toggle.add_option("fit", "Fit")
        self._scale_toggle.add_option("machine", "Machine")
        self._scale_toggle.set_tooltip_text(
            "Fit scales to what the project uses; Machine scales to this machine's RAM")

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                      margin_top=18, margin_bottom=18, margin_start=18, margin_end=18)
        for title, graph in (("CPU", self._cpu_graph), ("Memory", self._rss_graph)):
            label = Gtk.Label(label=title, halign=Gtk.Align.START, hexpand=True)
            label.add_css_class("heading")
            if title == "Memory":
                head = Gtk.Box(spacing=8)
                head.append(label)
                head.append(self._scale_toggle)
                box.append(head)
            else:
                box.append(label)
            # CPU gets less room than memory on purpose: it is near zero most
            # of the time and spikes briefly, while memory is the line anyone
            # actually watches. Equal halves gave the less useful chart the
            # same 230px as the more useful one.
            graph.set_content_height(130 if title == "CPU" else 210)
            frame = Gtk.Frame()
            frame.set_child(graph)
            box.append(frame)
        share_label = Gtk.Label(label="Share of memory", halign=Gtk.Align.START)
        share_label.add_css_class("heading")
        box.append(share_label)
        self._share = ShareChart()
        share_frame = Gtk.Frame()
        share_frame.set_child(self._share)
        box.append(share_frame)

        box.append(self._legend)

        # What the project costs, against what the machine actually has. Without
        # the second number the first one means nothing: 1.6 GiB is nothing on a
        # 64G workstation and most of a 2G container.
        self._machine_label = Gtk.Label(halign=Gtk.Align.START, wrap=True, xalign=0)
        self._machine_label.add_css_class("caption")
        self._machine_label.add_css_class("dim-label")
        box.append(self._machine_label)

        scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER)
        scroller.set_child(box)
        return scroller

    def _build_logs(self) -> Gtk.Widget:
        self._logs = LogView(self._toast)
        return self._logs

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

    def _refresh_profiles(self, profile_dir: str | None) -> None:
        names = profile_names(profile_dir)
        if names == getattr(self, "_profile_names", None):
            return
        self._profile_names = names
        self._profiles_menu.remove_all()
        if not names:
            # An empty submenu looks broken. Say why it is empty instead — and
            # still offer the way to make one.
            item = Gio.MenuItem.new("No saved profiles", None)
            item.set_action_and_target_value("win.noop", None)
            self._profiles_menu.append_item(item)
            self._profiles_menu.append_section(None, self._profiles_menu_end)
            return
        for name in names:
            item = Gio.MenuItem.new(f"Start @{name}", None)
            item.set_action_and_target_value("win.profile", GLib.Variant.new_string(name))
            self._profiles_menu.append_item(item)
        self._profiles_menu.append_section(None, self._profiles_menu_end)

    def _show_detail(self, name: str) -> None:
        comp = next((c for c in self._last_components if c["name"] == name), None)
        if comp is None or not self._project:
            return
        # Kept, so every later frame reaches it: watching a heap climb is
        # exactly what someone opens this for, and a dialog frozen at the
        # instant you clicked is a screenshot, not a monitor.
        dialog = DetailDialog(self._runner, self._project, comp, self._last_log_dir,
                              self._last_at, self._show_logs_for)
        self._detail = dialog
        dialog.connect("closed", lambda _d: setattr(self, "_detail", None))
        dialog.present(self)

    def _show_logs_for(self, name: str, errors_only: bool = False) -> None:
        """Hand off from a component row (or a crash notification) to its log."""
        self._stack.set_visible_child_name("logs")
        self._logs.show_component(name, errors_only)

    def _show_doctor(self) -> None:
        if not self._project:
            self._toast("no project selected")
            return
        DoctorDialog(self._runner, self._project).present(self)

    def _show_tools(self) -> None:
        if not self._project:
            self._toast("no project selected")
            return
        ToolsDialog(self._runner, self._project, self._shells, self._toast).present(self)

    def _show_profiles(self) -> None:
        if not self._project:
            self._toast("no project selected")
            return
        running = [c["name"] for c in self._last_components
                   if c.get("state") in ("up", "starting", "external")]
        ProfilesDialog(self._runner, self._project, running,
                       profile_names(self._last_profile_dir),
                       lambda: profile_names(self._last_profile_dir),
                       self._toast).present(self)

    def _show_limits(self) -> None:
        if not self._project:
            self._toast("no project selected")
            return
        if not self._last_components:
            # The caps arrive in the same frame as everything else, so there is
            # nothing sensible to show until one has landed.
            self._toast("waiting for the first frame")
            return

        def changed() -> None:
            # A cap only takes effect at start, so nothing on screen changes yet;
            # the next frame carries the new number and the row subtitles follow.
            self._layout_key = None
        LimitsDialog(self._runner, self._project, self._last_components, changed).present(self)

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
        listing.add(self._switch_row(
            "notify", "Notify when something crashes", "none", "crash",
            "A desktop notification for an up → crashed transition"))
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
        if key == "notify":
            self._crashes.enabled = value == "crash"
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
        for row, _dot, _badge in list(self._dep_rows.values()):
            self._dep_group.remove(row)
        self._dep_rows.clear()

    def _restart_stream(self) -> None:
        if self._stream:
            self._stream.stop()
        self._logs.stop()          # its file belongs to the project we are leaving
        # A component already crashed in the project you just switched TO is not
        # news — only a crash you were watching happen is.
        self._crashes.reset()
        self._series.clear()
        self._clear_lists()
        self._have_frame = False
        self._deep_findings = []
        self._live_findings = []
        self._verdict_title.set_text("…")
        self._verdict_sub.set_text("waiting for the first sample")
        self._verdict_dot.set_color(STATE_STYLE["down"][1])
        self._show_empty_state(0, 0)

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
        self._have_frame = True
        components = state.get("components", [])
        self._last_components = components
        # The stream's own clock, not the GUI's: uptime is measured against the
        # frame that reported it, and the two machines could disagree.
        self._last_at = state.get("at") or 0
        self._last_log_dir = state.get("logDir")
        colors = {c["name"]: SERIES_COLORS[i % len(SERIES_COLORS)]
                  for i, c in enumerate(components)}
        self._colors = colors
        history = self._settings["history"]

        for comp in components:
            name = comp["name"]
            series = self._series.get(name)
            if series is None:
                series = self._series[name] = Series(name, colors[name], history)
            series.push(comp.get("cpu"), comp.get("rss"))

        self._logs.update_sources(state.get("logDir"), components, state.get("errorPattern"))
        self._last_profile_dir = state.get("profileDir")
        self._shells = sorted(state.get("shells") or [])
        self._refresh_profiles(state.get("profileDir"))
        self._crashes.check(components)
        self._render_components(components, colors)
        self._render_deps(state.get("deps", []))
        self._render_graphs(components, history)

        self._render_overview(state)
        if self._detail is not None:
            live = next((c for c in components if c["name"] == self._detail.comp_name), None)
            if live is not None:
                self._detail.update(live)
        summary = state.get("summary", {})
        self._update_running_pill(state, components, summary)
        self._update_machine_summary(components, state.get("machine") or {})
        counts = [f"{summary[k]} {k}" for k in ("up", "starting", "crashed", "down") if summary.get(k)]
        self.set_title(f"{state.get('project') or 'pitcrew'} — {' · '.join(counts)}")

    def _render_components(self, components: list[dict], colors: dict[str, str]) -> None:
        mode = self._settings["group"]
        total = len(components)
        needle = self._comp_filter.get_text().strip().lower()
        if needle:
            components = [c for c in components
                          if needle in c["name"].lower() or needle in (c.get("app") or "").lower()]
        if self._settings["stopped"] == "hide":
            components = [c for c in components
                          if c.get("state") in ("up", "starting", "external", "crashed")]

        buckets: dict[tuple[str, str], list[dict]] = {}
        for comp in components:
            buckets.setdefault(group_of(comp, mode), []).append(comp)
        ordered = sorted(buckets.items())
        self._show_empty_state(len(components), total, needle)

        # Rebuild only when the shape changed — a new project, a settings change,
        # or a component appearing. Otherwise every frame would throw away and
        # recreate every widget, losing scroll position and focus twice a second.
        layout_key = (mode, tuple((heading, tuple(c["name"] for c in comps))
                                  for (_sort, heading), comps in ordered))
        if layout_key != self._layout_key:
            self._rebuild_components(ordered, colors)
            self._layout_key = layout_key

        now = self._last_at
        auto = self._settings["collapse"] == "auto"
        for (_sort, heading), comps in ordered:
            for comp in comps:
                self._rows[comp["name"]].update(comp, now)
            if heading not in self._pinned:
                self._collapsed[heading] = auto and group_is_idle(comps)
            self._apply_collapse(heading)
            group = self._group_widgets.get(heading)
            if group is not None:
                group.set_description(self._group_summary(comps))

    def _rebuild_components(self, ordered, colors: dict[str, str]) -> None:
        for group in self._groups:
            self._comp_page.remove(group)
        self._groups.clear()
        self._rows.clear()
        self._group_widgets.clear()
        self._group_toggles = {}
        self._group_rows: dict[str, list] = {}

        # Lift the dependencies group out once, then put it back last, so it
        # stays pinned below the components however many groups there are.
        # AdwPreferencesPage only appends, so ordering means re-adding.
        self._comp_page.remove(self._dep_group)
        for (_sort, heading), comps in ordered:
            group = Adw.PreferencesGroup(title=plain(heading))
            # Starting "sales" means both its roles. Doing that one row at a
            # time is the commonest thing anyone does here, so it belongs on
            # the heading rather than in a menu.
            group.set_header_suffix(self._group_actions(heading, comps))
            for comp in comps:
                row = ComponentRow(comp["name"], colors[comp["name"]], self._run_action,
                                   self._show_logs_for)
                row.set_activatable(True)
                row.connect("activated", lambda _r, n=comp["name"]: self._show_detail(n))
                group.add(row)
                self._rows[comp["name"]] = row
                self._group_rows.setdefault(heading, []).append(row)
            self._comp_page.append(group)
            self._groups.append(group)
            self._group_widgets[heading] = group
        self._comp_page.append(self._dep_group)

    def _show_empty_state(self, shown: int, total: int, needle: str = "") -> None:
        if shown:
            self._empty_group.set_visible(False)
            return
        if not self._have_frame:
            self._empty_label.set_text("Waiting for the first sample from pitcrew…")
        elif needle:
            self._empty_label.set_text(f"Nothing matches “{needle}”.")
        else:
            self._empty_label.set_text(empty_message(total))
        self._empty_group.set_visible(True)

    def _group_actions(self, heading: str, comps: list[dict]) -> Gtk.Widget:
        names = [c["name"] for c in comps]
        running = [c for c in comps if c.get("state") in ("up", "starting", "external")]
        box = Gtk.Box(spacing=4, valign=Gtk.Align.CENTER)

        # Six headings and twelve rows is a lot of scrolling to reach the two
        # apps you are actually working on. A group with nothing running folds
        # by default; the heading keeps its summary and its buttons, so a folded
        # group is still readable and still actionable.
        toggle = Gtk.Button(icon_name="pan-down-symbolic", tooltip_text="Collapse")
        toggle.add_css_class("flat")
        toggle.connect("clicked", lambda _b, h=heading: self._toggle_group(h))
        box.append(toggle)
        self._group_toggles[heading] = toggle

        if len(running) < len(comps):
            box.append(self._icon_button("media-playback-start-symbolic", "Start all",
                                         lambda: self._run_action("start", *names)))
        if running:
            box.append(self._icon_button("view-refresh-symbolic", "Restart all",
                                         lambda: self._run_action("restart", *names)))
            box.append(self._icon_button("media-playback-stop-symbolic", "Stop all",
                                         lambda: self._run_action("stop", *names)))
        return box

    def _toggle_group(self, heading: str) -> None:
        # An explicit click wins over the automatic rule for the rest of the
        # session: having a group you just opened fold itself again on the next
        # frame would be maddening.
        self._collapsed[heading] = not self._collapsed.get(heading, False)
        self._pinned.add(heading)
        self._apply_collapse(heading)

    def _apply_collapse(self, heading: str) -> None:
        folded = self._collapsed.get(heading, False)
        for row in self._group_rows.get(heading, []):
            row.set_visible(not folded)
        toggle = self._group_toggles.get(heading)
        if toggle is not None:
            toggle.set_icon_name("pan-end-symbolic" if folded else "pan-down-symbolic")
            toggle.set_tooltip_text("Expand" if folded else "Collapse")

    @staticmethod
    def _icon_button(icon: str, tooltip: str, action) -> Gtk.Button:
        button = Gtk.Button(icon_name=icon, tooltip_text=tooltip)
        button.add_css_class("flat")
        button.connect("clicked", lambda _b: action())
        return button

    @staticmethod
    def _group_summary(comps: list[dict]) -> str:
        up = sum(1 for c in comps if c.get("state") == "up")
        rss = sum(c.get("rss") or 0 for c in comps)
        capped = sum(c.get("limit") or 0 for c in comps)
        parts = [f"{up}/{len(comps)} up"]
        if rss:
            parts.append(human_bytes(rss))
        if capped:
            parts.append(f"capped at {human_bytes(capped)}")
        return "  ·  ".join(parts)

    def _render_deps(self, deps: list[dict]) -> None:
        # Dependencies were the one thing on this page you could look at and not
        # touch — `pitcrew start deps` existed and had no button. A dead
        # postgres is the commonest reason a stack looks broken, so the fix
        # belongs next to the symptom.
        for dep in deps:
            row = self._dep_rows.get(dep["name"])
            if row is None:
                row = Adw.ActionRow(title=dep["name"], use_markup=False)
                dot = Dot(STATE_STYLE.get(dep["state"], UNKNOWN_STYLE)[1])
                row.add_prefix(dot)
                badge = Gtk.Label(valign=Gtk.Align.CENTER, xalign=0, width_chars=8)
                badge.add_css_class("caption")
                badge.add_css_class("dim-label")
                row.add_suffix(badge)
                box = Gtk.Box(spacing=4, valign=Gtk.Align.CENTER)
                box.append(self._icon_button(
                    "media-playback-start-symbolic", "Start dependencies",
                    lambda: self._run_action("start", "deps")))
                box.append(self._icon_button(
                    "view-refresh-symbolic", f"Restart {dep['name']}",
                    lambda n=dep["name"]: self._restart_dep(n)))
                row.add_suffix(box)
                self._dep_group.add(row)
                self._dep_rows[dep["name"]] = (row, dot, badge)
            row, dot, badge = self._dep_rows[dep["name"]]
            dot.set_color(STATE_STYLE.get(dep["state"], UNKNOWN_STYLE)[1])
            badge.set_text(dep["state"])
        self._dep_group.set_visible(bool(self._dep_rows))

    def _restart_dep(self, name: str) -> None:
        # `pitcrew stop --deps` refuses PITCREW_PROTECTED_DEPS, which is the
        # whole point of that list — so this cannot tear down your database by
        # accident, and says so when it declines.
        dialog = Adw.AlertDialog(
            heading=f"Restart {name}?",
            body="Stops non-protected dependencies and starts them again.\n"
                 "Anything in protected_deps is left alone.")
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("go", "Restart")
        dialog.set_response_appearance("go", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.connect("response", lambda _d, r: (
            self._run_action("stop", "--deps") if r == "go" else None))
        dialog.present(self)

    def _render_graphs(self, components: list[dict], history: int) -> None:
        if self._settings["plot"] == "all":
            wanted = {c["name"] for c in components}
        else:
            # A dozen flat zeroes for stopped services hides the two you care about.
            wanted = {c["name"] for c in components
                      if c.get("state") in ("up", "starting", "external")}
        # The legend still lists a muted series — hiding its own off-switch is
        # how a toggle becomes a trap.
        listed = [s for name, s in self._series.items() if name in wanted]
        plotted = [s for s in listed if s.name not in self._hidden]
        self._cpu_graph.set_series(plotted, history)
        self._rss_graph.set_series(plotted, history)
        window = human_age(history * self._settings["interval"]) or ""
        for graph in (self._cpu_graph, self._rss_graph):
            graph.set_window(f"last {window}" if window else "")
        self._rebuild_legend(listed)

        by_name = {c["name"]: c for c in components}
        colour = {s.name: s.rgb for s in plotted}
        rows, total = share_slices((s.name, by_name.get(s.name, {}).get("rss") or 0)
                                   for s in plotted)
        self._share.set_slices(((n, v, colour[n]) for n, v in rows), total)

    def _update_machine_summary(self, components: list[dict], machine: dict) -> None:
        used = sum(c.get("rss") or 0 for c in components)
        capped = sum(c.get("limit") or 0 for c in components)
        total = machine.get("memTotal") or 0

        parts = [f"This project is using {human_bytes(used)}"]
        if total:
            parts[0] += f" of {human_bytes(total)} on this machine"
            parts.append(f"machine total {machine.get('memUsed') and human_bytes(machine['memUsed']) or '—'} "
                         f"used · {machine.get('cpuPercent', 0)}% cpu")
        if capped:
            over = " — more than the machine has" if total and capped > total else ""
            parts.append(f"caps commit {human_bytes(capped)}{over}")
        self._machine_label.set_text("   ·   ".join(parts))
        self._machine_total = total
        self._apply_scale()

    def _apply_scale(self) -> None:
        machine = self._scale_toggle.get_active_name() == "machine"
        self._rss_graph.set_ceiling(getattr(self, "_machine_total", 0) if machine else None)

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

            # The legend is the natural place to mute a series: twelve
            # overlapping lines are unreadable, and the entry naming one is
            # exactly where you reach to say "not that one".
            button = Gtk.Button(child=box, tooltip_text=f"Show or hide {item.name}")
            button.add_css_class("flat")
            if item.name in self._hidden:
                button.set_opacity(0.4)
            button.connect("clicked", lambda _b, n=item.name: self._toggle_series(n))
            self._legend.append(button)

    def _toggle_series(self, name: str) -> None:
        self._hidden.symmetric_difference_update({name})
        if self._last_components:
            self._render_graphs(self._last_components, self._settings["history"])

    # ── actions ─────────────────────────────────────────────────────────────
    def _run_action(self, verb: str, *components: str) -> None:
        """One component, a whole app, a profile, or everything — same path."""
        component = components[0] if len(components) == 1 else f"{len(components)} components"
        argv = cli_argv(self._pitcrew, ["-p", self._project, verb, *components])
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
