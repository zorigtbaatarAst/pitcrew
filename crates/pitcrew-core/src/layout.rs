//! How wide everything is, at whatever width the terminal happens to be.
//!
//! **Not a table of magic numbers — a priority order.** Columns are dropped
//! cheapest-loss-first until the fixed part of a row fits; the graph is not in
//! that list because it is the flexible column that soaks up whatever is left,
//! so it shrinks on its own before anything is lost. Only once it hits its own
//! minimum does the room go back to the name.
//!
//! Two rules that come out of this and are easy to break by accident:
//!
//! * **A mode is a layout, not a filter over one.** Narrow does not draw the
//!   wide table with a column hidden; it draws a different table. Filtering a
//!   layout built for twelve columns is how you get a wide, mostly-blank screen
//!   and call it focus.
//! * **Past both caps the table stops growing.** This is a max-width container,
//!   not a stretched one — a row that sprawls to a 400-column terminal leads
//!   the eye further from the numbers, not closer.

/// Column widths, in cells. Each is what the content actually needs.
const W_ICON: u16 = 2; // "● "
const W_PORT: u16 = 7; // ":8082 " or "n/a    "
const W_RAM: u16 = 7; // " 893M"
const W_RAM_CAP: u16 = 12; // " 1.2G/8G  " when caps are spelled out
const W_CPU: u16 = 5; // "  0%"
const W_ERR: u16 = 5; // " ⚡7  "

const PREFIX_W: u16 = 15; // marker(2) + " " + app(11) + " "
const PREFIX_MIN_W: u16 = 6; // nothing below this reads
const PREFIX_MAX_W: u16 = 26; // past this the name just leads the eye away
const CELL_GAP_W: u16 = 2;
const MIN_GRAPH_W: u16 = 6; // under this a sparkline is decoration, not information
const MAX_GRAPH_W: u16 = 40; // past this the row sprawls and history stops reading

/// How much the layout has had to give up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    Xl,
    Lg,
    Md,
    Sm,
    Xs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shape {
    /// Two components side by side per row.
    Wide,
    /// One per row, with a graph.
    Narrow,
    /// One per row, no graph — there was no room for one worth drawing.
    Tiny,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Layout {
    pub shape: Shape,
    pub tier: Tier,
    pub cells: u16,
    pub prefix_w: u16,
    pub graph_w: u16,
    /// One cell minus its graph, at the surviving column set.
    pub cell_fixed_w: u16,
    pub ram: bool,
    pub cpu: bool,
    pub err: bool,
}

pub struct Options {
    /// Below this width, one component per row.
    pub narrow_at: u16,
    pub xl_at: u16,
    /// Spell the cap out beside the value (`1.2G/8G`) rather than implying it
    /// with colour alone.
    pub ram_cap: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            narrow_at: 110,
            xl_at: 160,
            ram_cap: false,
        }
    }
}

pub fn for_width(width: u16, opts: &Options) -> Layout {
    let w_ram = if opts.ram_cap { W_RAM_CAP } else { W_RAM };
    let cells: u16 = if width >= opts.narrow_at { 2 } else { 1 };

    let (mut ram, mut cpu, mut err) = (true, true, true);
    let fixed = |ram: bool, cpu: bool, err: bool| -> u16 {
        W_ICON
            + W_PORT
            + if ram { w_ram } else { 0 }
            + if cpu { W_CPU } else { 0 }
            + if err { W_ERR } else { 0 }
    };
    let mut prefix_w = PREFIX_W;

    // Cheapest loss first. The error count is a number you can get from the
    // log; CPU is a number the graph already implies; RAM is the one people
    // actually came for, so it goes last.
    for drop in [Some("err"), Some("cpu"), Some("ram"), None] {
        let f = fixed(ram, cpu, err);
        if prefix_w + cells * f + (cells - 1) * CELL_GAP_W <= width {
            break;
        }
        match drop {
            Some("err") => err = false,
            Some("cpu") => cpu = false,
            Some("ram") => ram = false,
            _ => break,
        }
    }
    let cell_fixed_w = fixed(ram, cpu, err);

    // Whatever the fixed columns did not take is the graph's, split between
    // the cells.
    let used = prefix_w + cells * cell_fixed_w + (cells - 1) * CELL_GAP_W;
    let mut graph_w = width.saturating_sub(used) / cells;
    graph_w = graph_w.min(MAX_GRAPH_W);
    if graph_w < MIN_GRAPH_W {
        graph_w = 0;
        // Give the name column whatever the cells leave, so the row still ends
        // inside the terminal rather than being cut off by it.
        prefix_w = width
            .saturating_sub(cells * cell_fixed_w + (cells - 1) * CELL_GAP_W)
            .clamp(PREFIX_MIN_W, PREFIX_W);
    }

    // Whatever is STILL left once the graph has hit its cap goes to the name,
    // up to a limit of its own: a wide window should buy something — service
    // names that are not elided — and a row that stops two thirds of the way
    // across looks like a bug even when the numbers are right.
    let slack = width
        .saturating_sub(prefix_w + cells * (cell_fixed_w + graph_w) + (cells - 1) * CELL_GAP_W);
    if slack > 0 && prefix_w < PREFIX_MAX_W {
        prefix_w = (prefix_w + slack).min(PREFIX_MAX_W);
    }

    let (shape, tier) = if cells == 2 {
        (
            Shape::Wide,
            if width >= opts.xl_at {
                Tier::Xl
            } else {
                Tier::Lg
            },
        )
    } else if graph_w == 0 {
        (Shape::Tiny, Tier::Sm)
    } else if ram && cpu && err {
        (Shape::Narrow, Tier::Md)
    } else {
        (Shape::Narrow, Tier::Xs)
    };

    Layout {
        shape,
        tier,
        cells,
        prefix_w,
        graph_w,
        cell_fixed_w,
        ram,
        cpu,
        err,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(w: u16) -> Layout {
        for_width(w, &Options::default())
    }

    /// The total width a row occupies.
    ///
    /// Lives here rather than on `Layout` because nothing in production asks
    /// the question — the renderer pads each column to the width it was given.
    /// It exists to state the invariant the whole cascade is FOR.
    fn row_w(l: &Layout) -> u16 {
        l.prefix_w + l.cells * (l.cell_fixed_w + l.graph_w) + (l.cells - 1) * CELL_GAP_W
    }

    /// The invariant everything else rests on: a row must never be wider than
    /// the terminal, at any width. One column too many and the terminal
    /// guillotines every row — or worse, wraps and every subsequent repaint
    /// lands a line lower.
    #[test]
    fn a_row_never_exceeds_the_terminal_at_any_width() {
        for w in 20..=400u16 {
            let l = at(w);
            assert!(
                row_w(&l) <= w,
                "at {w} columns the row wants {} — it would be cut off",
                row_w(&l)
            );
        }
    }

    #[test]
    fn two_components_per_row_once_there_is_room() {
        assert_eq!(at(80).shape, Shape::Narrow);
        assert_eq!(at(110).cells, 2);
        assert_eq!(at(110).shape, Shape::Wide);
        assert_eq!(at(200).tier, Tier::Xl);
        assert_eq!(at(120).tier, Tier::Lg);
    }

    /// Cheapest loss first: the error count is derivable from the log, CPU is
    /// implied by the graph, RAM is what people came for.
    #[test]
    fn columns_are_dropped_in_priority_order() {
        let wide = at(110);
        assert!(wide.ram && wide.cpu && wide.err);

        // Squeeze until each is given up, and check the order it happens in.
        let mut lost = Vec::new();
        let mut prev = at(110);
        for w in (20..110).rev() {
            let l = at(w);
            if prev.err && !l.err {
                lost.push("err");
            }
            if prev.cpu && !l.cpu {
                lost.push("cpu");
            }
            if prev.ram && !l.ram {
                lost.push("ram");
            }
            prev = l;
        }
        assert_eq!(lost, ["err", "cpu", "ram"], "RAM must be the last to go");
    }

    /// Under its minimum a sparkline is decoration, not information — and the
    /// room is better spent on the name.
    #[test]
    fn a_graph_too_small_to_read_is_dropped_entirely() {
        for w in 20..400u16 {
            let l = at(w);
            assert!(
                l.graph_w == 0 || l.graph_w >= MIN_GRAPH_W,
                "at {w} the graph is {} cells — too narrow to mean anything",
                l.graph_w
            );
        }
        // 30 columns is exactly enough for the minimum graph; 25 is not.
        assert_eq!(
            at(30).graph_w,
            MIN_GRAPH_W,
            "the smallest graph worth drawing"
        );
        assert_eq!(
            at(25).shape,
            Shape::Tiny,
            "no room for a graph at 25 columns"
        );
        assert_eq!(at(25).graph_w, 0);
    }

    /// A max-width container, not a stretched one. Past both caps the table
    /// stops growing rather than leading the eye further from the numbers.
    #[test]
    fn the_table_stops_growing_rather_than_sprawling() {
        let big = at(400);
        assert!(big.graph_w <= MAX_GRAPH_W);
        assert!(big.prefix_w <= PREFIX_MAX_W);
        assert_eq!(at(400).graph_w, at(300).graph_w, "already at the cap");
    }

    /// A wide window should buy something: names that are not elided.
    #[test]
    fn extra_width_goes_to_the_name_once_the_graph_is_capped() {
        assert!(at(300).prefix_w > at(110).prefix_w);
    }

    /// Nothing below this reads as a name at all.
    #[test]
    fn the_name_column_never_shrinks_below_readable() {
        for w in 20..400u16 {
            assert!(at(w).prefix_w >= PREFIX_MIN_W, "at {w} columns");
        }
    }

    /// Spelling the cap out needs the room for it, and that has to be decided
    /// before any width is added up — not corrected afterwards.
    #[test]
    fn spelling_out_the_cap_is_accounted_for_in_the_width() {
        let opts = Options {
            ram_cap: true,
            ..Default::default()
        };
        for w in 20..400u16 {
            let l = for_width(w, &opts);
            assert!(row_w(&l) <= w, "at {w} columns with caps spelled out");
        }
        // It costs five cells, so at a width that just fit before it will not now.
        assert!(for_width(110, &opts).graph_w < at(110).graph_w);
    }
}
