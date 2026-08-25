//! ANSI escapes in a log, turned into styled spans.
//!
//! **A dev server's log is not plain text.** Spring Boot, Vite, gradle, npm and
//! pip all write SGR colour into it, and pitcrew captures stdout verbatim — as
//! it should, because the file is meant to be readable with `less -R` too.
//! Rendering those bytes literally turns a Spring log into a wall of
//! `␛[2m2026-08-20 11:04:19␛[0;39m ␛[32mINFO␛[0;39m` with the actual message
//! pushed off the right-hand edge.
//!
//! The terminal viewer solves this by throwing the colour away. That is the
//! right call for a frame it redraws at a fixed width and the wrong one for a
//! window: those colours are how you find the WARN in three hundred lines of
//! INFO.
//!
//! **This is a parser, not a stripper.** Do not "simplify" it into one. And no
//! GTK here, so the rules are testable without a display.

/// One run of text that shares a style.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Span {
    pub text: String,
    pub style: Style,
}

/// What SGR asked for. Deliberately a small subset: the attributes a log
/// actually uses, and nothing else.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Style {
    /// The 16-colour index, or `None` for the default foreground.
    pub fg: Option<u8>,
    pub bold: bool,
    /// SGR 2. Spring Boot writes its timestamps this way, and rendering them
    /// at full strength is most of why its logs look like noise.
    pub dim: bool,
    pub italic: bool,
    pub underline: bool,
}

/// Split a line into styled spans.
///
/// Every escape sequence is consumed, not only the ones acted on: an
/// erase-line or a cursor move has no meaning in a scrollback buffer, but it is
/// still not text and printing it is worse than dropping it.
pub fn parse(line: &str) -> Vec<Span> {
    let mut out: Vec<Span> = Vec::new();
    let mut style = Style::default();
    let mut text = String::new();
    let mut chars = line.chars().peekable();

    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            text.push(c);
            continue;
        }
        // Flush what came before the escape under the style it had.
        if !text.is_empty() {
            out.push(Span {
                text: std::mem::take(&mut text),
                style,
            });
        }
        match chars.peek() {
            // CSI — the only kind carrying anything worth keeping.
            Some('[') => {
                chars.next();
                let mut params = String::new();
                let mut final_byte = None;
                for c in chars.by_ref() {
                    if c.is_ascii_alphabetic() {
                        final_byte = Some(c);
                        break;
                    }
                    params.push(c);
                }
                if final_byte == Some('m') {
                    apply(&mut style, &params);
                }
                // Anything else (cursor moves, erases) is consumed and dropped.
            }
            // OSC — a window title, usually. Runs to BEL or ST.
            Some(']') => {
                chars.next();
                let mut prev = '\0';
                for c in chars.by_ref() {
                    if c == '\u{7}' || (prev == '\u{1b}' && c == '\\') {
                        break;
                    }
                    prev = c;
                }
            }
            // Everything else. ESC followed by an INTERMEDIATE byte (0x20-0x2F)
            // takes a final byte after it — `ESC ( B` is three bytes, not two,
            // and consuming only two leaves the `B` in the text as a stray
            // letter in the middle of a log line.
            Some(_) => {
                while chars
                    .peek()
                    .is_some_and(|c| ('\u{20}'..='\u{2f}').contains(c))
                {
                    chars.next();
                }
                // The final byte.
                chars.next();
            }
            None => {}
        }
    }
    if !text.is_empty() {
        out.push(Span { text, style });
    }
    out
}

fn apply(style: &mut Style, params: &str) {
    // A bare `\x1b[m` means reset, same as `\x1b[0m`.
    if params.is_empty() {
        *style = Style::default();
        return;
    }
    let mut codes = params.split(';').peekable();
    while let Some(raw) = codes.next() {
        // An empty field is a zero: `\x1b[0;39m` and `\x1b[;39m` mean the same.
        let code: u16 = raw.trim().parse().unwrap_or(0);
        match code {
            0 => *style = Style::default(),
            1 => style.bold = true,
            2 => style.dim = true,
            3 => style.italic = true,
            4 => style.underline = true,
            21 | 22 => {
                style.bold = false;
                style.dim = false;
            }
            23 => style.italic = false,
            24 => style.underline = false,
            30..=37 => style.fg = Some((code - 30) as u8),
            90..=97 => style.fg = Some((code - 90 + 8) as u8),
            39 => style.fg = None,
            // 256-colour and truecolour. Only the 256-colour form maps onto the
            // palette here; truecolour is consumed so its arguments are not
            // read back as separate attributes.
            38 => match codes.next().and_then(|m| m.parse::<u16>().ok()) {
                Some(5) => {
                    style.fg = codes.next().and_then(|v| v.parse::<u8>().ok());
                }
                Some(2) => {
                    codes.next();
                    codes.next();
                    codes.next();
                }
                _ => {}
            },
            _ => {}
        }
    }
}

/// The same line with every escape removed — for a fixed-width frame that has
/// no tag table to spend on colour.
pub fn strip(line: &str) -> String {
    parse(line).into_iter().map(|s| s.text).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(line: &str) -> Vec<String> {
        parse(line).into_iter().map(|s| s.text).collect()
    }

    #[test]
    fn plain_text_is_one_span() {
        assert_eq!(
            parse("hello"),
            [Span {
                text: "hello".into(),
                style: Style::default()
            }]
        );
        assert!(parse("").is_empty());
    }

    /// The shape that made a Spring log unreadable.
    #[test]
    fn a_spring_boot_line_comes_apart_into_readable_spans() {
        let line = "\u{1b}[2m2026-08-20 11:04:19\u{1b}[0;39m \u{1b}[32mINFO\u{1b}[0;39m started";
        let spans = parse(line);
        assert_eq!(spans[0].text, "2026-08-20 11:04:19");
        assert!(
            spans[0].style.dim,
            "the timestamp is dim, which is why it reads as noise at full strength"
        );
        let info = spans.iter().find(|s| s.text == "INFO").expect("the level");
        assert_eq!(info.style.fg, Some(2), "green");
        assert!(!info.style.dim, "the reset cleared it");
        assert_eq!(strip(line), "2026-08-20 11:04:19 INFO started");
    }

    /// `\x1b[0;39m` and `\x1b[;39m` mean the same thing, and a parser that
    /// reads an empty field as anything but zero drops the reset.
    #[test]
    fn an_empty_parameter_is_a_zero() {
        let a = parse("\u{1b}[1mx\u{1b}[0;39my");
        let b = parse("\u{1b}[1mx\u{1b}[;39my");
        assert_eq!(a, b);
        assert!(!a[1].style.bold);
    }

    /// A bare `\x1b[m` is a reset.
    #[test]
    fn a_bare_sgr_is_a_reset() {
        let spans = parse("\u{1b}[1;31mloud\u{1b}[mquiet");
        assert!(spans[0].style.bold && spans[0].style.fg == Some(1));
        assert_eq!(spans[1].style, Style::default());
    }

    /// An erase-line or a cursor move has no meaning in a scrollback buffer,
    /// but it is still not text.
    #[test]
    fn sequences_that_are_not_colour_are_dropped_rather_than_printed() {
        assert_eq!(strip("a\u{1b}[2Kb"), "ab");
        assert_eq!(strip("a\u{1b}[1;1Hb"), "ab");
        // OSC: a window title, to BEL or to ST.
        assert_eq!(strip("a\u{1b}]0;title\u{7}b"), "ab");
        assert_eq!(strip("a\u{1b}]0;title\u{1b}\\b"), "ab");
        // A two-character sequence.
        assert_eq!(strip("a\u{1b}(Bb"), "ab");
    }

    #[test]
    fn bright_colours_land_in_the_upper_half_of_the_palette() {
        assert_eq!(parse("\u{1b}[91mx")[0].style.fg, Some(9));
        assert_eq!(parse("\u{1b}[31mx")[0].style.fg, Some(1));
    }

    /// Truecolour is consumed whole. Reading its three arguments back as
    /// separate attributes is how a red foreground became bold-and-underlined.
    #[test]
    fn truecolour_arguments_are_not_read_as_attributes() {
        let spans = parse("\u{1b}[38;2;1;2;4mx");
        assert!(!spans[0].style.bold, "the 1 was a colour component");
        assert!(!spans[0].style.underline, "so was the 4");
    }

    #[test]
    fn a_256_colour_index_is_kept() {
        assert_eq!(parse("\u{1b}[38;5;208mx")[0].style.fg, Some(208));
    }

    /// A log line can end mid-sequence, because it is being appended to while
    /// it is read.
    #[test]
    fn an_unterminated_escape_does_not_leak_into_the_text() {
        assert_eq!(strip("done\u{1b}[3"), "done");
        assert_eq!(strip("done\u{1b}"), "done");
    }

    #[test]
    fn text_is_preserved_exactly_between_escapes() {
        assert_eq!(texts("\u{1b}[31ma b  c\u{1b}[0m"), ["a b  c"]);
        // Including characters that look like escapes but are not.
        assert_eq!(strip("cost: [30%]"), "cost: [30%]");
    }
}
