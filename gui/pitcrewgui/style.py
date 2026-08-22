"""The handful of things libadwaita does not already style for us.

Deliberately small. Everything that can be an Adwaita style class (`.title-2`,
`.dim-label`, `.numeric`, `.destructive-action`) IS one, so the app follows the
user's theme and accent colour rather than inventing a look that will be wrong
on the next GNOME release. What is here is the two things Adwaita has no
opinion about: a verdict banner tinted by severity, and the coloured rail that
makes a list of findings scannable without a card around each one.

Severity is the one place that does NOT defer to the desktop. `@error_color` is
whatever red the platform picked; the dot beside the banner, the bar in the
component row and the crashed service in the terminal dashboard are all pitcrew
red — and a banner that disagreed with the dot inside it about what "crit"
looks like is a banner that reads as a different kind of thing. So the tints
come from the same palette as everything else pitcrew draws, and the sheet is
rebuilt when the theme changes. Chrome that is genuinely the platform's — the
zen pill's success pair, which has to keep its own foreground legible — stays
Adwaita's.
"""

from __future__ import annotations

from gi.repository import Gdk, Gtk

from . import theme

# Structure only. Every colour in here is a name defined by _palette_css below,
# or an Adwaita one where the platform genuinely owns the decision.
RULES = """
/* The verdict. A tint, not a card: it has to read as the page's answer rather
   than as the first of five equal items. */
.verdict {
  border-radius: 14px;
  padding: 16px 20px;
  background-color: alpha(currentColor, 0.05);
}
.verdict-ok   { background-color: alpha(@pitcrew_ok,   0.10); }
.verdict-warn { background-color: alpha(@pitcrew_warn, 0.13); }
.verdict-crit { background-color: alpha(@pitcrew_crit, 0.13); }

/* A finding's severity, as a rail down its left edge. Cheaper than a coloured
   icon in every row and far easier to scan a column of. */
row.finding { border-left: 3px solid transparent; }
row.finding-crit { border-left-color: @pitcrew_crit; }
row.finding-warn { border-left-color: @pitcrew_warn; }
row.finding-info { border-left-color: alpha(@pitcrew_accent, 0.55); }

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

# The roles the sheet above names, and nothing else. One provider carries both
# the definitions and the rules that use them: GTK resolves a colour name
# against the provider chain, and a sheet that depends on a name some OTHER
# provider happened to define is a sheet that breaks when load order changes.
_ROLES = ("ok", "warn", "crit", "accent")

# One provider per display, kept so a reload replaces the sheet instead of
# stacking a second copy of every rule behind it.
_providers: dict[Gdk.Display, Gtk.CssProvider] = {}


def _palette_css(dark: bool) -> bytes:
    colors = theme.palette()
    defines = "".join(
        f"@define-color pitcrew_{role} {theme.legible(colors[role], dark)};\n"
        for role in _ROLES)
    return (defines + RULES).encode("utf-8")


def install(display: Gdk.Display | None = None, dark: bool = True) -> None:
    """Add the sheet, at a priority the user's own CSS can still beat.

    Idempotent: called again with a different `dark` (or after the theme file
    changed) it reloads the SAME provider, so the window repaints without
    stacking a second copy of every rule on the display.
    """
    display = display or Gdk.Display.get_default()
    if display is None:
        return
    provider = _providers.get(display)
    if provider is None:
        provider = _providers[display] = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_display(
            display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    provider.load_from_data(_palette_css(dark))
