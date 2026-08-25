//! The five pages.
//!
//! **Overview leads** because it answers the question you opened the window to
//! ask. Components is a list, and a list is evidence, not an answer.

use adw::prelude::*;
use pitcrew_core::format::human_bytes;
use pitcrew_model as pm;

use crate::widgets::{action_row, expander_row, ComponentRow, Gauges};

/// What a page needs from a frame.
pub struct Frame<'a> {
    pub snap: &'a pm::Snapshot,
}

// ── Overview ────────────────────────────────────────────────────────────────

/// The verdict, and the evidence for it.
///
/// The findings come from the stream. Working out "is anything wrong" from the
/// component list here would be reimplementing the diagnostics layer, and it
/// could not know what a check added later means.
pub struct Overview {
    root: gtk::Box,
    status: adw::StatusPage,
    findings: gtk::ListBox,
    recoverable: adw::ActionRow,
    recoverable_group: gtk::Box,
}

impl Overview {
    pub fn new() -> Overview {
        let status = adw::StatusPage::builder()
            .icon_name("emblem-ok-symbolic")
            .title("Connecting")
            .build();
        status.set_vexpand(false);

        let findings = gtk::ListBox::new();
        findings.set_selection_mode(gtk::SelectionMode::None);
        findings.add_css_class("boxed-list");

        let recoverable = action_row();
        let rec_list = gtk::ListBox::new();
        rec_list.set_selection_mode(gtk::SelectionMode::None);
        rec_list.add_css_class("boxed-list");
        rec_list.append(&recoverable);
        let recoverable_group = section("Could be given back", &rec_list);
        recoverable_group.set_visible(false);

        let root = gtk::Box::new(gtk::Orientation::Vertical, 18);
        root.append(&status);
        root.append(&section("What is wrong", &findings));
        root.append(&recoverable_group);

        Overview {
            root,
            status,
            findings,
            recoverable,
            recoverable_group,
        }
    }

    pub fn widget(&self) -> &gtk::Box {
        &self.root
    }

    pub fn update(&self, f: &Frame<'_>) {
        let h = &f.snap.health;
        let title = match h.verdict {
            pm::Verdict::Crit => "Something is wrong",
            pm::Verdict::Warn => "Needs attention",
            pm::Verdict::Info => "Worth knowing",
            pm::Verdict::Ok => "All good",
        };
        self.status.set_icon_name(Some(verdict_icon(h.verdict)));
        self.status.set_title(title);
        self.status.set_description(Some(if h.headline.is_empty() {
            "Nothing to report."
        } else {
            &h.headline
        }));

        clear(&self.findings);
        for finding in &h.findings {
            let row = action_row();
            row.set_title(&finding.title);
            // The evidence, never rounded into an assertion — and set as TEXT,
            // because a detail can contain a `&` and Adw renders a subtitle as
            // Pango markup.
            row.set_subtitle(&finding.detail);
            // Same vocabulary as the verdict: a finding and the headline it
            // produced must not be different colours.
            let as_verdict = match finding.severity {
                pm::Severity::Crit => pm::Verdict::Crit,
                pm::Severity::Warn => pm::Verdict::Warn,
                pm::Severity::Info => pm::Verdict::Info,
            };
            let icon = gtk::Image::from_icon_name(verdict_icon(as_verdict));
            icon.add_css_class(verdict_class(as_verdict));
            row.add_prefix(&icon);
            if !finding.fix.is_empty() {
                // Shown, not offered as a button: pitcrew proposes and the
                // person decides. A one-click "fix" here would be acting on a
                // judgement the tool was careful not to make.
                let hint = gtk::Label::new(Some(&finding.fix));
                hint.add_css_class("dim-label");
                hint.add_css_class("numeric");
                row.add_suffix(&hint);
            }
            self.findings.append(&row);
        }
        if h.findings.is_empty() {
            let row = action_row();
            row.set_title("Nothing to report");
            row.set_subtitle("No crashed services, no memory pressure, no missing dependencies.");
            self.findings.append(&row);
        }

        // Protected components are LISTED even though they will never be
        // proposed: a list that quietly omits the one you expected reads as a
        // bug in the tool.
        let r = &h.recoverable;
        let any = !r.components.is_empty() || !r.protected.is_empty();
        self.recoverable_group.set_visible(any);
        if any {
            self.recoverable.set_title(&if r.components.is_empty() {
                "Nothing safe to stop".to_string()
            } else {
                format!(
                    "{} could free {}",
                    r.components.join(", "),
                    human_bytes(r.bytes)
                )
            });
            self.recoverable.set_subtitle(&if r.protected.is_empty() {
                "no CPU since pitcrew started watching, and up long enough to be forgotten".into()
            } else {
                format!("protected, so never proposed: {}", r.protected.join(", "))
            });
        }
    }
}

impl Default for Overview {
    fn default() -> Self {
        Self::new()
    }
}

// ── Components ──────────────────────────────────────────────────────────────

/// The list, with the actions that act on it.
pub struct Components {
    root: gtk::Box,
    list: gtk::ListBox,
    known: std::cell::RefCell<Vec<String>>,
    rows: std::cell::RefCell<Vec<ComponentRow>>,
}

/// What the user asked for. Handled by the window, which owns the CLI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Start(String),
    Stop(String),
    Restart(String),
    ShowLog(String),
}

impl Components {
    pub fn new() -> Components {
        let list = gtk::ListBox::new();
        list.set_selection_mode(gtk::SelectionMode::None);
        list.add_css_class("boxed-list");
        let root = gtk::Box::new(gtk::Orientation::Vertical, 18);
        root.append(&list);
        Components {
            root,
            list,
            known: std::cell::RefCell::new(Vec::new()),
            rows: std::cell::RefCell::new(Vec::new()),
        }
    }

    pub fn widget(&self) -> &gtk::Box {
        &self.root
    }

    /// `on_action` is called when a button is pressed.
    pub fn update(&self, f: &Frame<'_>, on_action: &std::rc::Rc<dyn Fn(Action)>) {
        // Rebuilt only when the SET changes. Replacing every row on every frame
        // loses focus and makes the list flicker once a second.
        let names: Vec<String> = f.snap.components.iter().map(|c| c.name.clone()).collect();
        if *self.known.borrow() != names {
            clear(&self.list);
            let mut rows = Vec::new();
            for c in &f.snap.components {
                let row = ComponentRow::new(c);
                row.attach_actions(on_action.clone());
                self.list.append(row.widget());
                rows.push(row);
            }
            *self.rows.borrow_mut() = rows;
            *self.known.borrow_mut() = names;
        }
        for (row, c) in self.rows.borrow().iter().zip(&f.snap.components) {
            row.update(c, f.snap.at);
        }
    }
}

impl Default for Components {
    fn default() -> Self {
        Self::new()
    }
}

// ── Resources ───────────────────────────────────────────────────────────────

/// The gauges, and what is holding the memory.
pub struct Resources {
    root: gtk::Box,
    gauges: Gauges,
    processes: gtk::ListBox,
}

impl Resources {
    pub fn new() -> Resources {
        let gauges = Gauges::new();
        let processes = gtk::ListBox::new();
        processes.set_selection_mode(gtk::SelectionMode::None);
        processes.add_css_class("boxed-list");

        let root = gtk::Box::new(gtk::Orientation::Vertical, 18);
        root.append(&section("This machine", gauges.widget()));
        root.append(&section("What is holding it", &processes));
        Resources {
            root,
            gauges,
            processes,
        }
    }

    pub fn widget(&self) -> &gtk::Box {
        &self.root
    }

    pub fn update(&self, f: &Frame<'_>) {
        self.gauges.update(&f.snap.machine);
        clear(&self.processes);

        // Biggest first: the question is "what is holding the memory", and an
        // alphabetical list makes the reader do the sorting.
        let mut running: Vec<&pm::Component> = f
            .snap
            .components
            .iter()
            .filter(|c| c.rss.is_some_and(|r| r > 0))
            .collect();
        running.sort_by_key(|c| std::cmp::Reverse(c.rss.unwrap_or(0)));

        if running.is_empty() {
            let row = action_row();
            row.set_title("Nothing running");
            self.processes.append(&row);
            return;
        }
        for c in running {
            let expander = expander_row();
            expander.set_title(&c.name);
            expander.set_subtitle(&format!(
                "{}{}",
                human_bytes(c.rss.unwrap_or(0)),
                c.limit
                    .map(|l| format!(" of {}", human_bytes(l)))
                    .unwrap_or_default()
            ));
            // The tree, from the stream. Asking the OS here would be the GUI
            // becoming a second monitor.
            for p in &c.processes {
                let row = action_row();
                row.set_title(&format!("{}", p.pid));
                row.set_subtitle(&p.cmd);
                if let Some(rss) = p.rss {
                    let label = gtk::Label::new(Some(&human_bytes(rss)));
                    label.add_css_class("numeric");
                    label.add_css_class("dim-label");
                    row.add_suffix(&label);
                }
                expander.add_row(&row);
            }
            self.processes.append(&expander);
        }
    }
}

impl Default for Resources {
    fn default() -> Self {
        Self::new()
    }
}

// ── Projects ────────────────────────────────────────────────────────────────

/// What pitcrew knows about.
pub struct Projects {
    root: gtk::Box,
    list: gtk::ListBox,
    loaded: std::cell::Cell<bool>,
}

impl Projects {
    pub fn new() -> Projects {
        let list = gtk::ListBox::new();
        list.set_selection_mode(gtk::SelectionMode::None);
        list.add_css_class("boxed-list");
        let root = gtk::Box::new(gtk::Orientation::Vertical, 18);
        root.append(&section("Registered projects", &list));
        Projects {
            root,
            list,
            loaded: std::cell::Cell::new(false),
        }
    }

    pub fn widget(&self) -> &gtk::Box {
        &self.root
    }

    /// Read once, not on every frame: the registry is a directory on disk that
    /// changes when somebody runs `pitcrew init`, not once a second.
    pub fn load(&self, text: &str) {
        if self.loaded.get() {
            return;
        }
        self.loaded.set(true);
        clear(&self.list);
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let current = line.starts_with('●');
            let rest = line.trim_start_matches(['●', '○', ' ']);
            let (name, path) = rest.split_once(' ').unwrap_or((rest, ""));
            let row = action_row();
            row.set_title(name);
            row.set_subtitle(path.trim());
            if current {
                let badge = gtk::Label::new(Some("in use"));
                badge.add_css_class("accent");
                row.add_suffix(&badge);
            }
            self.list.append(&row);
        }
    }
}

impl Default for Projects {
    fn default() -> Self {
        Self::new()
    }
}

// ── shared ──────────────────────────────────────────────────────────────────

/// The icon for a verdict, and the Adwaita class that colours it.
///
/// One place, because the header and the overview both show it and two copies
/// is two chances for the window to disagree with itself about how bad things
/// are. Drawn from Adwaita's own vocabulary, so it follows the user's theme.
pub fn verdict_icon(v: pm::Verdict) -> &'static str {
    match v {
        pm::Verdict::Crit => "dialog-error-symbolic",
        pm::Verdict::Warn => "dialog-warning-symbolic",
        pm::Verdict::Info => "dialog-information-symbolic",
        pm::Verdict::Ok => "emblem-ok-symbolic",
    }
}

pub fn verdict_class(v: pm::Verdict) -> &'static str {
    match v {
        pm::Verdict::Crit => "error",
        pm::Verdict::Warn => "warning",
        pm::Verdict::Info => "accent",
        pm::Verdict::Ok => "success",
    }
}

/// Every class [`verdict_class`] can return, for clearing before setting.
pub const VERDICT_CLASSES: [&str; 4] = ["error", "warning", "accent", "success"];

/// A titled group. Not `AdwPreferencesGroup` inside a page — that carries a
/// ~600px clamp which cannot be widened, and it is what left half of every
/// window empty.
pub fn section(title: &str, child: &impl IsA<gtk::Widget>) -> gtk::Box {
    let heading = gtk::Label::new(Some(title));
    heading.set_xalign(0.0);
    heading.add_css_class("heading");
    let group = gtk::Box::new(gtk::Orientation::Vertical, 8);
    group.append(&heading);
    group.append(child);
    group
}

pub fn clear(list: &gtk::ListBox) {
    while let Some(child) = list.first_child() {
        list.remove(&child);
    }
}
