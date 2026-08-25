//! The main window.
//!
//! Layout constraints inherited from the Python version, each of which cost a
//! bug before it was a rule:
//!
//! * **libadwaita 1.5 is the floor** — what Ubuntu 24.04 LTS ships. A widget
//!   from a newer version does not raise, GTK *aborts the process*, so reaching
//!   for something new costs the app the ability to start on the most common
//!   Linux desktop. `AdwToggleGroup` (1.7) did exactly that once.
//! * **Nothing with columns or figures goes inside an `AdwPreferencesPage`.**
//!   That widget carries its own ~600px clamp which cannot be widened, and it
//!   is what left half of every window empty.
//! * **Colour means one thing.** Resource meters and status badges draw from
//!   the same ramp. The last time they did not, a 32%-full meter and a warning
//!   badge were the same hue.

use adw::prelude::*;
use gtk::glib;
use pitcrew_model as pm;

use crate::runner::{Event, Stream};
use crate::widgets;

pub struct Ui {
    pub window: adw::ApplicationWindow,
    rows: gtk::ListBox,
    verdict: gtk::Label,
    verdict_icon: gtk::Image,
    summary: gtk::Label,
    gauges: widgets::Gauges,
    toasts: adw::ToastOverlay,
    /// Rebuilt only when the component set changes — replacing every row on
    /// every frame loses the selection and makes a list flicker at 1Hz.
    known: std::cell::RefCell<Vec<String>>,
    cells: std::cell::RefCell<Vec<widgets::ComponentRow>>,
}

pub fn build(app: &adw::Application, project: Option<String>) -> std::rc::Rc<Ui> {
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .default_width(980)
        .default_height(680)
        .title("pitcrew")
        .build();

    let header = adw::HeaderBar::new();
    let verdict_icon = gtk::Image::from_icon_name("emblem-ok-symbolic");
    let verdict = gtk::Label::new(Some("connecting…"));
    verdict.set_ellipsize(gtk::pango::EllipsizeMode::End);
    let verdict_box = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    verdict_box.append(&verdict_icon);
    verdict_box.append(&verdict);
    header.set_title_widget(Some(&verdict_box));

    let summary = gtk::Label::new(None);
    summary.add_css_class("dim-label");
    header.pack_end(&summary);

    let gauges = widgets::Gauges::new();

    let rows = gtk::ListBox::new();
    rows.set_selection_mode(gtk::SelectionMode::None);
    rows.add_css_class("boxed-list");

    // A Box in a Clamp, NOT an AdwPreferencesPage: this view has columns and
    // figures, and that widget's ~600px clamp cannot be widened.
    let content = gtk::Box::new(gtk::Orientation::Vertical, 18);
    content.set_margin_top(18);
    content.set_margin_bottom(18);
    content.set_margin_start(12);
    content.set_margin_end(12);
    content.append(gauges.widget());
    content.append(&rows);

    let clamp = adw::Clamp::builder()
        .maximum_size(1100)
        .tightening_threshold(700)
        .child(&content)
        .build();
    let scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&clamp)
        .build();

    let toasts = adw::ToastOverlay::new();
    toasts.set_child(Some(&scroller));

    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    root.append(&header);
    root.append(&toasts);
    window.set_content(Some(&root));

    let ui = std::rc::Rc::new(Ui {
        window,
        rows,
        verdict,
        verdict_icon,
        summary,
        gauges,
        toasts,
        known: std::cell::RefCell::new(Vec::new()),
        cells: std::cell::RefCell::new(Vec::new()),
    });

    connect(ui.clone(), project);
    ui
}

/// Start the stream and pump it into the window.
fn connect(ui: std::rc::Rc<Ui>, project: Option<String>) {
    let stream = match Stream::start(project.as_deref(), 1.0) {
        Ok(s) => s,
        Err(e) => {
            ui.fail(&format!("could not start pitcrew: {e}"));
            return;
        }
    };
    let events = stream.events.clone();
    glib::spawn_future_local(async move {
        // Held for as long as the pump runs: dropping it kills the CLI, which
        // is what should happen when the window closes.
        let _stream = stream;
        while let Ok(event) = events.recv().await {
            match event {
                Event::State(snap) => ui.update(&snap),
                Event::Notice(text) => ui.notice(&text),
                Event::Ended(why) => {
                    ui.fail(&why);
                    return;
                }
            }
        }
    });
}

impl Ui {
    fn update(&self, snap: &pm::Snapshot) {
        self.window
            .set_title(Some(&format!("{} — pitcrew", snap.project)));

        // The verdict travels WITH the facts. Working it out from the component
        // list here would be reimplementing the diagnostics layer, and it could
        // not know what a check added later means.
        let (icon, css) = match snap.health.verdict {
            pm::Verdict::Crit => ("dialog-error-symbolic", "error"),
            pm::Verdict::Warn => ("dialog-warning-symbolic", "warning"),
            pm::Verdict::Info => ("dialog-information-symbolic", "accent"),
            pm::Verdict::Ok => ("emblem-ok-symbolic", "success"),
        };
        self.verdict_icon.set_icon_name(Some(icon));
        for class in ["error", "warning", "accent", "success"] {
            self.verdict_icon.remove_css_class(class);
        }
        self.verdict_icon.add_css_class(css);
        self.verdict.set_text(if snap.health.headline.is_empty() {
            "all good"
        } else {
            &snap.health.headline
        });

        let s = &snap.summary;
        self.summary.set_text(&format!(
            "{} up · {} starting · {} crashed · {} down",
            s.up, s.starting, s.crashed, s.down
        ));
        self.gauges.update(&snap.machine);

        // Rebuild rows only when the SET changes. Replacing them every frame
        // loses the selection and makes the list flicker once a second.
        let names: Vec<String> = snap.components.iter().map(|c| c.name.clone()).collect();
        if *self.known.borrow() != names {
            while let Some(child) = self.rows.first_child() {
                self.rows.remove(&child);
            }
            let mut cells = Vec::new();
            for c in &snap.components {
                let row = widgets::ComponentRow::new(c);
                self.rows.append(row.widget());
                cells.push(row);
            }
            *self.cells.borrow_mut() = cells;
            *self.known.borrow_mut() = names;
        }
        for (row, c) in self.cells.borrow().iter().zip(&snap.components) {
            row.update(c, snap.at);
        }
    }

    fn notice(&self, text: &str) {
        self.toasts.add_toast(adw::Toast::new(text));
    }

    fn fail(&self, why: &str) {
        self.verdict_icon
            .set_icon_name(Some("dialog-error-symbolic"));
        self.verdict.set_text(why);
        self.notice(why);
    }
}
