//! The widgets GTK does not ship.
//!
//! **Colour means one thing.** Everything here draws from [`RAMP`], and the
//! status badges draw from the same one — the last time a meter and a badge had
//! separate palettes, a 32%-full meter and a warning badge were the same hue.

use adw::prelude::*;
use gtk::cairo;
use pitcrew_core::format::{human_bytes, human_duration};
use pitcrew_model as pm;

/// The one ramp. Green through amber to red, by how full something is.
///
/// Not a gradient: four stops, because a meter that shades continuously reads
/// as "somewhat concerning" at every value and as nothing in particular.
pub const RAMP: [(f64, (f64, f64, f64)); 4] = [
    (0.00, (0.40, 0.78, 0.44)), // fine
    (0.70, (0.60, 0.76, 0.36)), // filling
    (0.85, (0.90, 0.75, 0.28)), // worth noticing
    (0.95, (0.88, 0.36, 0.40)), // out of room
];

/// The colour for a 0..1 fraction.
pub fn ramp(fraction: f64) -> (f64, f64, f64) {
    let f = fraction.clamp(0.0, 1.0);
    let mut chosen = RAMP[0].1;
    for (at, colour) in RAMP {
        if f >= at {
            chosen = colour;
        }
    }
    chosen
}

/// A horizontal meter with its own colour.
///
/// `Gtk::LevelBar` was the obvious choice and is the reason this exists: its
/// stock "high" offset paints orange, which is a second palette nobody asked
/// for and which collided with the warning badge.
pub struct Meter {
    area: gtk::DrawingArea,
    fraction: std::rc::Rc<std::cell::Cell<f64>>,
}

impl Meter {
    pub fn new() -> Meter {
        let area = gtk::DrawingArea::new();
        area.set_content_height(6);
        area.set_hexpand(true);
        let fraction = std::rc::Rc::new(std::cell::Cell::new(0.0f64));
        let f = fraction.clone();
        area.set_draw_func(move |_, cr: &cairo::Context, w, h| {
            let w = w as f64;
            let h = h as f64;
            let radius = h / 2.0;
            // The trough. Drawn rather than themed so the meter reads the same
            // on a light and a dark desktop.
            cr.set_source_rgba(0.5, 0.5, 0.5, 0.25);
            rounded(cr, 0.0, 0.0, w, h, radius);
            let _ = cr.fill();

            let value = f.get().clamp(0.0, 1.0);
            if value <= 0.0 {
                return;
            }
            // A floor, so a meter that is barely full is still visibly not
            // empty — "0.4%" and "nothing at all" are different states.
            let filled = (w * value).max(h);
            let (r, g, b) = ramp(value);
            cr.set_source_rgb(r, g, b);
            rounded(cr, 0.0, 0.0, filled, h, radius);
            let _ = cr.fill();
        });
        Meter { area, fraction }
    }

    pub fn widget(&self) -> &gtk::DrawingArea {
        &self.area
    }

    pub fn set(&self, fraction: f64) {
        self.fraction.set(fraction);
        self.area.queue_draw();
    }
}

impl Default for Meter {
    fn default() -> Self {
        Self::new()
    }
}

fn rounded(cr: &cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    let r = r.min(w / 2.0).min(h / 2.0);
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -std::f64::consts::FRAC_PI_2, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, std::f64::consts::FRAC_PI_2);
    cr.arc(
        x + r,
        y + h - r,
        r,
        std::f64::consts::FRAC_PI_2,
        std::f64::consts::PI,
    );
    cr.arc(
        x + r,
        y + r,
        r,
        std::f64::consts::PI,
        1.5 * std::f64::consts::PI,
    );
    cr.close_path();
}

/// The machine gauges: how much of this box is left.
///
/// The product's actual promise is "a RAM meter before your laptop falls over
/// running six JVMs", so this is the first thing on screen rather than a
/// footnote.
pub struct Gauges {
    root: gtk::Box,
    ram: Meter,
    ram_label: gtk::Label,
    cpu: Meter,
    cpu_label: gtk::Label,
    swap_row: gtk::Box,
    swap_label: gtk::Label,
}

impl Gauges {
    pub fn new() -> Gauges {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 10);
        let (ram, ram_label, ram_row) = labelled("RAM");
        let (cpu, cpu_label, cpu_row) = labelled("CPU");
        let (swap_meter, swap_label, swap_row) = labelled("SWAP");
        root.append(&ram_row);
        root.append(&cpu_row);
        root.append(&swap_row);
        // Swap is hidden until there is any: a row reading "0B" on every
        // machine with none is a row that teaches the eye to skip that area.
        swap_row.set_visible(false);
        let _ = swap_meter;
        Gauges {
            root,
            ram,
            ram_label,
            cpu,
            cpu_label,
            swap_row,
            swap_label,
        }
    }

    pub fn widget(&self) -> &gtk::Box {
        &self.root
    }

    pub fn update(&self, m: &pm::Machine) {
        let used = if m.mem_total > 0 {
            m.mem_used as f64 / m.mem_total as f64
        } else {
            0.0
        };
        self.ram.set(used);
        self.ram_label.set_text(&format!(
            "{} / {}",
            human_bytes(m.mem_used),
            human_bytes(m.mem_total)
        ));
        self.cpu.set(m.cpu_percent as f64 / 100.0);
        self.cpu_label.set_text(&format!("{}%", m.cpu_percent));

        // Swap in use means the machine has already started paging to cope,
        // which is worse news than a high percentage.
        self.swap_row.set_visible(m.swap_used > 0);
        if m.swap_used > 0 {
            self.swap_label.set_text(&format!(
                "{} / {}",
                human_bytes(m.swap_used),
                human_bytes(m.swap_total)
            ));
        }
    }
}

impl Default for Gauges {
    fn default() -> Self {
        Self::new()
    }
}

fn labelled(name: &str) -> (Meter, gtk::Label, gtk::Box) {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let title = gtk::Label::new(Some(name));
    title.set_width_chars(5);
    title.set_xalign(0.0);
    title.add_css_class("dim-label");
    let meter = Meter::new();
    let value = gtk::Label::new(None);
    value.set_width_chars(14);
    value.set_xalign(1.0);
    value.add_css_class("numeric");
    row.append(&title);
    row.append(meter.widget());
    row.append(&value);
    (meter, value, row)
}

/// A row whose title and subtitle are TEXT, not markup.
///
/// `AdwActionRow` renders both as Pango markup by default, and the strings here
/// come from a config and a process table: every real start command has `&&` in
/// it, and `pitcrew init <dir>` has angle brackets. Pango does not escape them,
/// it fails to parse — and a failed parse renders the line EMPTY, which reads
/// as a bug in pitcrew rather than in the text.
pub fn action_row() -> adw::ActionRow {
    let row = adw::ActionRow::new();
    row.set_use_markup(false);
    row
}

/// The same, for an expandable one.
pub fn expander_row() -> adw::ExpanderRow {
    let row = adw::ExpanderRow::new();
    row.set_use_markup(false);
    row
}

/// One component's row.
pub struct ComponentRow {
    row: adw::ActionRow,
    dot: gtk::Image,
    rss: gtk::Label,
    meter: Meter,
    name: String,
    start: gtk::Button,
    restart: gtk::Button,
    stop: gtk::Button,
    logs: gtk::Button,
}

impl ComponentRow {
    pub fn new(c: &pm::Component) -> ComponentRow {
        let row = action_row();
        row.set_title(&c.name);

        let dot = gtk::Image::from_icon_name("media-record-symbolic");
        row.add_prefix(&dot);

        let right = gtk::Box::new(gtk::Orientation::Vertical, 4);
        right.set_valign(gtk::Align::Center);
        right.set_width_request(160);
        let rss = gtk::Label::new(None);
        rss.set_xalign(1.0);
        rss.add_css_class("numeric");
        let meter = Meter::new();
        right.append(&rss);
        right.append(meter.widget());
        row.add_suffix(&right);

        // Icon buttons, flat, in a linked group: three labelled buttons per row
        // is a wall of text where the state is what anyone is reading.
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        actions.add_css_class("linked");
        actions.set_valign(gtk::Align::Center);
        actions.set_margin_start(12);
        let start = icon_button("media-playback-start-symbolic", "Start");
        let restart = icon_button("view-refresh-symbolic", "Restart");
        let stop = icon_button("media-playback-stop-symbolic", "Stop");
        let logs = icon_button("text-x-generic-symbolic", "Logs");
        actions.append(&start);
        actions.append(&restart);
        actions.append(&stop);
        actions.append(&logs);
        row.add_suffix(&actions);

        ComponentRow {
            row,
            dot,
            rss,
            meter,
            name: c.name.clone(),
            start,
            restart,
            stop,
            logs,
        }
    }

    /// Wire the buttons. Separate from construction so the row can be built
    /// without a handler in a test.
    pub fn attach_actions(&self, on: std::rc::Rc<dyn Fn(crate::views::Action)>) {
        for (button, make) in [
            (
                &self.start,
                Box::new(crate::views::Action::Start)
                    as Box<dyn Fn(String) -> crate::views::Action>,
            ),
            (&self.restart, Box::new(crate::views::Action::Restart)),
            (&self.stop, Box::new(crate::views::Action::Stop)),
            (&self.logs, Box::new(crate::views::Action::ShowLog)),
        ] {
            let name = self.name.clone();
            let on = on.clone();
            button.connect_clicked(move |_| on(make(name.clone())));
        }
    }

    pub fn widget(&self) -> &adw::ActionRow {
        &self.row
    }

    pub fn update(&self, c: &pm::Component, at: i64) {
        // A command with `&&` in it is not markup. Adw renders a subtitle as
        // Pango markup, and every real start command has an ampersand, so the
        // parse failed and the line rendered EMPTY.
        let mut subtitle = state_word(c.state).to_string();
        if let Some(port) = c.port {
            subtitle.push_str(&format!(" · :{port}"));
        }
        if let (Some(code), pm::State::Crashed) = (c.exit, c.state) {
            subtitle.push_str(&format!(" · exited {code}"));
        }
        if let Some(since) = c.since {
            if at >= since {
                subtitle.push_str(&format!(" · up {}", human_duration(at - since)));
            }
        }
        if c.errors > 0 {
            subtitle.push_str(&format!(" · {} errors", c.errors));
        }
        if !c.enabled {
            // Off keeps its row and says off. An excluded service that
            // VANISHED is one you spend an afternoon looking for.
            subtitle.push_str(" · off");
        }
        self.row.set_subtitle(&subtitle);

        for class in ["success", "warning", "error", "accent", "dim-label"] {
            self.dot.remove_css_class(class);
        }
        self.dot.add_css_class(state_class(c.state));

        self.rss
            .set_text(&c.rss.map(human_bytes).unwrap_or_default());
        // Against its own cap, which is what the colour is about: at the cap a
        // component is killed, not throttled.
        let fraction = match (c.rss, c.limit) {
            (Some(rss), Some(limit)) if limit > 0 => rss as f64 / limit as f64,
            _ => 0.0,
        };
        self.meter.set(fraction);

        // A stopped component cannot be stopped and a running one does not need
        // starting. Greying the wrong one out beats a button that does nothing
        // and says nothing about why.
        let running = c.state.is_running();
        self.start.set_sensitive(!running);
        // Restart is stop-then-start, so it needs something to stop. A crashed
        // component counts: its pidfile is still there and the port may not be.
        self.restart
            .set_sensitive(running || c.state == pm::State::Crashed);
        self.stop
            .set_sensitive(running || c.state == pm::State::Crashed);
        // There is no log to read for a component that has never run.
        self.logs.set_sensitive(true);
    }
}

fn icon_button(icon: &str, tooltip: &str) -> gtk::Button {
    let b = gtk::Button::from_icon_name(icon);
    b.set_tooltip_text(Some(tooltip));
    b.add_css_class("flat");
    b
}

pub fn state_word(s: pm::State) -> &'static str {
    match s {
        pm::State::Up => "up",
        pm::State::Starting => "starting",
        pm::State::Crashed => "crashed",
        pm::State::External => "external",
        pm::State::Down => "down",
        pm::State::NotA => "n/a",
    }
}

/// Drawn from the same ramp as the meters — see the note at the top.
pub fn state_class(s: pm::State) -> &'static str {
    match s {
        pm::State::Up => "success",
        pm::State::Starting => "warning",
        pm::State::Crashed => "error",
        pm::State::External => "accent",
        pm::State::Down | pm::State::NotA => "dim-label",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One ramp, and it has to actually move: a meter that is the same colour
    /// at 10% and at 99% is decoration.
    #[test]
    fn the_ramp_gets_worse_as_things_fill_up() {
        assert_eq!(ramp(0.0), RAMP[0].1);
        assert_eq!(ramp(0.5), RAMP[0].1);
        assert_eq!(ramp(0.75), RAMP[1].1);
        assert_eq!(ramp(0.90), RAMP[2].1);
        assert_eq!(ramp(0.99), RAMP[3].1);
        // Out of range is clamped, not wrapped: a component over its cap is as
        // red as it gets, not back to green.
        assert_eq!(ramp(1.5), RAMP[3].1);
        assert_eq!(ramp(-1.0), RAMP[0].1);
    }

    /// The status colours come from the same vocabulary as the meters. Two
    /// palettes is how a 32%-full meter and a warning badge became one hue.
    #[test]
    fn every_state_has_exactly_one_colour() {
        let states = [
            pm::State::Up,
            pm::State::Starting,
            pm::State::Crashed,
            pm::State::External,
            pm::State::Down,
            pm::State::NotA,
        ];
        for s in states {
            assert!(!state_class(s).is_empty());
            assert!(!state_word(s).is_empty());
        }
        assert_eq!(state_class(pm::State::Up), "success");
        assert_eq!(state_class(pm::State::Crashed), "error");
    }
}
