"""pitcrew's project registry, read without sourcing anything."""

from __future__ import annotations

import re
import shlex
from pathlib import Path

from .platform import pitcrew_home

def known_projects() -> list[str]:
    """Registered project names, read straight from the registry directory.

    Deliberately not parsed out of `pitcrew projects` — that output is themed,
    colourised and meant for a human, so scraping it would break the first time
    someone changed a glyph.
    """
    directory = pitcrew_home() / "projects"
    if not directory.is_dir():
        return []
    return sorted(p.stem for p in directory.glob("*.sh"))

def project_file(name: str) -> Path:
    return pitcrew_home() / "projects" / f"{name}.sh"

def declared_root(path: Path) -> Path | None:
    """PITCREW_ROOT out of a config file, without sourcing it.

    Mirrors `config_declared_root` in lib/02-config.sh: the value is written
    with printf %q, so it may be quoted or backslash-escaped.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("PITCREW_ROOT="):
            continue
        try:
            parts = shlex.split(stripped[len("PITCREW_ROOT="):])
        except ValueError:
            return None
        return Path(parts[0]).expanduser() if parts else None
    return None

_SOURCES_OWN_CONFIG = re.compile(r"^\s*(?:\.|source)\s+.*pitcrew\.config\.sh", re.M)

def project_config_path(name: str) -> Path:
    """The file that actually holds this project's config.

    A registry entry for a repo that ships its own `pitcrew.config.sh` only
    sets PITCREW_ROOT and sources it (see lib/15-registry.sh), so editing the
    stub would change nothing the tool reads. Follow the indirection to the
    file with the content in it.
    """
    entry = project_file(name)
    root = declared_root(entry)
    if root is not None:
        in_repo = root / "pitcrew.config.sh"
        try:
            if in_repo.is_file() and _SOURCES_OWN_CONFIG.search(entry.read_text(encoding="utf-8")):
                return in_repo
        except OSError:
            pass
    return entry

def current_project() -> str | None:
    marker = pitcrew_home() / "current"
    try:
        name = marker.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return name or None
