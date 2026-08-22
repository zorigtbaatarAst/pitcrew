"""Targeted edits to a pitcrew.yaml, without parsing it.

The form in ConfigDialog changes fields; this turns a changed field into the
smallest possible edit to the file's text. Everything it does not touch stays
byte-identical — comments, blank lines, key order, the block-vs-flow style each
component happens to be written in.

Why not regenerate the file from the model? Because a config is something
people write and annotate, and an editor that rewrites it wholesale hands back
a file with every comment gone. That is not a save, it is a replacement.

Why not parse it properly? Because `lib/18-yaml.sh` is the ONE definition of
the subset pitcrew accepts. A second parser here would eventually accept a file
the tool rejects, or — much worse — silently misread one and save it back. So
this module never interprets a value. It finds the LINE a dotted path lives on,
and edits that line. What the file MEANS comes from `pitcrew config --json`,
which is pitcrew answering the question itself.
"""

from __future__ import annotations

import re

# A `key:` line, capturing indent, key and whatever follows on the same line.
# Quoted keys are not matched on purpose: pitcrew accepts them, this cannot
# safely rewrite them, and `locate` returning nothing sends the caller to the
# raw-text tab rather than guessing.
_KEY = re.compile(r"^(?P<indent>[ ]*)(?P<key>[A-Za-z0-9_][A-Za-z0-9_.\-]*):(?P<rest>.*)$")

_NEEDS_QUOTING = "#&*!|>%@`[]{},'\"?-"
_RESERVED = {"true", "false", "null", "~", "yes", "no", "on", "off",
             "True", "False", "Null", "TRUE", "FALSE", "NULL"}


def format_value(value: str, flow: bool = False) -> str:
    """A scalar, quoted only when leaving it bare would change what it means.

    `flow=True` for a value going inside `{ … }`, where a comma separates the
    pairs and a quote opens a string — so both have to be quoted there and
    neither does on a line of its own.
    """
    if value == "":
        return '""'
    needs = (
        # Leading or trailing space is significant and a bare scalar loses it.
        value != value.strip()
        # In a flow mapping a comma separates the pairs and a quote opens a
        # string; on a line of its own both are ordinary characters.
        or (flow and any(char in value for char in ",{}\"'"))
        or value[0] in _NEEDS_QUOTING
        or value in _RESERVED
        # ": " inside a bare scalar makes the rest of the line look like a
        # mapping, and a trailing ":" makes the whole thing look like a key.
        or ": " in value
        or value.endswith(":")
        or "\n" in value
        # An inline comment starts at " #", so a value containing one would
        # silently lose its tail.
        or " #" in value
    )
    return _quote(value) if needs else value


def _quote(value: str) -> str:
    body = (value.replace("\\", "\\\\").replace('"', '\\"')
                 .replace("\n", "\\n").replace("\t", "\\t"))
    return f'"{body}"'


class _Line:
    """One `key:` line, with the dotted path it sits at."""

    __slots__ = ("index", "indent", "key", "path", "rest")

    def __init__(self, index: int, indent: int, key: str, path: tuple[str, ...], rest: str):
        self.index = index
        self.indent = indent
        self.key = key
        self.path = path
        self.rest = rest

    @property
    def is_block(self) -> bool:
        """True when the line opens a block rather than carrying a value."""
        return self.rest.strip() == ""

    @property
    def is_flow(self) -> bool:
        return self.rest.strip().startswith("{")


def scan(text: str) -> list[_Line]:
    """Every mapping key in the file, with its dotted path.

    Indentation-driven, exactly like the bash parser: a line indented further
    than the one above it is a child of it. Sequence items, block scalars and
    comments are skipped rather than interpreted — this only needs to know
    where the keys are.
    """
    out: list[_Line] = []
    stack: list[tuple[int, tuple[str, ...]]] = []   # (indent, path)
    skip_until_indent: int | None = None

    for index, raw in enumerate(text.splitlines()):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))

        # Inside a block scalar (| or >), the body is text, not keys.
        if skip_until_indent is not None:
            if indent > skip_until_indent:
                continue
            skip_until_indent = None

        if stripped.startswith("- "):
            continue                       # a sequence item; nothing addressable
        match = _KEY.match(raw)
        if not match:
            continue

        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1] if stack else ()
        key = match.group("key")
        path = (*parent, key)
        rest = match.group("rest")
        out.append(_Line(index, indent, key, path, rest))

        body = rest.strip()
        if body.startswith("|") or body.startswith(">"):
            skip_until_indent = indent
        elif body == "":
            stack.append((indent, path))
    return out


def _flow_pairs(body: str) -> list[tuple[str, str]]:
    """`{a: b, c: d}` → [("a", "b"), ("c", "d")], honouring quotes.

    The same split lib/18-yaml.sh does, for the same reason: a comma inside a
    quoted value is part of the value, not a separator.
    """
    inner = body.strip()
    inner = inner.removeprefix("{")
    inner = inner.removesuffix("}")
    pairs: list[tuple[str, str]] = []
    current, quote = "", ""
    for char in inner:
        if quote:
            current += char
            if char == quote:
                quote = ""
        elif char in "'\"":
            quote = char
            current += char
        elif char == ",":
            pairs.append(current)
            current = ""
        else:
            current += char
    pairs.append(current)
    out: list[tuple[str, str]] = []
    for raw in pairs:
        item = raw.strip()
        if not item or ":" not in item:
            continue
        key, _, value = item.partition(":")
        out.append((key.strip(), value.strip()))
    return out


def _render_flow(pairs: list[tuple[str, str]]) -> str:
    return "{ " + ", ".join(f"{k}: {v}" for k, v in pairs) + " }"


def _find(lines: list[_Line], path: tuple[str, ...]) -> _Line | None:
    for line in lines:
        if line.path == path:
            return line
    return None


def _child_indent(text_lines: list[str], lines: list[_Line], parent: _Line) -> int:
    """How far this file indents children of `parent` — measured, not assumed."""
    for line in lines:
        if len(line.path) == len(parent.path) + 1 and line.path[:-1] == parent.path:
            return line.indent
    return parent.indent + 2


def set_value(text: str, path: tuple[str, ...], value: str | None,
              literal: bool = False) -> str:
    """Set `path` to `value`, or remove it when value is None.

    `literal=True` writes the value exactly as given, for the booleans the form
    produces itself. Without it `enabled: false` would come out as
    `enabled: "false"` — correct, and not what anybody would have typed.

    Returns the text unchanged if there is nothing to do. Raises LookupError
    when the parent does not exist and cannot be created — the caller then
    sends the user to the raw tab rather than this module inventing structure
    it does not understand.
    """
    text_lines = text.splitlines()
    lines = scan(text)

    existing = _find(lines, path)
    if existing is not None:
        if value is None:
            return _delete(text_lines, lines, existing)
        return _replace(text_lines, existing, value, literal)

    # Not a line of its own — it may be a pair inside a parent's flow mapping.
    parent_path = path[:-1]
    parent = _find(lines, parent_path) if parent_path else None
    if parent is not None and parent.is_flow:
        return _edit_flow(text_lines, parent, path[-1], value, literal)

    if value is None:
        return text                         # already absent; nothing to remove

    if parent is None:
        raise LookupError(".".join(parent_path) or "(root)")
    if not parent.is_block:
        # `be: something` with a scalar on it cannot also hold children.
        raise LookupError(".".join(parent_path))

    indent = _child_indent(text_lines, lines, parent)
    insert_at = _end_of_block(text_lines, parent)
    written = value if literal else format_value(value)
    text_lines.insert(insert_at, f"{' ' * indent}{path[-1]}: {written}")
    return "\n".join(text_lines) + ("\n" if text.endswith("\n") else "")


def _replace(text_lines: list[str], line: _Line, value: str,
             literal: bool = False) -> str:
    raw = text_lines[line.index]
    comment = _trailing_comment(line.rest)
    written = value if literal else format_value(value)
    text_lines[line.index] = f"{' ' * line.indent}{line.key}: {written}{comment}"
    return "\n".join(text_lines) + ("\n" if raw is not None else "")


def _trailing_comment(rest: str) -> str:
    """Keep an aligned ` # note` on a line whose value is being replaced."""
    body = rest
    quote = ""
    for i, char in enumerate(body):
        if quote:
            if char == quote:
                quote = ""
        elif char in "'\"":
            quote = char
        elif char == "#" and i > 0 and body[i - 1] == " ":
            return "  " + body[i:].strip()
    return ""


def _edit_flow(text_lines: list[str], parent: _Line, key: str,
               value: str | None, literal: bool = False) -> str:
    pairs = _flow_pairs(parent.rest)
    pairs = [(k, v) for k, v in pairs if k != key]
    if value is not None:
        pairs.append((key, value if literal else format_value(value, flow=True)))
    if not pairs:
        text_lines[parent.index] = f"{' ' * parent.indent}{parent.key}: {{}}"
    else:
        text_lines[parent.index] = (f"{' ' * parent.indent}{parent.key}: "
                                    f"{_render_flow(pairs)}")
    return "\n".join(text_lines) + "\n"


def _end_of_block(text_lines: list[str], parent: _Line) -> int:
    """The index just past everything indented under `parent`."""
    last = parent.index
    for index in range(parent.index + 1, len(text_lines)):
        raw = text_lines[index]
        if not raw.strip():
            continue                        # a blank line inside a block stays inside
        indent = len(raw) - len(raw.lstrip(" "))
        if indent <= parent.indent:
            break
        last = index
    return last + 1


def _delete(text_lines: list[str], lines: list[_Line], line: _Line) -> str:
    end = _end_of_block(text_lines, line) if line.is_block else line.index + 1
    del text_lines[line.index:end]
    return "\n".join(text_lines) + "\n"


def add_block(text: str, path: tuple[str, ...], fields: list[tuple[str, str]]) -> str:
    """Add a new block at `path` with `fields` under it.

    Used for a whole new component or app, which is the one thing a field-level
    edit cannot express.
    """
    text_lines = text.splitlines()
    lines = scan(text)
    if _find(lines, path) is not None:
        raise LookupError(f"{'.'.join(path)} already exists")

    parent_path = path[:-1]
    parent = _find(lines, parent_path) if parent_path else None
    if parent_path and parent is None:
        raise LookupError(".".join(parent_path))

    if parent is None:
        indent = 0
        insert_at = len(text_lines)
    else:
        indent = _child_indent(text_lines, lines, parent)
        insert_at = _end_of_block(text_lines, parent)

    block = [f"{' ' * indent}{path[-1]}:"]
    block += [f"{' ' * (indent + 2)}{k}: {format_value(v)}" for k, v in fields]
    text_lines[insert_at:insert_at] = block
    return "\n".join(text_lines) + "\n"
