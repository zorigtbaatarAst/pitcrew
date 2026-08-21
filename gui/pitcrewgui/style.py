"""The handful of things libadwaita does not already style for us.

Deliberately small. Everything that can be an Adwaita style class (`.title-2`,
`.dim-label`, `.numeric`, `.destructive-action`) IS one, so the app follows the
user's theme and accent colour rather than inventing a look that will be wrong
on the next GNOME release. What is here is the two things Adwaita has no
opinion about: a verdict banner tinted by severity, and the coloured rail that
makes a list of findings scannable without a card around each one.

The colours are named Adwaita ones (`@error_color` and friends), so they track
light/dark and any accent the user has chosen.
"""

from __future__ import annotations

from gi.repository import Gdk, Gtk

CSS = b"""
/* The verdict. A tint, not a card: it has to read as the page's answer rather
   than as the first of five equal items. */
.verdict {
  border-radius: 14px;
  padding: 16px 20px;
  background-color: alpha(currentColor, 0.05);
}
.verdict-ok   { background-color: alpha(@success_color, 0.10); }
.verdict-warn { background-color: alpha(@warning_color, 0.13); }
.verdict-crit { background-color: alpha(@error_color,   0.13); }

/* A finding's severity, as a rail down its left edge. Cheaper than a coloured
   icon in every row and far easier to scan a column of. */
row.finding { border-left: 3px solid transparent; }
row.finding-crit { border-left-color: @error_color; }
row.finding-warn { border-left-color: @warning_color; }
row.finding-info { border-left-color: alpha(@accent_color, 0.55); }

/* Figures in a column must line up, and proportional digits do not. Adwaita
   ships `.numeric` for this; this only widens where it applies. */
.numeric { font-feature-settings: "tnum"; font-variant-numeric: tabular-nums; }

/* The component table's header. Not a real GtkColumnView (these are still
   AdwActionRows), so the header is a label row that has to match their
   padding exactly. */
.table-head {
  font-size: 0.82em;
  font-weight: bold;
  opacity: 0.55;
  padding: 2px 14px 6px 14px;
}
"""


def install(display: Gdk.Display | None = None) -> None:
    """Add the sheet once, at a priority the user's own CSS can still beat."""
    display = display or Gdk.Display.get_default()
    if display is None:
        return
    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_display(
        display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
