"""The main window: the three views and everything that keeps them current."""

from __future__ import annotations

import os

from gi.repository import Adw, Gio, GLib, Gtk

from . import ansi, theme
from .dialogs import (
    ConfigDialog,
    DetailDialog,
    DoctorDialog,
    InitDialog,
    LimitsDialog,
    ProfilesDialog,
    ToolsDialog,
)
from .logview import LogView, LogWindow
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
    report_panels,
    share_slices,
    state_rank,
    top_consumers,
    verdict_of,
)
from .notify import CrashWatcher
from .platform import cli_argv
from .registry import current_project, known_projects
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
    set_row_compact,
)

# How wide the content column is allowed to get. Wide enough for the
# component table's columns to line up; zen narrows it, because a verdict and
# two findings stretched across 1240px is the same emptiness as the terminal's
# full-width table with two rows in it.
CLAMP_WIDE = 1240
# Not a taste number: a ComponentRow's own natural width is ~755px, and
# clamped under that the flexible part — the component's NAME — is the thing
# that gives, so "be-billing" wrapped to "be-billi-/ng" mid-word. Narrow enough
# to read in one go, never narrower than a row needs.
CLAMP_ZEN = 800


class Window(Adw.ApplicationWindow):
    def __init__(self, pitcrew: str, project: str | None, settings: Settings, **kwargs):
        super().__init__(**kwargs)
        self._pitcrew = pitcrew
        self._project = project
        self._settings = settings
        self._runner = Runner(pitcrew)
        self._init_state()

        # Before a single widget is built. The palettes the widgets draw from
        # are module-level dicts, and a Dot built now keeps the colour it was
        # handed — so a theme applied afterwards would reach the graphs and
        # miss every dot in the window.
        self._apply_theme(repaint=False)
        # Light/dark stays the desktop's decision, and a dark palette on a
        # light background is unreadable — so the adaptation has to be redone
        # when the desktop changes its mind, not only at startup.
        Adw.StyleManager.get_default().connect(
            "notify::dark", lambda *_: self._apply_theme())
        self._watch_theme_file()
        self.set_title("pitcrew")
        # Remembered across runs: reopening at 900x680 on every launch, on the
        # tab you were not using, is a small insult repeated daily.
        self.set_default_size(settings["width"], settings["height"])
        self.connect("close-request", self._remember_geometry)

        self._crashes = CrashWatcher(kwargs.get("application"), self._show_logs_for)
        self._crashes.enabled = settings["notify"] == "crash"

        self._stack = Adw.ViewStack()
        # A stack sizes to its LARGEST child unless told otherwise, so the Logs
        # page's toolbar — the widest thing in the app — set the minimum width
        # of every other page. Projects needs 127px and was being given 854,
        # which is why a narrow window clipped rows that had room to shrink.
        self._stack.set_hhomogeneous(False)
        self._stack.set_vhomogeneous(False)
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

        header = self._build_header()

        self._banner = Adw.Banner(revealed=False)
        # Stated rather than assumed: the messages here are pitcrew's own
        # stderr, which contains `<dir>` and paths, and whether they are parsed
        # as markup decides whether _fail must escape them. Guarded because the
        # property is newer than the libadwaita floor this app supports.
        if hasattr(self._banner, "set_use_markup"):
            self._banner.set_use_markup(False)
        self._banner.set_button_label("Retry")
        self._banner.connect("button-clicked", lambda _b: self._restart_stream())

        # Before the first frame there is nothing to show, and five empty pages
        # behind a switcher is a window that looks broken rather than one that
        # has not been told anything yet. The banner alone was the whole answer
        # for a brand-new install: a strip of text across an empty window,
        # which is the right weight for a transient failure and the wrong one
        # for "you have not set anything up".
        #
        # Swapped out on the first frame and never swapped back — a stream that
        # drops later has a banner AND a window full of the last known state,
        # which is more use than a status page that throws it away.
        self._welcome = self._build_welcome()
        self._body = Gtk.Stack()
        # Same reason: the welcome page must not be held to the width of the
        # live one, or a fresh install cannot be resized either.
        self._body.set_hhomogeneous(False)
        self._body.set_vhomogeneous(False)
        self._body.add_named(self._welcome, "welcome")
        self._body.add_named(self._stack, "live")
        self._body.set_visible_child_name("welcome")

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        content.append(self._banner)
        content.append(self._body)

        view = Adw.ToolbarView()
        view.add_top_bar(header)
        view.set_content(content)

        self._toasts = Adw.ToastOverlay()
        self._toasts.set_child(view)
        self.set_content(self._toasts)

        self._install_breakpoints()
        self._install_shortcuts()
        if settings["tab"] in ("overview", "components", "resources", "logs", "projects"):
            self._stack.set_visible_child_name(settings["tab"])
        # Before the stream has had a chance to fail. On a fresh install there
        # is nothing to stream FROM, and waiting for the failure to say so
        # means a second of "Starting up" that is not true.
        self._update_welcome()
        self._restart_stream()

    def _install_breakpoints(self) -> None:
        """Every width decision in one place.

        Scattered through a constructor that also builds five pages, these read
        as incidental; together they are the app's whole responsive behaviour,
        and the order they fire in matters.
        """
        # Two columns above ~880px, stacked below it. Without this the Overview
        # is unusable in a half-screen window: two 440px columns of meters and
        # findings both truncate rather than one of them wrapping.
        breakpoint_ = Adw.Breakpoint.new(
            Adw.BreakpointCondition.parse("max-width: 880px"))
        breakpoint_.add_setter(self._columns, "orientation", Gtk.Orientation.VERTICAL)
        breakpoint_.add_setter(self._left, "width-request", -1)
        self.add_breakpoint(breakpoint_)

        # The Logs toolbar is the widest thing in the app — a row of controls
        # that cannot wrap. Below this the role filter goes: the picker next to
        # it selects a component outright, so the roles are a shortcut rather
        # than the only way through, and losing a shortcut beats a toolbar that
        # runs off the edge of the window.
        narrow = Adw.Breakpoint.new(
            Adw.BreakpointCondition.parse("max-width: 700px"))
        narrow.add_setter(self._logs.role_filter(), "visible", False)
        # The component table's columns are fixed so they line up, so the only
        # way to make it narrower is to lose one. Rows come and go, so this is
        # a signal rather than a setter on a fixed set of objects.
        narrow.connect("apply", lambda _b: self._set_compact(True))
        narrow.connect("unapply", lambda _b: self._set_compact(False))
        self.add_breakpoint(narrow)

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
        # Set by the narrow breakpoint. Read when a row is built, so one made
        # while the window is already narrow does not flash wide for a frame.
        self._compact = False
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
        self._last_pattern: str | None = None
        # Detached logs. Keyed by component so asking for the same one twice
        # raises the window you already have rather than stacking a second copy
        # of it on top.
        self._log_windows: dict[str, LogWindow] = {}
        self._last_profiles: list[dict] = []
        self._shells: list[str] = []
        self._detail: object | None = None
        self._machine_total = 0
        self._last_at = 0
        self._last_state: dict | None = None
        # Zen is a FILTER, not a separate screen. See _apply_zen.
        self._zen = False

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

        zen = Gio.SimpleAction.new("zen", None)
        zen.connect("activate", lambda *_: self._toggle_zen())
        self.add_action(zen)

        shortcuts = Gio.SimpleAction.new("shortcuts", None)
        shortcuts.connect("activate", lambda *_: self._show_shortcuts())
        self.add_action(shortcuts)

        for index, view in enumerate(views, start=1):
            app.set_accels_for_action(f"win.view::{view}", [f"<Primary>{index}"])
        app.set_accels_for_action("win.focusfilter", ["slash", "<Primary>f"])
        app.set_accels_for_action("win.shortcuts", ["<Primary>question", "question"])
        app.set_accels_for_action("win.limits", ["<Primary>m"])
        app.set_accels_for_action("win.zen", ["<Primary>z"])
        app.set_accels_for_action("win.up", ["<Primary>Return"])
        app.set_accels_for_action("win.stopall", ["<Primary><Shift>Return"])
        # Alt, not Primary: Ctrl+1…4 already switch views, and a profile is the
        # other thing you reach for by number.
        for slot in range(1, 10):
            app.set_accels_for_action(f"win.profileat::{slot}", [f"<Alt>{slot}"])

    def _toggle_zen(self) -> None:
        self._zen = not self._zen
        self._apply_zen()
        self._toasts.add_toast(Adw.Toast.new(
            "Zen on — only what needs you" if self._zen else "Zen off — everything is back"))

    def _apply_zen(self) -> None:
        """Zen answers one question: is there anything I need to do?

        So it hides what is fine — healthy components, dependencies that are
        up, the machine meters, the consumer ranking — and keeps the verdict,
        the findings, and anything broken.

        It does NOT hide the view switcher. Chrome is the meters and the
        rankings; navigation is not chrome, and a focus mode you cannot
        navigate out of is a trap rather than a mode. Same reason the terminal
        keeps `q quit` in the hint row.
        """
        self._zen_pill.set_visible(self._zen)
        # Minimal means minimal: in zen the header is the navigation icons and
        # the one green oval. The project name and the up-count are both
        # answers to questions zen is not asking — which project and how much
        # is fine — and the page below already says everything that needs you.
        self._project_button.set_visible(not self._zen)
        self._running_pill.set_visible(not self._zen)
        self._switcher_titles(not self._zen)
        # The whole left COLUMN, not just the groups inside it: it carries a
        # 360px width-request, so hiding only its contents left the findings
        # pinned to the right of a dead gutter a third of the window wide.
        self._left.set_visible(not self._zen)
        self._meters_group.set_visible(not self._zen)
        self._profiles_group.set_visible(bool(getattr(self, "_last_profiles", []))
                                         and not self._zen)
        # Zen is a LAYOUT, not the same page with things hidden: the column
        # narrows, and while its content is short enough it sits in the middle
        # of the window rather than clinging to the top of it.
        width = CLAMP_ZEN if self._zen else CLAMP_WIDE
        for clamp in (self._overview_clamp, self._comp_clamp, self._comp_filter_clamp):
            clamp.set_maximum_size(width)
        # Overview only. The Components list has a filter box pinned above it,
        # and a list floating in the middle of the window with its own filter
        # stranded at the top reads as two unrelated things; a list belongs
        # under the box that filters it.
        self._overview_body.set_valign(Gtk.Align.CENTER if self._zen else Gtk.Align.FILL)
        # The column header goes with the headings. It is sized in characters
        # for the wide column, so in the narrow one it wrapped "component" to
        # one letter per line — but it would be the wrong thing here even if it
        # fitted: a header over a four-row list is what zen exists to remove.
        self._comp_header.set_visible(not self._zen)
        self._layout_key = None            # the visible set changed; rebuild
        if self._last_state is not None:
            self._on_state(self._last_state)

    def _switcher_titles(self, show: bool) -> None:
        """Icon-only navigation in zen, with the titles moved to tooltips.

        Adw.ViewSwitcher has no icon-only policy — NARROW stacks the title
        under the icon, WIDE puts it beside — so the titles are hidden one by
        one. Keyed on "this label has text": the other labels in an
        AdwViewSwitcherButton are its badge counters, which are empty and must
        stay that way. Nothing here reads the box-and-stack shape around them,
        so a libadwaita that rearranges it loses the effect rather than
        crashing on a hierarchy that moved.

        The title becomes a tooltip on the way out. Zen may shed chrome but
        never navigation (see _apply_zen), and an unlabelled icon with nothing
        to hover is navigation you have to guess at.
        """
        button = self._switcher.get_first_child()
        while button is not None:
            title = ""
            for label in self._labels_in(button):
                if not label.get_text():
                    continue                      # the badge counter, not a title
                title = title or label.get_text()
                label.set_visible(show)
            if title:
                button.set_tooltip_text(None if show else title)
            button = button.get_next_sibling()

    @classmethod
    def _labels_in(cls, widget: Gtk.Widget) -> list[Gtk.Label]:
        found: list[Gtk.Label] = []
        child = widget.get_first_child()
        while child is not None:
            if isinstance(child, Gtk.Label):
                found.append(child)
            else:
                found.extend(cls._labels_in(child))
            child = child.get_next_sibling()
        return found

    @staticmethod
    def _zen_wants(comp: dict) -> bool:
        """Anything not plainly up earns its row in zen."""
        return comp.get("state") not in ("up", None, "")

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
            ("Alt+1 … Alt+9", "Start a saved profile, in the order the Overview lists them"),
            ("/  or  Ctrl+F", "Filter the log"),
            ("Ctrl+Z", "Zen mode — hide everything that is fine"),
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
    def _build_header(self) -> Gtk.Widget:
        header = Adw.HeaderBar()
        # NARROW stacks the icon over the label, which is what makes four views
        # fit: WIDE puts them side by side and truncated every title to "Comp…"
        # the moment a fourth tab arrived.
        self._switcher = Adw.ViewSwitcher(stack=self._stack,
                                          policy=Adw.ViewSwitcherPolicy.NARROW)
        header.set_title_widget(self._switcher)
        header.pack_start(self._build_project_button())
        header.pack_start(self._build_running_pill())
        header.pack_end(self._build_menu_button())
        header.pack_end(self._build_zen_pill())
        return header

    def _build_zen_pill(self) -> Gtk.Widget:
        """The mode indicator: one green oval, and nothing else.

        Zen hides rows, so it has to announce itself — a window that is quietly
        not showing you six services is worse than one that never had them. But
        announcing it is the whole job, and this has been talked out of every
        extra it accumulated: an icon, a live count of what was hidden, then a
        status dot beside the word. Each was defensible and together they made
        the one calm thing in the header the widest thing in it.

        So the oval IS the indicator. Green because zen being on is fine —
        Adwaita's own success pair, so the fill and the text on it stay legible
        in light and dark rather than being a hex value that only works in one.
        In zen it is also the only coloured thing left up there, which is what
        makes a single small pill enough to carry the message.

        The ✕ is transparent until hover, with its width reserved either way.
        With the project name and the running count gone in zen, this chip is
        the only thing on screen that says how to get out, so it keeps the
        affordance even while it looks like it has nothing but a word in it.
        """
        name = Gtk.Label(label="zen")
        name.add_css_class("caption-heading")
        close = Gtk.Image.new_from_icon_name("window-close-symbolic")
        close.set_pixel_size(11)
        close.add_css_class("zen-pill-close")

        # Margins rather than CSS padding. A header-bar button's padding comes
        # from the theme and beats an application rule for it: setting `padding`
        # on .zen-pill changed the oval's width by exactly nothing, at any
        # value, which is the kind of rule that looks like it works. A margin on
        # the child is ours and cannot be themed away.
        #
        # Asymmetric on purpose: the reserved width of the invisible close mark
        # is trailing space already, so the two sides read as even.
        box = Gtk.Box(spacing=5, valign=Gtk.Align.CENTER,
                      margin_start=11, margin_end=2)
        for child in (name, close):
            box.append(child)
        self._zen_pill = Gtk.Button(child=box, visible=False, valign=Gtk.Align.CENTER)
        self._zen_pill.add_css_class("zen-pill")
        self._zen_pill.connect("clicked", lambda _b: self._toggle_zen())
        self._update_zen_pill(0)
        return self._zen_pill

    def _update_zen_pill(self, hidden: int) -> None:
        """What zen is holding back. Not on the chip — in the tooltip.

        On the chip it was noise on every frame; here it is an answer to the
        question the chip provokes, available the moment anyone asks it.
        """
        self._zen_pill.set_tooltip_text(
            f"Zen is hiding {hidden} component{'' if hidden == 1 else 's'} that are fine.\n"
            "Click or Ctrl+Z to show everything again."
            if hidden else
            "Zen is on, and nothing is being hidden — everything here needs you.\n"
            "Click or Ctrl+Z to leave.")

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
        #
        # Keyed on zen, not a bare True: this runs on every frame, so a flat
        # `set_visible(True)` would put the pill back half a second after zen
        # took it away, and only sometimes — which is worse than never hiding it.
        self._running_pill.set_visible(not self._zen)

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

        at_action = Gio.SimpleAction.new("profileat", GLib.VariantType.new("s"))
        at_action.connect("activate",
                          lambda _a, t: self._profile_at(int(t.get_string()) - 1))
        self.add_action(at_action)

        menu.append("Zen mode", "win.zen")
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
    def _build_welcome(self) -> Gtk.Widget:
        """What the window says before it has been told anything.

        Three different situations arrive here and they want different words:
        nothing is registered at all, a project is selected but its config
        cannot be read, or the stream simply has not produced a frame yet. The
        third is a fraction of a second and needs no button; the first is
        somebody's first minute with the tool and needs the only one that
        matters.
        """
        self._welcome_page = Adw.StatusPage(
            icon_name="application-x-executable-symbolic",
            title="Starting up",
            description="Waiting for the first frame…")
        self._welcome_button = Gtk.Button(halign=Gtk.Align.CENTER)
        self._welcome_button.add_css_class("suggested-action")
        self._welcome_button.add_css_class("pill")
        self._welcome_button.set_child(Adw.ButtonContent(
            icon_name="folder-open-symbolic", label="Add a project…"))
        self._welcome_button.connect("clicked", lambda _b: self._add_project())
        self._welcome_button.set_visible(False)
        self._welcome_page.set_child(self._welcome_button)
        return self._welcome_page

    def _update_welcome(self, message: str | None = None) -> None:
        """Say which of the three situations this is, and offer the way out.

        Called on a stream failure and once at startup. Never after a frame has
        arrived: past that point the window has real content and a failure is
        the banner's job.
        """
        if self._have_frame:
            return
        if not known_projects():
            # Somebody's first minute. `pitcrew init` is the only thing that
            # helps, and naming the command is not the same as offering it.
            self._welcome_page.set_icon_name("folder-new-symbolic")
            self._welcome_page.set_title("No projects yet")
            self._welcome_page.set_description(
                "pitcrew reads a repository and works out what it is — which "
                "directories are services, how to start them, and which ports "
                "they will use.")
            self._welcome_button.set_visible(True)
            return
        if message:
            self._welcome_page.set_icon_name("dialog-warning-symbolic")
            self._welcome_page.set_title("Nothing to show")
            # The CLI's own words: it knows why better than this does, and it
            # is the same sentence the terminal would have printed.
            #
            # Escaped as well as ANSI-stripped, and the two are different jobs.
            # AdwStatusPage:description PARSES markup and has no use-markup
            # property to turn that off, so the one sentence the CLI actually
            # emits here — "no config here — write a pitcrew.yaml, or:
            # pitcrew init <dir>" — failed to parse and the description
            # rendered EMPTY. The page then said "Nothing to show" and gave no
            # reason, which is the one thing this screen exists to do.
            self._welcome_page.set_description(plain(ansi.plain(message)))
            self._welcome_button.set_visible(True)

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
        # Machine and Largest-consumers are one thought — "what is this
        # costing" — so they share the left column, and findings get the right
        # one at full height. Stacked instead, the left column ran out at a
        # third of the page while consumers pushed itself below the fold.
        self._left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=22)
        self._left.append(self._meters_group)
        self._left.set_size_request(360, -1)
        self._left.set_hexpand(False)
        self._columns = Gtk.Box(spacing=24)
        self._columns.append(self._left)
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

        # Profiles, where you land rather than three clicks into a menu.
        #
        # They were reachable only from the app menu, as a list of names — no
        # indication of what a profile covers or whether it is already running,
        # so choosing one meant remembering what you saved six weeks ago. Every
        # number on these rows comes from the stream, which is pitcrew
        # resolving its own target words: "sales" covers whatever sales has
        # TODAY, including a worker that did not exist when the profile was
        # saved.
        self._profiles_group = Adw.PreferencesGroup(
            title="Profiles",
            description="Saved sets of components — Alt+1…9", visible=False)
        manage = Gtk.Button(valign=Gtk.Align.CENTER)
        manage.set_child(Adw.ButtonContent(icon_name="document-properties-symbolic",
                                           label="Manage"))
        manage.connect("clicked", lambda _b: self._show_profiles())
        self._profiles_group.set_header_suffix(manage)
        self._profile_rows: list[Adw.ActionRow] = []

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=22,
                       margin_top=20, margin_bottom=24, margin_start=18, margin_end=18)
        self._left.append(self._consumers_group)
        body.append(self._verdict_banner)
        body.append(self._columns)
        body.append(self._build_reports_box())
        body.append(self._profiles_group)
        body.append(self._recover_group)
        body.append(self._protected_group)

        self._overview_body = body
        self._overview_clamp = Adw.Clamp(maximum_size=CLAMP_WIDE,
                                         tightening_threshold=900, child=body)
        return Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER,
                                  child=self._overview_clamp)

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
            row = Adw.ActionRow(title=name, subtitle="   ·   ".join(bits),
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
            row = Adw.ActionRow(title=name, use_markup=False,
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
        self._render_reports(report_panels(state))
        extra = len(merge_findings(self._live_findings, self._deep_findings)) \
            - len(self._live_findings)
        # Re-render now rather than waiting for the next frame: a button whose
        # effect appears up to `interval` seconds later reads as broken.
        self._render_findings(merge_findings(self._live_findings, self._deep_findings))
        self._toast(f"full diagnostics found {extra} more"
                    if extra else "full diagnostics found nothing the stream missed")

    def _build_reports_box(self) -> Gtk.Box:
        """Where plugin tables land, empty until a deep run fills it.

        One group per report, built on demand: how many there are and what they
        are called is the plugin's business, and this end knows only that a
        report has a title and rows.

        It sits directly under the findings that reference it. A JVM finding
        says the heap plus non-heap will not fit the cap; the table is the
        arithmetic behind that sentence. Two pages apart they are two unrelated
        facts.
        """
        self._report_groups: list[Adw.PreferencesGroup] = []
        self._reports_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL,
                                    spacing=22, visible=False)
        return self._reports_box

    def _render_reports(self, panels: list[dict]) -> None:
        """One group per plugin report, rebuilt from scratch each deep run.

        Rebuilt rather than diffed: these arrive a few seconds apart at most,
        by hand, and a stale row on a memory table is worse than a rebuild
        nobody can perceive.
        """
        for group in self._report_groups:
            self._reports_box.remove(group)
        self._report_groups.clear()

        for panel in panels:
            title = panel["title"]
            if panel["scope"]:
                title = f"{panel['scope']} — {title}"
            group = Adw.PreferencesGroup(title=plain(title))
            for row in panel["rows"]:
                # The label is the measurement and the value is the figure, so
                # the value goes where the eye scans down a column. The note is
                # the qualifier that keeps the figure honest — "a floor",
                # "reserved, not committed" — and belongs beside it, not in a
                # tooltip nobody opens.
                action = Adw.ActionRow(title=row.get("label") or "",
                                       use_markup=False,
                                       subtitle=row.get("note") or "")
                value = Gtk.Label(label=row.get("value") or "",
                                  valign=Gtk.Align.CENTER)
                value.add_css_class("numeric")
                action.add_suffix(value)
                group.add(action)
            self._reports_box.append(group)
            self._report_groups.append(group)

        self._reports_box.set_visible(bool(self._report_groups))

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
            row = Adw.ActionRow(title=name, use_markup=False)
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
        # "What is eating my RAM" is a good question and not this one.
        self._consumers_group.set_visible(bool(rows) and not self._zen)

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
        self._comp_clamp = Adw.Clamp(maximum_size=CLAMP_WIDE,
                                     tightening_threshold=900, child=self._comp_page)
        clamp = self._comp_clamp
        # Names the columns once, so the rows below stop needing to be read:
        # without it you infer that `:19871` is a port and `8s` is uptime from
        # every row, every time. Built by ComponentRow itself, from the widths
        # the rows actually use.
        # One width for the action column, agreed between the header and every
        # row under it. The header cannot state it in characters — it is a
        # strip of theme-sized icon buttons — and a header column that is not
        # the width of the column it names is worse than no header.
        self._action_sizes = Gtk.SizeGroup(mode=Gtk.SizeGroupMode.HORIZONTAL)
        self._comp_header = ComponentRow.header(self._action_sizes)
        self._comp_page.prepend(self._comp_header)
        scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER,
                                      child=clamp, vexpand=True)
        # The filter stays put while the list scrolls under it — a search box
        # you have to scroll back up to reach is one you stop using.
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self._comp_filter_clamp = Adw.Clamp(maximum_size=CLAMP_WIDE,
                                            tightening_threshold=900,
                                            child=self._comp_filter)
        box.append(self._comp_filter_clamp)
        box.append(scroller)
        return box

    def _set_compact(self, compact: bool) -> None:
        """Tell every component row how much room it has.

        Remembered as well as applied: rows are rebuilt when the shape of the
        list changes, and a row built while the window is narrow has to arrive
        already narrow rather than flashing wide for a frame.
        """
        self._compact = compact
        set_row_compact(self._comp_header, compact)
        for row in self._rows.values():
            row.set_compact(compact)

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
        # The ring only became worth pointing at recently, and an affordance
        # nobody knows about is the same as not having one.
        share_hint = Gtk.Label(label="Point at a slice for its numbers  ·  "
                                     "click to pin  ·  double-click to open it",
                               halign=Gtk.Align.START, xalign=0, wrap=True)
        share_hint.add_css_class("caption")
        share_hint.add_css_class("dim-label")
        share_head = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        share_head.append(share_label)
        share_head.append(share_hint)
        box.append(share_head)
        self._share = ShareChart(on_activate=self._show_detail)
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
        self._logs = LogView(self._toast, on_detach=self._open_log_window)
        return self._logs

    def _build_projects(self) -> Gtk.Widget:
        """What pitcrew knows about every checkout on this machine.

        This was the one view still inside an AdwPreferencesPage — clamped to
        600px with most of the window empty — and it showed a name and a path
        while `pitcrew projects` already printed running counts and
        `pitcrew ports` printed clashes. The GUI was worse than the CLI at the
        one thing the tool sells: several projects on one machine.
        """
        self._projects_group = Adw.PreferencesGroup(
            title="Projects", description="Everything pitcrew knows about on this machine")
        add = Gtk.Button(valign=Gtk.Align.CENTER)
        add.set_child(Adw.ButtonContent(icon_name="list-add-symbolic", label="Add"))
        add.connect("clicked", lambda _b: self._add_project())
        self._projects_group.set_header_suffix(add)
        self._project_rows: list[Adw.ActionRow] = []

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18,
                       margin_top=20, margin_bottom=24, margin_start=18, margin_end=18)
        body.append(self._projects_group)
        clamp = Adw.Clamp(maximum_size=1240, tightening_threshold=900, child=body)
        self._refresh_projects()
        return Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, child=clamp)

    def _refresh_projects(self) -> None:
        # Asked of the CLI, not worked out here: liveness means reading pidfiles
        # and testing pids, which is process discovery — the one thing the GUI
        # does not do. `pitcrew projects --json` already knows.
        self._runner.run_json(["projects", "--json"], self._render_projects)

    def _render_projects(self, state: dict | None, problem: str) -> None:
        for row in self._project_rows:
            self._projects_group.remove(row)
        self._project_rows.clear()

        projects = (state or {}).get("projects") or []
        if not projects:
            row = Adw.ActionRow(
                title=problem or "No projects yet",
                use_markup=False,
                subtitle="Add one to have pitcrew look at a checkout and write its config")
            self._projects_group.add(row)
            self._project_rows.append(row)
            return

        for project in projects:
            self._projects_group.add(self._project_row(project))

    def _project_row(self, project: dict) -> Adw.ActionRow:
        name = project.get("name", "?")
        row = Adw.ActionRow(title=name, use_markup=False,
                            subtitle=self._project_subtitle(project))
        row.set_subtitle_lines(2)

        # A dot that means what it means everywhere else in this app: green if
        # something is running, red if the checkout has gone, grey if idle.
        if not project.get("exists", True):
            row.add_prefix(Dot(STATE_STYLE["crashed"][1]))
        elif project.get("running"):
            row.add_prefix(Dot(STATE_STYLE["up"][1]))
        else:
            row.add_prefix(Dot(STATE_STYLE["down"][1]))

        if project.get("current"):
            badge = Gtk.Label(label="current", valign=Gtk.Align.CENTER)
            badge.add_css_class("caption")
            badge.add_css_class("accent")
            row.add_suffix(badge)

        # A port two projects both claim is not cosmetic: pitcrew decides a
        # component is up from its port, so each project reports the other's
        # services as its own. Worth a warning next to the name.
        clashes = project.get("clashes") or []
        if clashes:
            warn = Gtk.Image(icon_name="dialog-warning-symbolic", valign=Gtk.Align.CENTER)
            warn.add_css_class("warning")
            warn.set_tooltip_text("\n".join(
                f"port {c['port']}: {name}/{c['component']} vs "
                f"{c['project']}/{c['theirs']}" for c in clashes))
            row.add_suffix(warn)

        box = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
        box.append(self._project_button_for(
            "document-edit-symbolic", "Edit config", lambda n=name: self._edit_config(n)))
        box.append(self._project_button_for(
            "media-playback-start-symbolic", "Watch this project",
            lambda n=name: self._switch_to(n)))
        box.append(self._project_button_for(
            "user-trash-symbolic", "Forget", lambda n=name: self._confirm_forget(n)))
        row.add_suffix(box)
        self._project_rows.append(row)
        return row

    @staticmethod
    def _project_subtitle(project: dict) -> str:
        if not project.get("exists", True):
            return f"{project.get('root', '?')}   ·   that directory is gone"
        bits = []
        running = project.get("running") or 0
        bits.append(f"{running} running" if running else "idle")
        ports = project.get("ports") or []
        if ports:
            shown = "  ".join(f":{p['port']}" for p in ports[:6])
            if len(ports) > 6:
                shown += f"  +{len(ports) - 6}"
            bits.append(shown)
        clashes = project.get("clashes") or []
        if clashes:
            others = sorted({c["project"] for c in clashes})
            bits.append(f"shares a port with {', '.join(others)}")
        return f"{project.get('root', '?')}\n" + "   ·   ".join(bits)

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
        def reopen() -> None:
            # A .sh config that has just become a pitcrew.yaml is a different
            # file with a form tab, so the editor opens again on whatever the
            # config now is. Deferred: the dialog asking for this is still
            # closing when it calls.
            GLib.idle_add(lambda: self._edit_config(name) or False)

        ConfigDialog(self._runner, name, saved, reopen).present(self)

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

    def _refresh_profiles(self, profiles: list[dict]) -> None:
        """The menu submenu, rebuilt only when the names change.

        The labels carry the live count, so the menu answers "is core already
        up" without opening anything.
        """
        labels = [(p["name"], p.get("up", 0), p.get("total", 0)) for p in profiles]
        if labels == getattr(self, "_profile_labels", None):
            return
        self._profile_labels = labels
        self._profiles_menu.remove_all()
        if not labels:
            # An empty submenu looks broken. Say why it is empty instead — and
            # still offer the way to make one.
            item = Gio.MenuItem.new("No saved profiles", None)
            item.set_action_and_target_value("win.noop", None)
            self._profiles_menu.append_item(item)
            self._profiles_menu.append_section(None, self._profiles_menu_end)
            return
        for name, up, total in labels:
            item = Gio.MenuItem.new(f"@{name}  —  {up}/{total} up", None)
            item.set_action_and_target_value("win.profile", GLib.Variant.new_string(name))
            self._profiles_menu.append_item(item)
        self._profiles_menu.append_section(None, self._profiles_menu_end)

    def _render_profiles(self, profiles: list[dict]) -> None:
        """One row per profile: what it covers, and what it is doing."""
        for row in self._profile_rows:
            self._profiles_group.remove(row)
        self._profile_rows.clear()
        # Hidden in zen, which keeps only what needs you — a saved set that is
        # already running does not.
        self._profiles_group.set_visible(bool(profiles) and not self._zen)
        if not profiles:
            return
        for index, profile in enumerate(profiles):
            row = self._profile_row(index, profile)
            self._profiles_group.add(row)
            # Kept, because the next frame has to remove exactly these — an
            # AdwPreferencesGroup hands back its own scaffolding otherwise.
            self._profile_rows.append(row)

    def _profile_row(self, index: int, profile: dict) -> Adw.ActionRow:
        name = profile["name"]
        up, total = profile.get("up", 0), profile.get("total", 0)
        missing = profile.get("missing") or []

        bits = [f"{up}/{total} up" if total else "resolves to nothing"]
        starting = profile.get("starting") or 0
        if starting:
            bits.append(f"{starting} starting")
        rss = profile.get("rss") or 0
        if rss:
            bits.append(human_bytes(rss))
        # What it COVERS, not the words it was saved as: "sales" is not an
        # answer to "what will this start".
        comps = profile.get("components") or []
        if comps:
            bits.append(", ".join(comps[:4]) + ("…" if len(comps) > 4 else ""))

        row = Adw.ActionRow(title=f"@{name}", use_markup=False,
                            subtitle=" · ".join(bits))
        if index < 9:
            row.set_tooltip_text(f"Alt+{index + 1}")

        if missing:
            # A profile referring to an app that no longer exists cannot start
            # at all — `pitcrew start @name` dies on the target. Better to say
            # so on the row than to let the button fail.
            warn = Gtk.Image(icon_name="dialog-warning-symbolic",
                             valign=Gtk.Align.CENTER)
            warn.set_tooltip_text(f"{', '.join(missing)} no longer exists — "
                                  "this profile will not start")
            row.add_prefix(warn)
            row.set_subtitle(" · ".join([*bits, f"⚠ {', '.join(missing)} missing"]))

        box = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
        start = Gtk.Button(icon_name="media-playback-start-symbolic",
                           tooltip_text=f"Start @{name}")
        start.add_css_class("flat")
        start.set_sensitive(not missing and total > 0)
        start.connect("clicked", lambda _b, n=name: self._start_profile(n))
        box.append(start)
        if up:
            stop = Gtk.Button(icon_name="media-playback-stop-symbolic",
                              tooltip_text=f"Stop the {up} component(s) @{name} has running")
            stop.add_css_class("flat")
            stop.connect("clicked", lambda _b, n=name: self._stop_profile(n))
            box.append(stop)
        row.add_suffix(box)
        return row

    def _start_profile(self, name: str) -> None:
        self._run_action("start", f"@{name}")

    def _stop_profile(self, name: str) -> None:
        self._run_action("stop", f"@{name}")

    def _profile_at(self, index: int) -> None:
        """Alt+N — the fastest path there is to a saved set."""
        profiles = getattr(self, "_last_profiles", [])
        if index >= len(profiles):
            self._toast(f"no profile {index + 1}")
            return
        self._start_profile(profiles[index]["name"])

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

    def _open_log_window(self, name: str) -> None:
        """This component's log, in a window of its own, live from now on."""
        existing = self._log_windows.get(name)
        if existing is not None:
            existing.present()
            return
        window = LogWindow(self.get_application(), self._project or "pitcrew",
                           name, self._log_window_closed, self._toast)
        self._log_windows[name] = window
        # The frame it missed. Without this the window sits empty until the
        # next sample, which at a 3-second interval reads as broken.
        if self._last_components:
            window.feed(self._last_log_dir, self._last_components, self._last_pattern)
        window.present()

    def _log_window_closed(self, window: LogWindow) -> None:
        # By identity, not by the name it was opened with: the picker inside it
        # may have been pointed somewhere else since.
        for name, open_window in list(self._log_windows.items()):
            if open_window is window:
                del self._log_windows[name]

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
                       getattr(self, "_last_profiles", []),
                       lambda: getattr(self, "_last_profiles", []),
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

        appearance = Adw.PreferencesGroup(
            title="Appearance",
            description="The palette pitcrew draws with, shared with the terminal "
                        "dashboard. Light and dark still follow your desktop.")
        appearance.add(self._theme_row())
        page.add(appearance)

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

    def _theme_row(self) -> Adw.ComboRow:
        names = theme.available() or ["default"]
        current = theme.active_name()
        # A theme named by $PITCREW_THEME need not exist on disk, and a saved
        # preference can outlive the file it names. Either way the row has to
        # be able to show what is actually in force.
        if current not in names:
            names.insert(0, current)
        row = Adw.ComboRow(title="Theme", model=Gtk.StringList.new(names))
        row.set_selected(names.index(current))
        if os.environ.get("PITCREW_THEME", "").strip():
            # Saying nothing here means a combo that visibly does not take.
            row.set_subtitle("$PITCREW_THEME is set for this run and wins")
        row.connect("notify::selected",
                    lambda r, _p: self._pick_theme(names[r.get_selected()]))
        return row

    def _pick_theme(self, name: str) -> None:
        if name == self._theme_name:
            return
        if not theme.save(name):
            # Still applied: a preference that could not be written is still a
            # preference you asked for, and this session should honour it.
            self._toast(f"Could not write {theme.theme_file()} — this session only")
        self._apply_theme(name)

    # ── theme ───────────────────────────────────────────────────────────────
    def _apply_theme(self, name: str | None = None, repaint: bool = True) -> None:
        """Repaint from the pitcrew palette — the one `pitcrew theme` sets.

        Everything the app DRAWS comes from here: meters, graph series, state
        dots, the verdict tint, the ANSI palette the log view renders with. The
        chrome around them is still Adwaita's, light/dark included, which is
        why the palette is adapted to that decision rather than overriding it.
        """
        dark = Adw.StyleManager.get_default().get_dark()
        self._theme_name = name or theme.active_name()
        theme.apply(self._theme_name, dark)
        install_css(dark=dark)
        if repaint:
            self._logs.refresh_palette()
            # The Projects list is built from its own `pitcrew projects --json`
            # and not from the frame, so replaying the frame does not reach it —
            # its state dots kept the palette they were built with until you
            # switched project. Rare enough that the extra call costs nothing.
            self._refresh_projects()
            # The same idiom zen uses: the frame is already in hand, and every
            # renderer reads the palettes fresh, so replaying it is a repaint.
            self._layout_key = None
            if self._last_state is not None:
                self._on_state(self._last_state)

    def _watch_theme_file(self) -> None:
        """`pitcrew theme <name>` in a terminal should reach an open window.

        Two front ends, one preference file: the app writes it from Preferences
        and the CLI writes it from `pitcrew theme`, and whichever wrote it last
        is what both of them should be showing.
        """
        try:
            self._theme_monitor = Gio.File.new_for_path(
                str(theme.theme_file())).monitor_file(Gio.FileMonitorFlags.NONE, None)
        except GLib.Error:
            return          # no inotify, or a filesystem that cannot watch: not fatal
        # Held on the window, not left to the local: a dropped GFileMonitor is
        # collected and simply stops reporting, with nothing to say it did.
        self._theme_monitor.connect("changed", self._on_theme_file_changed)

    def _on_theme_file_changed(self, *_args) -> None:
        # One save fires created + changed + changes-done-hint, and repainting
        # the whole window three times for one keystroke is visible.
        if theme.active_name() != self._theme_name:
            self._apply_theme()

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
        # A detached log belongs to the project it was opened from, and its
        # component may not even exist in the next one.
        for window in list(self._log_windows.values()):
            if window.project != (self._project or "pitcrew"):
                window.close()
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
        self._remember_project(name)
        self._restart_stream()

    def _remember_project(self, name: str) -> None:
        """Make the switch outlive the window.

        The app opens on `~/.config/pitcrew/current` — the same selection
        `pitcrew` with no `-p` uses, and the one this window's Projects page
        badges as "current". Switching only ever changed it in memory, so
        closing the window threw the choice away and the next launch reopened
        whatever the terminal had last run `pitcrew use` on.

        Written by the CLI rather than from here: the registry is the CLI's,
        `use` is what owns that file (it validates the name and, on `forget`,
        clears it), and re-implementing it in Python would be a second writer
        to disagree with the first. Async, so the switch itself stays instant —
        the stream is already restarting while this runs.

        The projects list is refreshed when it lands, not before: the "current"
        badge comes from `pitcrew projects --json`, so asking any earlier
        renders the badge on the row we just moved it off.
        """
        def done(ok: bool, output: str) -> None:
            if not ok:
                # A home we cannot write is not a reason to stop watching the
                # project — it is a reason to say it will not be remembered.
                self._toast(output.splitlines()[-1] if output.strip()
                            else f"could not save {name} as the current project")
            self._refresh_projects()

        self._runner.run(["use", name], done)

    def _fail(self, message: str) -> None:
        # pitcrew colours its own errors, so raw from the pipe the failure this
        # banner exists to explain arrives as SGR bytes across the top of the
        # window. Every banner message comes through here, so strip them here.
        #
        # NOT markup-escaped, unlike every other title in this file: AdwBanner
        # is the one that does not parse markup (use-markup defaults off), and
        # escaping turned `pitcrew init <dir>` into a literal `&lt;dir&gt;`.
        self._banner.set_title(ansi.plain(message))
        self._banner.set_revealed(True)
        # Before the first frame the banner is a strip across an empty window,
        # which is the right weight for "the stream hiccuped" and the wrong one
        # for "you have not set anything up".
        self._update_welcome(message)

    # ── rendering ───────────────────────────────────────────────────────────
    def _on_state(self, state: dict) -> None:
        self._banner.set_revealed(False)
        if not self._have_frame:
            # First frame: there is something to look at now.
            self._body.set_visible_child_name("live")
        self._have_frame = True
        self._last_state = state
        components = state.get("components", [])
        self._last_components = components
        # The stream's own clock, not the GUI's: uptime is measured against the
        # frame that reported it, and the two machines could disagree.
        self._last_at = state.get("at") or 0
        self._last_log_dir = state.get("logDir")
        # Set here rather than in _update_machine_summary, which runs after the
        # graphs: the share ring draws the project against the machine, and a
        # total that arrives a frame late is a ring that is wrong on the first.
        self._machine_total = (state.get("machine") or {}).get("memTotal") or 0
        colors = {c["name"]: SERIES_COLORS[i % len(SERIES_COLORS)]
                  for i, c in enumerate(components)}
        self._colors = colors
        history = self._settings["history"]

        for comp in components:
            name = comp["name"]
            series = self._series.get(name)
            if series is None:
                series = self._series[name] = Series(name, colors[name], history)
            elif series.color != colors[name]:
                # The palette changed under it, or the component list reordered
                # and the slot it draws from is now someone else's. Either way
                # the legend dot beside it has already moved on.
                series.recolor(colors[name])
            series.push(comp.get("cpu"), comp.get("rss"))

        self._last_pattern = state.get("errorPattern")
        self._logs.update_sources(state.get("logDir"), components, self._last_pattern)
        # Every detached window gets the same frame. A log pulled into its own
        # window has to keep moving, or detaching it is how you stop watching.
        for window in self._log_windows.values():
            window.feed(state.get("logDir"), components, self._last_pattern)
        self._shells = sorted(state.get("shells") or [])
        # From the stream, not from the directory: a profile holds TARGET
        # WORDS, and only pitcrew can say what "sales" covers today. Reading
        # the files here meant the GUI could show the words back and nothing
        # else — not how many components, not how many were up.
        self._last_profiles = state.get("profiles") or []
        self._refresh_profiles(self._last_profiles)
        self._crashes.check(components)
        self._render_components(components, colors)
        self._render_deps(state.get("deps", []))
        self._render_graphs(components, history)

        self._render_profiles(self._last_profiles)
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
        everything = components
        needle = self._comp_filter.get_text().strip().lower()
        if needle:
            components = [c for c in components
                          if needle in c["name"].lower() or needle in (c.get("app") or "").lower()]
        if self._settings["stopped"] == "hide":
            components = [c for c in components
                          if c.get("state") in ("up", "starting", "external", "crashed")]
        if self._zen:
            kept = [c for c in components if self._zen_wants(c)]
            self._update_zen_pill(len(components) - len(kept))
            components = kept

        buckets: dict[tuple[str, str], list[dict]] = {}
        for comp in components:
            buckets.setdefault(group_of(comp, mode), []).append(comp)
        ordered = sorted(buckets.items())
        if self._zen:
            # ONE flat list, no headings. Grouped, zen showed three headings
            # over four rows — a heading for a group of one is the same noise
            # as a column header over a single row, which is exactly what the
            # terminal's zen drops. The rows still say which app they belong
            # to: that is what the `be-`/`fe-` prefix is for.
            # Worst first, stably, so the grouping preference still decides
            # the order inside each band rather than being overridden by it.
            flat = sorted(components, key=state_rank)
            ordered = [(("", ""), flat)] if flat else []

        # The heading counts describe the GROUP, never the filtered slice of it.
        # "orders 0/1 up" under a filter that hid the healthy half of orders is
        # not a summary, it is a wrong number stated confidently.
        whole: dict[str, list[dict]] = {}
        for comp in everything:
            whole.setdefault(group_of(comp, mode)[1], []).append(comp)
        self._show_empty_state(len(components), total, needle)

        # Rebuild only when the shape changed — a new project, a settings change,
        # or a component appearing. Otherwise every frame would throw away and
        # recreate every widget, losing scroll position and focus twice a second.
        # Which buttons a heading gets depends on whether ANY and whether ALL
        # of the whole group is running, so those two bits are part of the
        # shape — otherwise a component going up while zen hid it would never
        # re-add that group's Stop button. Two bits, not the states themselves:
        # a rebuild costs scroll position and focus, and a group crosses these
        # boundaries a handful of times a day, not twice a second.
        def _buttons_for(heading: str) -> tuple[bool, bool]:
            members = whole.get(heading) or ()
            live = [c for c in members if c.get("state") in ("up", "starting", "external")]
            return bool(live), len(live) == len(members)

        layout_key = (mode, tuple((heading, tuple(c["name"] for c in comps),
                                   _buttons_for(heading))
                                  for (_sort, heading), comps in ordered))
        if layout_key != self._layout_key:
            self._rebuild_components(ordered, colors, whole)
            self._layout_key = layout_key

        now = self._last_at
        auto = self._settings["collapse"] == "auto"
        for (_sort, heading), comps in ordered:
            for comp in comps:
                self._rows[comp["name"]].update(comp, now)
            # Never in zen. Auto-collapse asks a DIFFERENT question — "is
            # anything in this group up?" — and for a list of stopped services
            # it answers no, which is exactly the list zen just built for you.
            # Zen also drops the headings, so there is no expander left to undo
            # the fold with: the page went blank, with 2/12 up in the header and
            # no way back. A mode you cannot see out of is a trap, not a filter.
            if self._zen:
                self._collapsed[heading] = False
            elif heading not in self._pinned:
                self._collapsed[heading] = auto and group_is_idle(comps)
            self._apply_collapse(heading)
            group = self._group_widgets.get(heading)
            if group is not None and heading:
                group.set_description(self._group_summary(whole.get(heading, comps),
                                                          hidden=len(whole.get(heading, comps)) - len(comps)))

    def _rebuild_components(self, ordered, colors: dict[str, str],
                            whole: dict[str, list[dict]] | None = None) -> None:
        for group in self._groups:
            self._comp_page.remove(group)
        self._groups.clear()
        # Out of the size group as well as out of the page: a size group holds
        # its widgets, so rows left in it are rows that never go away, and a
        # list rebuilt every time the shape of the stack changes would keep
        # every row it has ever drawn — sized against each other forever.
        for row in self._rows.values():
            self._action_sizes.remove_widget(row.action_slot)
        self._rows.clear()
        self._group_widgets.clear()
        self._group_toggles = {}
        self._group_rows: dict[str, list] = {}

        # Lift the dependencies group out once, then put it back last, so it
        # stays pinned below the components however many groups there are.
        # AdwPreferencesPage only appends, so ordering means re-adding.
        # Deps FIRST. A dead postgres is the likeliest reason six services are
        # failing, and it was the last thing on the page, under every app.
        self._comp_page.remove(self._dep_group)
        self._comp_page.append(self._dep_group)
        for (_sort, heading), comps in ordered:
            group = Adw.PreferencesGroup(title=plain(heading))
            if not heading:
                # The zen list. No title, so no header suffix either: the
                # buttons hang off a heading, and there is no heading.
                for comp in comps:
                    row = ComponentRow(comp["name"], colors[comp["name"]],
                                       self._run_action, self._show_logs_for,
                                       self._open_log_window, self._action_sizes)
                    row.set_activatable(True)
                    row.set_compact(self._compact)
                    row.connect("activated", lambda _r, n=comp["name"]: self._show_detail(n))
                    group.add(row)
                    self._rows[comp["name"]] = row
                    self._group_rows.setdefault(heading, []).append(row)
                self._comp_page.append(group)
                self._groups.append(group)
                self._group_widgets[heading] = group
                continue
            # Starting "sales" means both its roles. Doing that one row at a
            # time is the commonest thing anyone does here, so it belongs on
            # the heading rather than in a menu.
            # The WHOLE group, not the rows a filter left behind: a button
            # labelled "Stop all" under a heading called `orders` has to stop
            # orders. Under zen the healthy half of the group is hidden, and
            # "all" meaning "the two you can see" is how you end up with a
            # service you thought you stopped still holding its port.
            group.set_header_suffix(
                self._group_actions(heading, (whole or {}).get(heading, comps)))
            for comp in comps:
                row = ComponentRow(comp["name"], colors[comp["name"]], self._run_action,
                                   self._show_logs_for, self._open_log_window,
                                   self._action_sizes)
                row.set_activatable(True)
                row.set_compact(self._compact)
                row.connect("activated", lambda _r, n=comp["name"]: self._show_detail(n))
                group.add(row)
                self._rows[comp["name"]] = row
                self._group_rows.setdefault(heading, []).append(row)
            self._comp_page.append(group)
            self._groups.append(group)
            self._group_widgets[heading] = group

    def _show_empty_state(self, shown: int, total: int, needle: str = "") -> None:
        if shown:
            self._empty_group.set_visible(False)
            return
        if not self._have_frame:
            self._empty_label.set_text("Waiting for the first sample from pitcrew…")
        elif needle:
            self._empty_label.set_text(f"Nothing matches “{needle}”.")
        elif self._zen and total:
            # Not "the list is broken" — the answer you turned zen on to get.
            self._empty_label.set_text("Nothing needs you.")
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
    def _group_summary(comps: list[dict], hidden: int = 0) -> str:
        up = sum(1 for c in comps if c.get("state") == "up")
        rss = sum(c.get("rss") or 0 for c in comps)
        capped = sum(c.get("limit") or 0 for c in comps)
        parts = [f"{up}/{len(comps)} up"]
        if rss:
            parts.append(human_bytes(rss))
        if capped:
            parts.append(f"capped at {human_bytes(capped)}")
        # Says the rows below are not all of them, so the count above reads as
        # the group's rather than as a contradiction of what you can see.
        if hidden > 0:
            parts.append(f"{hidden} not shown")
        return "  ·  ".join(parts)

    def _render_deps(self, deps: list[dict]) -> None:
        # A running postgres is not news. A stopped one explains everything
        # else on the screen, so in zen that is the only kind worth a row.
        if self._zen:
            deps = [d for d in deps if d.get("state") != "up"]
            for name, (row, _dot, _badge) in self._dep_rows.items():
                row.set_visible(any(d["name"] == name for d in deps))
        elif self._dep_rows:
            for row, _dot, _badge in self._dep_rows.values():
                row.set_visible(True)
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
        # In zen the deps are the top of the ONE list, not a section above it —
        # same as the terminal, where a dead dependency is a row beside the
        # services it took out rather than a rule of its own.
        self._dep_group.set_title("" if self._zen else "Dependencies")
        self._dep_group.set_visible(bool(self._dep_rows)
                                   and (not self._zen or bool(deps)))

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
        colour = {s.name: s.color for s in plotted}
        rows, total = share_slices((s.name,
                                    by_name.get(s.name, {}).get("rss") or 0,
                                    by_name.get(s.name, {}).get("limit") or 0)
                                   for s in plotted)
        self._share.set_slices(rows, total, colour, self._machine_total)

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
        self._apply_scale()

    def _apply_scale(self) -> None:
        machine = self._scale_toggle.get_active_name() == "machine"
        self._rss_graph.set_ceiling(self._machine_total if machine else None)

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
