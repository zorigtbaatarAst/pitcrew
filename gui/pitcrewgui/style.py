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

/* The zen indicator: one green oval, and in zen the only coloured thing in the
   header. Adwaita's own success pair rather than a hex value, so the fill and
   the text on it are legible together in light and dark. A green picked for
   one scheme is unreadable in the other, and this is the single control that
   says how to leave the mode.

   Success, not accent: accent follows whatever colour the user chose, and on a
   warm one this read as a warning badge. Zen being on is not a warning. */
.zen-pill {
  background: @success_bg_color;
  color: @success_fg_color;
  border-radius: 999px;
  min-height: 24px;
  font-weight: bold;
}
.zen-pill:hover  { background: shade(@success_bg_color, 1.12); }
.zen-pill:active { background: shade(@success_bg_color, 0.92); }

/* The close mark is an affordance, not an action of its own: the whole chip is
   the button. Invisible until the pointer arrives, so at rest the oval is a
   word and nothing else -- but its WIDTH is reserved either way, because a
   chip that grows under the pointer is a chip you can miss by hovering it. */
.zen-pill-close { opacity: 0; }
.zen-pill:hover .zen-pill-close { opacity: 0.85; }
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
