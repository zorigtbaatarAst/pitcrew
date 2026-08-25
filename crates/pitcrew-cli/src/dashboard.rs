//! The live dashboard.
//!
//! One frame is: collect, build, paint, wait for a key. The refresh interval
//! **is** the input timeout, so the repaint loop and the input loop are the same
//! loop — a design inherited from the shell version and worth keeping, because
//! the alternative is a second thread whose only job is to make the first one
//! redraw.
//!
//! Ratatui owns the alternate screen and the diffing, which removes the two
//! sharpest edges of the shell implementation: `fit_line` (an ANSI-aware
//! truncator written three times, once because the obvious version *hung*) and
//! the auto-wrap discipline, where one row too many scrolled the alt screen and
//! every subsequent repaint landed a line off, permanently.

use std::io;
use std::path::Path;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use pitcrew_core::format::{human_bytes, human_duration};
use pitcrew_core::layout::{self, Shape};
use pitcrew_core::supervise::{Action, Supervisor};
use pitcrew_model as pm;
use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::project;
use crate::state_object::Builder;

pub fn run(dir: Option<&Path>, name: Option<&str>, interval: f64) -> ExitCode {
    let session = match project::open(dir, name) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error  {e}");
            return ExitCode::FAILURE;
        }
    };
    let emoji = session.loaded.project.emoji.clone();
    // A project pins how it wants to be drawn; the flag is the override.
    let interval = setting(&session, "refresh")
        .and_then(|v| v.parse().ok())
        .unwrap_or(interval);
    let mut supervisor = Supervisor::new(
        setting(&session, "restart").as_deref() == Some("1"),
        pitcrew_core::supervise::Policy {
            backoff: setting(&session, "restart_backoff")
                .and_then(|v| v.parse().ok())
                .unwrap_or(2),
            max: setting(&session, "restart_max")
                .and_then(|v| v.parse().ok())
                .unwrap_or(5),
            reset: setting(&session, "restart_reset")
                .and_then(|v| v.parse().ok())
                .unwrap_or(60),
        },
    );
    let mut builder = Builder::new(&session);
    for w in &builder.warnings {
        eprintln!("warn   {w}");
    }

    let mut terminal = ratatui::init_with_options(ratatui::TerminalOptions {
        viewport: ratatui::Viewport::Fullscreen,
    });
    let result = loop_frames(
        &mut terminal,
        &mut builder,
        &session,
        interval,
        &emoji,
        &mut supervisor,
    );
    ratatui::restore();
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error  {e}");
            ExitCode::FAILURE
        }
    }
}

/// A project's `dashboard:` setting, if it pinned one.
fn setting(s: &project::Session, key: &str) -> Option<String> {
    s.loaded
        .project
        .dashboard
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.clone())
}

struct View {
    /// Which row the cursor is on, in the flattened component list.
    selected: usize,
    /// The last thing the supervisor did, shown until something replaces it.
    /// A dashboard that restarts a service silently looks like one that lost it.
    notice: Option<String>,
    /// Strips gauges, legends and healthy rows — but never the way out of
    /// itself, which is why the hint row is built last and `q` is listed first.
    zen: bool,
}

fn loop_frames(
    terminal: &mut ratatui::DefaultTerminal,
    builder: &mut Builder,
    session: &project::Session,
    interval: f64,
    emoji: &str,
    supervisor: &mut Supervisor,
) -> io::Result<()> {
    let gap = Duration::from_secs_f64(interval.max(0.1));
    let mut view = View {
        selected: 0,
        notice: None,
        zen: false,
    };

    let launcher = crate::run::launcher_for(session);
    loop {
        let snap = builder.build(session, false);

        // Called once per frame, and a no-op unless the project asked for it.
        // This is where auto-restart lives BECAUSE there is no daemon: it is
        // active while a dashboard is open and not otherwise, which is stated
        // rather than implied.
        let states: Vec<(String, pm::State)> = snap
            .components
            .iter()
            .map(|c| (c.name.clone(), c.state))
            .collect();
        for (name, action) in supervisor.tick(&states, snap.at) {
            match action {
                Action::Restart { attempt, of } => {
                    if let Some(c) = session.loaded.project.component(&name) {
                        let mut sampler = pitcrew_platform::process::Sampler::new();
                        launcher.stop(c, &sampler.sample().table);
                        let _ = launcher.start(c);
                    }
                    view.notice = Some(format!("↻ auto-restarting {name} ({attempt}/{of})"));
                }
                Action::GaveUp { after } => {
                    view.notice = Some(format!(
                        "✗ {name} keeps crashing — gave up after {after} restarts"
                    ));
                }
            }
        }

        terminal.draw(|f| draw(f, &snap, &view, emoji))?;

        // The refresh interval IS the input timeout: one loop, not two.
        let deadline = Instant::now() + gap;
        while Instant::now() < deadline {
            let left = deadline.saturating_duration_since(Instant::now());
            if !event::poll(left)? {
                break;
            }
            if let Event::Key(k) = event::read()? {
                // Windows reports press AND release; acting on both moves the
                // cursor two rows per keypress.
                if k.kind != KeyEventKind::Press {
                    continue;
                }
                match k.code {
                    KeyCode::Char('q') | KeyCode::Esc => return Ok(()),
                    KeyCode::Char('c') if k.modifiers.contains(KeyModifiers::CONTROL) => {
                        return Ok(())
                    }
                    KeyCode::Char('z') => view.zen = !view.zen,
                    KeyCode::Down | KeyCode::Char('j') => {
                        view.selected = view.selected.saturating_add(1)
                    }
                    KeyCode::Up | KeyCode::Char('k') => {
                        view.selected = view.selected.saturating_sub(1)
                    }
                    // Any other key just forces an early repaint, which is what
                    // someone pressing a key at a stale-looking screen wants.
                    _ => {}
                }
                break;
            }
        }
    }
}

fn draw(f: &mut Frame, snap: &pm::Snapshot, view: &View, emoji: &str) {
    let area = f.area();
    let rows: Vec<&pm::Component> = if view.zen {
        // Zen draws a LIST, not the table with rows removed: the table's header
        // rows, column pair and graph column cost more rows than the content
        // does once the content is one crashed service.
        snap.components
            .iter()
            .filter(|c| !matches!(c.state, pm::State::Up | pm::State::NotA))
            .collect()
    } else {
        snap.components.iter().collect()
    };

    let chunks = Layout::vertical([
        Constraint::Length(1), // title
        Constraint::Length(if view.zen { 0 } else { 1 }),
        Constraint::Min(1),    // the table
        Constraint::Length(2), // verdict + hints
    ])
    .split(area);

    let l = layout::for_width(area.width, &layout::Options::default());

    f.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                format!(" {emoji} {} ", snap.project),
                Style::default().add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!(
                    "  {} up · {} starting · {} crashed · {} down",
                    snap.summary.up, snap.summary.starting, snap.summary.crashed, snap.summary.down
                ),
                Style::default().fg(Color::DarkGray),
            ),
        ])),
        chunks[0],
    );

    if !view.zen {
        f.render_widget(
            Paragraph::new(Line::from(Span::styled(
                format!(
                    "  RAM {} / {}   CPU {}%",
                    human_bytes(snap.machine.mem_used),
                    human_bytes(snap.machine.mem_total),
                    snap.machine.cpu_percent
                ),
                Style::default().fg(Color::DarkGray),
            ))),
            chunks[1],
        );
    }

    let body: Vec<Line> = if rows.is_empty() {
        // A mode that goes blank looks broken. Say what it means instead.
        vec![Line::from(Span::styled(
            "  nothing needs attention",
            Style::default().fg(Color::Green),
        ))]
    } else {
        let selected = view.selected.min(rows.len() - 1);
        match l.shape {
            // Two per line. Zen is deliberately excluded: it draws a list, and
            // pairing a list of crashed services back into columns would be
            // reintroducing the table it exists to avoid.
            Shape::Wide if !view.zen => rows
                .chunks(2)
                .enumerate()
                .map(|(i, pair)| {
                    let mut spans = cell(pair[0], &l, i * 2 == selected);
                    if let Some(second) = pair.get(1) {
                        spans.push(Span::raw("  "));
                        spans.extend(cell(second, &l, i * 2 + 1 == selected));
                    }
                    Line::from(spans)
                })
                .collect(),
            _ => rows
                .iter()
                .enumerate()
                .map(|(i, c)| Line::from(cell(c, &l, i == selected)))
                .collect(),
        }
    };
    f.render_widget(
        Paragraph::new(body).block(Block::default().borders(Borders::NONE)),
        chunks[2],
    );

    let verdict_style = match snap.health.verdict {
        pm::Verdict::Crit => Style::default().fg(Color::Red),
        pm::Verdict::Warn => Style::default().fg(Color::Yellow),
        pm::Verdict::Info => Style::default().fg(Color::Cyan),
        pm::Verdict::Ok => Style::default().fg(Color::Green),
    };
    // The supervisor's last action outranks the verdict for one line: it is
    // the thing that just changed, and a restart nobody saw looks like a loss.
    let headline = match (&view.notice, snap.health.headline.is_empty()) {
        (Some(n), _) => n.clone(),
        (None, true) => "all good".to_string(),
        (None, false) => snap.health.headline.clone(),
    };
    f.render_widget(
        Paragraph::new(vec![
            Line::from(Span::styled(format!("  {headline}"), verdict_style)),
            // `q quit` FIRST, because the hint row is truncated from the END:
            // adding one hint to the tail of the old order silently pushed the
            // way out off a 160-column terminal.
            Line::from(Span::styled(
                if view.zen {
                    "  q quit · z leave zen · ↑↓ select"
                } else {
                    "  q quit · z zen · ↑↓ select"
                },
                Style::default().fg(Color::DarkGray),
            )),
        ]),
        chunks[3],
    );
}

fn cell(c: &pm::Component, l: &layout::Layout, selected: bool) -> Vec<Span<'static>> {
    let (mark, colour) = match c.state {
        pm::State::Up => ("●", Color::Green),
        pm::State::Starting => ("◐", Color::Yellow),
        pm::State::Crashed => ("✗", Color::Red),
        pm::State::External => ("◇", Color::Cyan),
        pm::State::Down => ("○", Color::DarkGray),
        pm::State::NotA => ("·", Color::DarkGray),
    };
    // The name column is the prefix minus its marker and status glyph. Every
    // branch below emits the same columns in the same order and at the same
    // widths — a skipped column shifts everything right by its width and lands
    // in the middle of the neighbouring service.
    let name_w = l.prefix_w.saturating_sub(4) as usize;
    let mut spans = vec![
        Span::styled(
            if selected { "▸ " } else { "  " },
            Style::default().fg(Color::White),
        ),
        Span::styled(format!("{mark} "), Style::default().fg(colour)),
        Span::raw(format!("{:<name_w$} ", elide(&c.name, name_w))),
        Span::styled(
            format!("{:<7}", c.port.map(|p| format!(":{p}")).unwrap_or_default()),
            Style::default().fg(Color::DarkGray),
        ),
    ];
    if l.ram {
        spans.push(Span::raw(format!(
            "{:>7}",
            c.rss.map(human_bytes).unwrap_or_default()
        )));
    }
    if l.cpu {
        spans.push(Span::raw(format!(
            "{:>5}",
            c.cpu.map(|v| format!("{v:.0}%")).unwrap_or_default()
        )));
    }
    if l.err && c.errors > 0 {
        spans.push(Span::styled(
            format!("{:>5}", format!("⚡{}", c.errors)),
            Style::default().fg(Color::Yellow),
        ));
    } else if l.err {
        spans.push(Span::raw("     "));
    }
    // The tail only exists where a row has slack. In the two-up shape it would
    // push the second cell off the terminal.
    if l.shape != Shape::Wide {
        if let (Some(code), pm::State::Crashed) = (c.exit, c.state) {
            // The one thing worth saying about a crash, on the row itself.
            spans.push(Span::styled(
                format!("  exited {code}"),
                Style::default().fg(Color::Red),
            ));
        } else if let Some(since) = c.since {
            if l.shape != Shape::Tiny {
                spans.push(Span::styled(
                    format!("  up {}", human_duration(now() - since)),
                    Style::default().fg(Color::DarkGray),
                ));
            }
        }
    }
    if !c.enabled {
        // Off keeps its row and says so. An excluded service that VANISHED is
        // one you spend an afternoon looking for.
        spans.push(Span::styled(" off", Style::default().fg(Color::DarkGray)));
    }
    spans
}

fn now() -> i64 {
    pitcrew_platform::now() as i64
}

fn elide(s: &str, w: usize) -> String {
    if s.chars().count() <= w || w < 2 {
        return s.to_string();
    }
    let keep: String = s.chars().take(w - 1).collect();
    format!("{keep}…")
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;

    fn component(name: &str, state: pm::State, port: u16) -> pm::Component {
        pm::Component {
            name: name.into(),
            app: "app".into(),
            role: name.split('-').next().unwrap_or("be").into(),
            state,
            port: Some(port),
            pid: Some(1),
            rss: Some(900 * 1024 * 1024),
            cpu: Some(4.0),
            errors: 0,
            exit: None,
            limit: Some(2 * 1024 * 1024 * 1024),
            limit_source: pm::LimitSource::Role,
            url: String::new(),
            health: String::new(),
            since: Some(now() - 3600),
            restarts: 0,
            idle: None,
            protected: false,
            enabled: true,
            processes: Vec::new(),
        }
    }

    fn snapshot(components: Vec<pm::Component>) -> pm::Snapshot {
        pm::Snapshot {
            schema: pm::SCHEMA,
            project: "demo".into(),
            root: "/tmp/demo".into(),
            collector: "native".into(),
            log_dir: String::new(),
            profile_dir: String::new(),
            error_pattern: String::new(),
            shells: Vec::new(),
            machine: pm::Machine {
                mem_total: 32 * 1024 * 1024 * 1024,
                mem_used: 8 * 1024 * 1024 * 1024,
                cpu_percent: 3,
                swap_total: 0,
                swap_used: 0,
            },
            at: now(),
            summary: pm::Summary {
                up: components
                    .iter()
                    .filter(|c| c.state == pm::State::Up)
                    .count() as u32,
                ..Default::default()
            },
            components,
            profiles: Vec::new(),
            deps: Vec::new(),
            health: pm::Health {
                verdict: pm::Verdict::Ok,
                headline: String::new(),
                deep: false,
                counts: pm::Counts::default(),
                findings: Vec::new(),
                recoverable: pm::Recoverable::default(),
            },
        }
    }

    /// Render at a size and return the lines, trailing space trimmed.
    fn paint(w: u16, h: u16, snap: &pm::Snapshot, view: &View) -> Vec<String> {
        let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
        terminal.draw(|f| draw(f, snap, view, "🧪")).unwrap();
        terminal
            .backend()
            .buffer()
            .content()
            .chunks(w as usize)
            .map(|row| {
                row.iter()
                    .map(|c| c.symbol())
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect()
    }

    fn view() -> View {
        View {
            selected: 0,
            notice: None,
            zen: false,
        }
    }

    /// The invariant the shell version needed a hand-written ANSI truncator to
    /// hold: nothing may exceed the terminal. One column too many and every
    /// subsequent repaint lands a line off.
    #[test]
    fn nothing_overflows_the_terminal_at_any_width() {
        let snap = snapshot(vec![
            component("be-api", pm::State::Up, 8080),
            component("fe-api", pm::State::Starting, 3000),
            component("worker-api", pm::State::Crashed, 9000),
        ]);
        for w in [40u16, 60, 80, 90, 110, 132, 160, 200] {
            for line in paint(w, 20, &snap, &view()) {
                assert!(
                    line.chars().count() <= w as usize,
                    "at {w} columns a line is {} wide: {line:?}",
                    line.chars().count()
                );
            }
        }
    }

    /// Two components per row is the whole point of the wide shape — rendering
    /// one per row wastes half a normal terminal.
    #[test]
    fn a_wide_terminal_puts_two_components_on_a_row() {
        let snap = snapshot(vec![
            component("be-api", pm::State::Up, 8080),
            component("fe-api", pm::State::Up, 3000),
        ]);
        let lines = paint(140, 20, &snap, &view());
        let both = lines
            .iter()
            .find(|l| l.contains("be-api") && l.contains("fe-api"));
        assert!(both.is_some(), "expected one row with both: {lines:#?}");
    }

    /// …and a narrow one does not try.
    #[test]
    fn a_narrow_terminal_puts_one_component_on_a_row() {
        let snap = snapshot(vec![
            component("be-api", pm::State::Up, 8080),
            component("fe-api", pm::State::Up, 3000),
        ]);
        let lines = paint(80, 20, &snap, &view());
        assert!(!lines
            .iter()
            .any(|l| l.contains("be-api") && l.contains("fe-api")));
    }

    /// A mode never hides the way out of itself. The hint row is truncated from
    /// the END, so `q quit` is listed first — adding a hint to the tail of the
    /// old order once pushed the way out off a 160-column terminal.
    #[test]
    fn the_way_out_is_always_on_screen() {
        let snap = snapshot(vec![component("be-api", pm::State::Up, 8080)]);
        for zen in [false, true] {
            for w in [40u16, 80, 160] {
                let v = View {
                    selected: 0,
                    notice: None,
                    zen,
                };
                let lines = paint(w, 20, &snap, &v);
                assert!(
                    lines.iter().any(|l| l.contains("q quit")),
                    "no way out at {w} columns, zen={zen}: {lines:#?}"
                );
            }
        }
    }

    /// Zen strips healthy rows — but a mode that goes blank looks broken, so it
    /// says what it means instead.
    #[test]
    fn zen_with_nothing_wrong_says_so_rather_than_going_blank() {
        let snap = snapshot(vec![component("be-api", pm::State::Up, 8080)]);
        let lines = paint(
            100,
            20,
            &snap,
            &View {
                selected: 0,
                notice: None,
                zen: true,
            },
        );
        assert!(lines.iter().any(|l| l.contains("nothing needs attention")));
        assert!(!lines.iter().any(|l| l.contains("be-api")));
    }

    /// …and shows the ones that are not healthy.
    #[test]
    fn zen_keeps_what_is_wrong() {
        let snap = snapshot(vec![
            component("be-api", pm::State::Up, 8080),
            component("fe-api", pm::State::Crashed, 3000),
        ]);
        let lines = paint(
            100,
            20,
            &snap,
            &View {
                selected: 0,
                notice: None,
                zen: true,
            },
        );
        assert!(lines.iter().any(|l| l.contains("fe-api")));
        assert!(!lines.iter().any(|l| l.contains("be-api")));
    }

    /// Off keeps its row and says so. An excluded service that VANISHED is one
    /// you spend an afternoon looking for.
    #[test]
    fn a_disabled_component_keeps_its_row() {
        let mut c = component("be-api", pm::State::Down, 8080);
        c.enabled = false;
        let lines = paint(100, 20, &snapshot(vec![c]), &view());
        let row = lines
            .iter()
            .find(|l| l.contains("be-api"))
            .expect("its row");
        assert!(row.contains("off"), "{row:?}");
    }

    /// A crash on its own tells you nothing actionable.
    #[test]
    fn a_crash_shows_its_exit_code_on_the_row() {
        let mut c = component("be-api", pm::State::Crashed, 8080);
        c.exit = Some(7);
        let lines = paint(100, 20, &snapshot(vec![c]), &view());
        assert!(lines.iter().any(|l| l.contains("exited 7")), "{lines:#?}");
    }

    /// A very small terminal is still a terminal.
    #[test]
    fn it_renders_at_all_in_a_tiny_window() {
        let snap = snapshot(vec![component("be-api", pm::State::Up, 8080)]);
        let lines = paint(40, 8, &snap, &view());
        assert!(lines.iter().any(|l| l.contains("demo")));
        assert!(lines.iter().any(|l| l.contains("q quit")));
    }
}
