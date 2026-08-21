"""ANSI escape sequences in a log file, turned into spans a TextView can style.

A dev server's log is not plain text. Spring Boot, Vite, gradle, npm and pip all
write SGR colour into it, and pitcrew captures stdout verbatim — as it should,
because the file is meant to be readable with `less -R` too. The desktop app
was rendering those bytes literally, so a Spring log came out as a wall of
`▯▯[2m2026-08-20 11:04:19.670▯▯[0;39m ▯▯[32mINFO▯▯[0;39m`, with the actual
message pushed off the right-hand edge.

The terminal viewer solves this by throwing the colour away (`strip_ansi`).
That is the right call for a frame it has to redraw at a fixed width, and the
wrong one here: those colours are how you find the WARN in three hundred lines
of INFO, and a window has a tag table to spend on them.

No GTK in this file, so the parsing rules are testable without a display.
"""

from __future__ import annotations

import re

# Every escape sequence, not only the ones we act on. CSI (\\x1b[...), OSC
# (\\x1b]...BEL or ST), and the two-character sequences. Anything matched and
# not understood is dropped rather than printed — an erase-line or a cursor
# move has no meaning in a scrollback buffer, but it is still not text.
_SEQ = re.compile(
    r"\x1b\[([0-9;:]*)m"                 # 1: SGR, the only kind we interpret
    r"|\x1b\[[0-9;:?]*[ -/]*[@-~]"       # other CSI
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC (window titles)
    r"|\x1b[ -/]+[0-~]"                  # nF, e.g. ESC ( B — charset selection
    r"|\x1b[@-Z\\-_]"                    # two-character escapes
)
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

# SGR foreground codes to a name the view maps onto a palette. Bright variants
# are separate because "bright black" is a real grey that logs use for
# timestamps, and folding it into black would make those invisible.
_FG = {
    30: "black", 31: "red", 32: "green", 33: "yellow",
    34: "blue", 35: "magenta", 36: "cyan", 37: "white",
    90: "bright-black", 91: "bright-red", 92: "bright-green", 93: "bright-yellow",
    94: "bright-blue", 95: "bright-magenta", 96: "bright-cyan", 97: "bright-white",
}
_ATTR = {1: "bold", 2: "dim", 3: "italic", 4: "underline"}
_ATTR_OFF = {22: ("bold", "dim"), 23: ("italic",), 24: ("underline",)}

# xterm's 6x6x6 cube and greyscale ramp, for 38;5;N. Logs that use 256-colour
# mostly use it for greys and pastels, and rounding those to the nearest of
# eight would lose the distinction entirely.
_CUBE = (0, 95, 135, 175, 215, 255)


def _xterm256(index: int) -> str | None:
    if index < 16:
        return None                       # a palette colour; the caller names it
    if index < 232:
        index -= 16
        r, g, b = _CUBE[index // 36], _CUBE[index % 36 // 6], _CUBE[index % 6]
        return f"#{r:02x}{g:02x}{b:02x}"
    grey = 8 + (index - 232) * 10
    return f"#{grey:02x}{grey:02x}{grey:02x}"


class Style:
    """Foreground and attributes at a point in the stream."""

    __slots__ = ("fg", "attrs")

    def __init__(self, fg: str | None = None, attrs: frozenset[str] = frozenset()):
        self.fg = fg
        self.attrs = attrs

    def tags(self) -> tuple[str, ...]:
        return ((f"fg:{self.fg}",) if self.fg else ()) + tuple(sorted(self.attrs))

    def __eq__(self, other) -> bool:
        return isinstance(other, Style) and self.fg == other.fg and self.attrs == other.attrs

    def __hash__(self) -> int:
        return hash((self.fg, self.attrs))


def _apply(style: Style, params: str) -> Style:
    """One SGR sequence against the current style."""
    # "\\x1b[m" means "\\x1b[0m". An empty parameter inside a list means 0 too.
    codes = [int(p) if p.isdigit() else 0
             for p in (params.split(";") if params else ["0"])]
    fg, attrs = style.fg, set(style.attrs)
    index = 0
    while index < len(codes):
        code = codes[index]
        if code == 0:
            fg, attrs = None, set()
        elif code in _ATTR:
            attrs.add(_ATTR[code])
        elif code in _ATTR_OFF:
            attrs.difference_update(_ATTR_OFF[code])
        elif code in _FG:
            fg = _FG[code]
        elif code == 39:
            fg = None
        elif code == 38 and index + 1 < len(codes):
            # 38;5;N and 38;2;R;G;B. Consumed here so their arguments are never
            # mistaken for further codes — that is how a truecolor sequence
            # ends up setting a random background in a naive parser.
            kind = codes[index + 1]
            if kind == 5 and index + 2 < len(codes):
                named = _FG.get(codes[index + 2] + (30 if codes[index + 2] < 8 else 82))
                fg = named or _xterm256(codes[index + 2])
                index += 2
            elif kind == 2 and index + 4 < len(codes):
                r, g, b = codes[index + 2:index + 5]
                fg = f"#{r & 255:02x}{g & 255:02x}{b & 255:02x}"
                index += 4
        # Backgrounds (40-49, 100-107) are recognised by the code above only to
        # be skipped. A log that paints whole lines is unreadable in a window
        # that is not a terminal, and losing that emphasis beats a wall of
        # colour blocks.
        index += 1
    return Style(fg, frozenset(attrs))


def spans(line: str) -> list[tuple[str, tuple[str, ...]]]:
    """(text, tag names) pairs for one line, escapes consumed.

    Style does NOT carry across lines. It can in a real terminal, but a log
    buffer is scrolled, filtered and trimmed — one unterminated sequence would
    otherwise colour everything after it, including lines the writer had
    already reset. Per-line is the reading that survives being cut up.
    """
    line = _collapse_carriage_returns(line)
    out: list[tuple[str, tuple[str, ...]]] = []
    style = Style()
    position = 0
    for match in _SEQ.finditer(line):
        text = line[position:match.start()]
        if text:
            out.append((_CONTROL.sub("", text), style.tags()))
        if match.group(1) is not None:
            style = _apply(style, match.group(1))
        position = match.end()
    text = line[position:]
    if text:
        out.append((_CONTROL.sub("", text), style.tags()))
    return [(text, tags) for text, tags in out if text]


def _collapse_carriage_returns(line: str) -> str:
    """What a terminal would leave on screen after the line was overwritten.

    npm, pip and gradle draw progress by returning to column zero and writing
    again. Kept verbatim, one download turns into two hundred copies of itself.
    """
    if "\r" not in line:
        return line
    return line.rsplit("\r", 1)[-1]


def plain(line: str) -> str:
    """The line as text: what a filter should search and a pattern should match."""
    return "".join(text for text, _tags in spans(line))
