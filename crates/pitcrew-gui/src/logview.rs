//! Following a component's log.
//!
//! It does not know where logs live: `logDir` arrives in the stream, like
//! everything else. Deciding for itself would be the GUI re-deriving something
//! the CLI already told it.
//!
//! Colour is parsed rather than stripped — see `pitcrew_core::ansi` for why
//! that is the difference between finding the WARN in three hundred lines of
//! INFO and not.

use adw::prelude::*;
use gtk::glib;
use pitcrew_core::ansi;

/// How much of a log to show.
///
/// A dev server can write megabytes in an afternoon, and a TextView holding all
/// of it is a window that stops scrolling smoothly. The tail is what anyone
/// reads anyway.
const TAIL_LINES: usize = 800;

pub struct LogView {
    root: gtk::Box,
    text: gtk::TextView,
    buffer: gtk::TextBuffer,
    scroller: gtk::ScrolledWindow,
    title: gtk::Label,
    /// The component being followed, and how far into its file we have read.
    following: std::cell::RefCell<Option<(String, u64)>>,
    empty: adw::StatusPage,
    stack: gtk::Stack,
}

impl LogView {
    pub fn new() -> std::rc::Rc<LogView> {
        let buffer = gtk::TextBuffer::new(None);
        // One tag per palette entry, made once. Creating tags per line is how a
        // log view comes to spend more time in the tag table than on screen.
        let tags = buffer.tag_table();
        for (i, colour) in PALETTE.iter().enumerate() {
            let tag = gtk::TextTag::builder()
                .name(format!("fg{i}"))
                .foreground(*colour)
                .build();
            tags.add(&tag);
        }
        for (name, tag) in [
            (
                "bold",
                gtk::TextTag::builder().name("bold").weight(700).build(),
            ),
            // Spring Boot writes its timestamps dim, and rendering them at full
            // strength is most of why its logs look like noise.
            (
                "dim",
                gtk::TextTag::builder()
                    .name("dim")
                    .foreground("#8b8b8b")
                    .build(),
            ),
            (
                "italic",
                gtk::TextTag::builder()
                    .name("italic")
                    .style(gtk::pango::Style::Italic)
                    .build(),
            ),
            (
                "underline",
                gtk::TextTag::builder()
                    .name("underline")
                    .underline(gtk::pango::Underline::Single)
                    .build(),
            ),
        ] {
            let _ = name;
            tags.add(&tag);
        }

        let text = gtk::TextView::builder()
            .buffer(&buffer)
            .editable(false)
            .cursor_visible(false)
            .monospace(true)
            .wrap_mode(gtk::WrapMode::WordChar)
            .left_margin(12)
            .right_margin(12)
            .top_margin(8)
            .bottom_margin(8)
            .build();
        text.add_css_class("logview");

        let scroller = gtk::ScrolledWindow::builder()
            .vexpand(true)
            .hexpand(true)
            .child(&text)
            .build();

        let title = gtk::Label::new(Some("no component selected"));
        title.set_xalign(0.0);
        title.add_css_class("heading");
        title.set_margin_top(12);
        title.set_margin_start(12);

        let empty = adw::StatusPage::builder()
            .icon_name("text-x-generic-symbolic")
            .title("No log open")
            .description("Pick a component on the Components page.")
            .build();

        let stack = gtk::Stack::new();
        stack.add_named(&empty, Some("empty"));
        stack.add_named(&scroller, Some("log"));
        stack.set_visible_child_name("empty");

        let root = gtk::Box::new(gtk::Orientation::Vertical, 6);
        root.append(&title);
        root.append(&stack);

        std::rc::Rc::new(LogView {
            root,
            text,
            buffer,
            scroller,
            title,
            following: std::cell::RefCell::new(None),
            empty,
            stack,
        })
    }

    pub fn widget(&self) -> &gtk::Box {
        &self.root
    }

    /// Follow a different component. Resets the buffer and the read position.
    pub fn follow(self: &std::rc::Rc<Self>, comp: &str, log_dir: &str) {
        self.title.set_text(comp);
        self.buffer.set_text("");
        *self.following.borrow_mut() = Some((comp.to_string(), 0));
        self.stack.set_visible_child_name("log");
        let _ = &self.empty;
        self.poll(log_dir);
    }

    /// Read whatever is new. Called on every frame.
    ///
    /// Incremental, from a retained offset: re-reading the file each second
    /// over a log a JVM is appending to is how a window comes to spend a core
    /// on scrollback.
    pub fn poll(self: &std::rc::Rc<Self>, log_dir: &str) {
        let Some((comp, offset)) = self.following.borrow().clone() else {
            return;
        };
        let path = std::path::Path::new(log_dir).join(format!("{comp}.log"));
        let Ok(meta) = std::fs::metadata(&path) else {
            return;
        };
        let size = meta.len();
        // Shrunk: the log was rotated by a restart, so the offset means nothing
        // against this file and what is on screen belongs to a run that is over.
        if size < offset {
            self.buffer.set_text("");
            *self.following.borrow_mut() = Some((comp.clone(), 0));
            return self.poll(log_dir);
        }
        if size == offset {
            return;
        }

        let Ok(text) = read_from(&path, offset) else {
            return;
        };
        *self.following.borrow_mut() = Some((comp, size));

        // Only follow the tail if the reader is ALREADY at the bottom.
        // Yanking the view down while somebody is reading history is the single
        // most annoying thing a log window can do.
        let adj = self.scroller.vadjustment();
        let at_bottom = adj.value() + adj.page_size() >= adj.upper() - 24.0;

        let mut end = self.buffer.end_iter();
        for line in text.lines() {
            for span in ansi::parse(line) {
                let start_offset = end.offset();
                self.buffer.insert(&mut end, &span.text);
                let mut from = self.buffer.iter_at_offset(start_offset);
                apply_tags(&self.buffer, &mut from, &mut end, &span.style);
            }
            self.buffer.insert(&mut end, "\n");
        }
        trim(&self.buffer);

        if at_bottom {
            let view = self.text.clone();
            let buffer = self.buffer.clone();
            // After the layout has caught up with the insert, or the scroll
            // targets a position that does not exist yet.
            glib::idle_add_local_once(move || {
                let mut end = buffer.end_iter();
                view.scroll_to_iter(&mut end, 0.0, false, 0.0, 0.0);
            });
        }
    }
}

fn read_from(path: &std::path::Path, offset: u64) -> std::io::Result<String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path)?;
    f.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::new();
    f.read_to_end(&mut bytes)?;
    // Lossy on purpose: a log is captured verbatim and may hold half a
    // multibyte character at the boundary. One mangled glyph beats refusing the
    // whole read.
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn apply_tags(
    buffer: &gtk::TextBuffer,
    from: &mut gtk::TextIter,
    to: &mut gtk::TextIter,
    style: &ansi::Style,
) {
    if let Some(fg) = style.fg {
        if (fg as usize) < PALETTE.len() {
            buffer.apply_tag_by_name(&format!("fg{fg}"), from, to);
        }
    }
    for (on, name) in [
        (style.bold, "bold"),
        (style.dim, "dim"),
        (style.italic, "italic"),
        (style.underline, "underline"),
    ] {
        if on {
            buffer.apply_tag_by_name(name, from, to);
        }
    }
}

/// Keep the buffer bounded — see [`TAIL_LINES`].
fn trim(buffer: &gtk::TextBuffer) {
    let lines = buffer.line_count();
    if lines <= TAIL_LINES as i32 {
        return;
    }
    let start = buffer.start_iter();
    if let Some(cut) = buffer.iter_at_line(lines - TAIL_LINES as i32) {
        let mut start = start;
        let mut cut = cut;
        buffer.delete(&mut start, &mut cut);
    }
}

/// The 16 ANSI colours, plus enough of the 256-colour cube to cover what logs
/// actually use. Chosen to stay legible on a light AND a dark desktop, which
/// the terminal defaults are not.
const PALETTE: [&str; 16] = [
    "#555555", "#c0392b", "#27ae60", "#b7950b", "#2980b9", "#8e44ad", "#16a085", "#8b8b8b",
    "#7f8c8d", "#e74c3c", "#2ecc71", "#f1c40f", "#3498db", "#9b59b6", "#1abc9c", "#2c3e50",
];
