"""Desktop notifications for the things you would otherwise find out late.

A dashboard you have to be looking at tells you nothing you would not have
learned by alt-tabbing to the terminal. The point of a desktop app is that it
can interrupt you — but only for the one event that deserves it: a component
that WAS up and now is not.
"""

from __future__ import annotations

from gi.repository import Gio, GLib


class CrashWatcher:
    """Fires once per up → crashed transition, never on a steady state."""

    def __init__(self, app: Gio.Application, on_show):
        self._app = app
        self._on_show = on_show
        self._previous: dict[str, str] = {}
        self.enabled = True

    def reset(self) -> None:
        """Forget history — on a project switch, every component is 'new'.

        Without this, switching to a project whose backend is already crashed
        would notify about something that broke before you were watching.
        """
        self._previous.clear()

    def check(self, components: list[dict]) -> None:
        for comp in components:
            name = comp["name"]
            state = comp.get("state") or "n/a"
            was = self._previous.get(name)
            self._previous[name] = state
            # `was` being None means this is the first frame for this component.
            # A crash already in progress when the window opened is not news.
            if not self.enabled or was is None or state != "crashed" or was == "crashed":
                continue
            self._notify(comp)

    def _notify(self, comp: dict) -> None:
        note = Gio.Notification.new(f"{comp['name']} crashed")
        detail = []
        if comp.get("exit") is not None:
            detail.append(f"exit {comp['exit']}")
        if comp.get("errors"):
            detail.append(f"{comp['errors']} errors in log")
        note.set_body(" · ".join(detail) or "it was up a moment ago")
        note.set_priority(Gio.NotificationPriority.HIGH)
        note.add_button("Show logs", f"app.showlogs::{comp['name']}")
        # The id is the component, so a service that flaps replaces its own
        # notification instead of stacking twelve of them.
        self._app.send_notification(f"crash-{comp['name']}", note)

    def install_action(self) -> None:
        action = Gio.SimpleAction.new("showlogs", GLib.VariantType.new("s"))
        action.connect("activate", lambda _a, target: self._on_show(target.get_string()))
        self._app.add_action(action)
