//! The small amount of CSS Adwaita has no opinion about.
//!
//! Everything else should be an Adwaita style class, so the app follows the
//! user's theme and accent colour rather than inventing its own. A rule here
//! is a rule that has to be maintained against two desktop themes forever.

const CSS: &str = "
/* Figures line up in a column only if the digits are the same width. */
.numeric { font-feature-settings: 'tnum'; font-variant-numeric: tabular-nums; }

/* Log text is captured verbatim, escapes included, so it needs a font that
   does not reflow it. */
.logview { font-family: monospace; font-size: 0.92em; }
";

pub fn load() {
    let provider = gtk::CssProvider::new();
    provider.load_from_data(CSS);
    if let Some(display) = gtk::gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}
