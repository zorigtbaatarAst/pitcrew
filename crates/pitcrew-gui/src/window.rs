//! The main window: a view stack, a header, and the pump that feeds them.
//!
//! Layout constraints inherited from the Python version, each of which cost a
//! bug before it was a rule:
//!
//! * **libadwaita 1.5 is the floor** — what Ubuntu 24.04 LTS ships. A widget
//!   from a newer version does not raise, GTK *aborts the process*.
//! * **Nothing with columns or figures inside an `AdwPreferencesPage`.** That
//!   widget carries a ~600px clamp which cannot be widened, and it is what left
//!   half of every window empty.
//! * **Colour means one thing** — see `widgets::RAMP`.

use adw::prelude::*;
use gtk::glib;
use pitcrew_model as pm;

use crate::logview::LogView;
use crate::runner::{self, Event, Stream};
use crate::views::{Action, Components, Frame, Overview, Projects, Resources};

pub struct Ui {
    pub window: adw::ApplicationWindow,
    stack: adw::ViewStack,
    overview: Overview,
    components: Components,
    resources: Resources,
    projects: Projects,
    logs: std::rc::Rc<LogView>,
    verdict: gtk::Label,
    verdict_icon: gtk::Image,
    summary: gtk::Label,
    toasts: adw::ToastOverlay,
    banner: adw::Banner,
    project: Option<String>,
    log_dir: std::cell::RefCell<String>,
}

pub fn build(app: &adw::Application, project: Option<String>) -> std::rc::Rc<Ui> {
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .default_width(1000)
        .default_height(720)
        .title("pitcrew")
        .build();

    let overview = Overview::new();
    let components = Components::new();
    let resources = Resources::new();
    let projects = Projects::new();
    let logs = LogView::new();

    let stack = adw::ViewStack::new();
    // Overview leads because it answers the question you opened the window to
    // ask. Components is a list, and a list is evidence, not an answer.
    stack.add_titled_with_icon(
        &padded(overview.widget()),
        Some("overview"),
        "Overview",
        "dialog-information-symbolic",
    );
    stack.add_titled_with_icon(
        &padded(components.widget()),
        Some("components"),
        "Components",
        "view-list-symbolic",
    );
    stack.add_titled_with_icon(
        &padded(resources.widget()),
        Some("resources"),
        "Resources",
        "power-profile-performance-symbolic",
    );
    // Not padded or clamped: a log wants the whole width it can get.
    stack.add_titled_with_icon(
        logs.widget(),
        Some("logs"),
        "Logs",
        "text-x-generic-symbolic",
    );
    stack.add_titled_with_icon(
        &padded(projects.widget()),
        Some("projects"),
        "Projects",
        "folder-symbolic",
    );

    let header = adw::HeaderBar::new();
    let switcher = adw::ViewSwitcher::builder()
        .stack(&stack)
        .policy(adw::ViewSwitcherPolicy::Wide)
        .build();
    header.set_title_widget(Some(&switcher));

    let verdict_icon = gtk::Image::from_icon_name("content-loading-symbolic");
    let verdict = gtk::Label::new(Some("connecting…"));
    verdict.set_ellipsize(gtk::pango::EllipsizeMode::End);
    verdict.set_max_width_chars(48);
    let verdict_box = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    verdict_box.append(&verdict_icon);
    verdict_box.append(&verdict);
    header.pack_start(&verdict_box);

    let summary = gtk::Label::new(None);
    summary.add_css_class("dim-label");
    summary.add_css_class("numeric");
    header.pack_end(&summary);

    // A banner, not a toast, for a stream that has stopped: a toast goes away
    // and this condition does not.
    let banner = adw::Banner::builder().revealed(false).build();

    let toasts = adw::ToastOverlay::new();
    toasts.set_child(Some(&stack));

    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    root.append(&header);
    root.append(&banner);
    root.append(&toasts);
    window.set_content(Some(&root));

    // The switcher is wide-only; below that it belongs at the bottom, where a
    // thumb can reach it.
    let bottom = adw::ViewSwitcherBar::builder().stack(&stack).build();
    root.append(&bottom);
    let breakpoint = adw::Breakpoint::new(adw::BreakpointCondition::new_length(
        adw::BreakpointConditionLengthType::MaxWidth,
        620.0,
        adw::LengthUnit::Px,
    ));
    breakpoint.add_setter(&bottom, "reveal", Some(&true.to_value()));
    breakpoint.add_setter(&switcher, "visible", Some(&false.to_value()));
    window.add_breakpoint(breakpoint);

    let ui = std::rc::Rc::new(Ui {
        window,
        stack,
        overview,
        components,
        resources,
        projects,
        logs,
        verdict,
        verdict_icon,
        summary,
        toasts,
        banner,
        project,
        log_dir: std::cell::RefCell::new(String::new()),
    });

    connect(ui.clone());
    ui
}

/// Padded and clamped. A Box in an `AdwClamp`, never an `AdwPreferencesPage` —
/// see the note at the top of this file.
fn padded(child: &impl IsA<gtk::Widget>) -> gtk::Widget {
    let inner = gtk::Box::new(gtk::Orientation::Vertical, 0);
    inner.set_margin_top(18);
    inner.set_margin_bottom(18);
    inner.set_margin_start(12);
    inner.set_margin_end(12);
    inner.append(child);
    let clamp = adw::Clamp::builder()
        .maximum_size(1100)
        .tightening_threshold(760)
        .child(&inner)
        .build();
    gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&clamp)
        .build()
        .upcast()
}

fn connect(ui: std::rc::Rc<Ui>) {
    // Read once: the registry changes when somebody runs `pitcrew init`, not
    // once a second.
    if let Ok(text) = runner::run(&["projects"]) {
        ui.projects.load(&text);
    }

    let stream = match Stream::start(ui.project.as_deref(), 1.0) {
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
    fn update(self: &std::rc::Rc<Self>, snap: &pm::Snapshot) {
        self.window
            .set_title(Some(&format!("{} — pitcrew", snap.project)));
        *self.log_dir.borrow_mut() = snap.log_dir.clone();

        // The verdict travels WITH the facts, so nothing here re-derives it.
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

        let frame = Frame { snap };
        self.overview.update(&frame);
        self.resources.update(&frame);

        let ui = self.clone();
        let on_action: std::rc::Rc<dyn Fn(Action)> = std::rc::Rc::new(move |action| ui.act(action));
        self.components.update(&frame, &on_action);

        // Whatever the log view is following, keep following it.
        self.logs.poll(&self.log_dir.borrow());
    }

    /// A button was pressed.
    fn act(self: &std::rc::Rc<Self>, action: Action) {
        let (verb, comp) = match &action {
            Action::Start(c) => ("start", c),
            Action::Stop(c) => ("stop", c),
            Action::Restart(c) => ("restart", c),
            Action::ShowLog(c) => {
                self.logs.follow(c, &self.log_dir.borrow());
                self.stack.set_visible_child_name("logs");
                return;
            }
        };
        // Rendering the CLI's answer, not computing one.
        let mut args: Vec<&str> = Vec::new();
        if let Some(p) = &self.project {
            args.push("-p");
            args.push(p);
        }
        args.push(verb);
        args.push(comp);
        match runner::run(&args) {
            // The next frame will show the result; this only reports what the
            // command itself said, which is where a refusal lives.
            Ok(out) => {
                let line = out.lines().next().unwrap_or("").trim();
                if !line.is_empty() {
                    self.notice(line);
                }
            }
            Err(e) => self.notice(&e),
        }
    }

    fn notice(&self, text: &str) {
        self.toasts.add_toast(adw::Toast::new(text));
    }

    /// A condition that will not go away on its own gets a banner, not a toast.
    fn fail(&self, why: &str) {
        self.verdict_icon
            .set_icon_name(Some("dialog-error-symbolic"));
        self.verdict.set_text("disconnected");
        self.banner.set_title(why);
        self.banner.set_revealed(true);
    }
}
