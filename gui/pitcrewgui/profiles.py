"""Saved sets of targets, read from the directory pitcrew keeps them in.

`pitcrew profile save/list/rm` has existed for ages and the GUI had never heard
of it. The files are one target word per line; the path arrives in the stream as
`profileDir`, so this stays ignorant of pitcrew's layout.
"""

from __future__ import annotations

from pathlib import Path


def profile_names(profile_dir: str | None) -> list[str]:
    if not profile_dir:
        return []
    try:
        return sorted(p.name for p in Path(profile_dir).iterdir() if p.is_file())
    except OSError:
        return []                      # no profiles saved yet


def profile_targets(profile_dir: str | None, name: str) -> list[str]:
    if not profile_dir:
        return []
    try:
        text = (Path(profile_dir) / name).read_text(encoding="utf-8")
    except OSError:
        return []
    return [line.strip() for line in text.splitlines() if line.strip()]
