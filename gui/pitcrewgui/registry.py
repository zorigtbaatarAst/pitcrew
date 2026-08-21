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
    return sorted({p.stem for e in REGISTRY_EXTS for p in directory.glob(f"*.{e}")})

# Mirrors PITCREW_REGISTRY_EXTS in lib/15-registry.sh, most preferred first.
REGISTRY_EXTS = ("yaml", "yml", "sh")

def project_file(name: str) -> Path:
    """The registry entry for a project, whichever format it was written in."""
    directory = pitcrew_home() / "projects"
    for ext in REGISTRY_EXTS:
        candidate = directory / f"{name}.{ext}"
        if candidate.is_file():
            return candidate
    return directory / f"{name}.yaml"

def is_yaml(path: Path) -> bool:
    return path.suffix in (".yaml", ".yml")

def _yaml_root(text: str, path: Path) -> Path | None:
    for line in text.splitlines():
        if not line.startswith("root:"):
            continue
        value = line[len("root:"):].split(" #", 1)[0].strip().strip("\"'")
        if not value:
            return None
        root = Path(value).expanduser()
        return root if root.is_absolute() else (path.parent / root).resolve()
    return None

def _bash_root(text: str) -> Path | None:
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

def declared_root(path: Path) -> Path | None:
    """The project root out of a config file, without loading it.

    Mirrors `config_declared_root` in lib/02-config.sh. In the bash format the
    value is written with printf %q, so it may be quoted or backslash-escaped;
    in YAML it is a plain `root:` scalar, and a relative one is relative to the
    config file itself.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    return _yaml_root(text, path) if is_yaml(path) else _bash_root(text)

_SOURCES_OWN_CONFIG = re.compile(r"^\s*(?:\.|source)\s+.*pitcrew\.config\.sh", re.MULTILINE)
_INCLUDES_OWN_CONFIG = re.compile(r"^include:\s*(\S+)", re.MULTILINE)

def project_config_path(name: str) -> Path:
    """The file that actually holds this project's config.

    A registry entry for a repo that ships its own config only records the root
    and points at that file — `source` in the bash format, `include:` in YAML
    (see lib/15-registry.sh). Editing the stub would change nothing the tool
    reads, so follow the indirection to the file with the content in it.
    """
    entry = project_file(name)
    root = declared_root(entry)
    if root is None:
        return entry
    try:
        text = entry.read_text(encoding="utf-8")
    except OSError:
        return entry
    if is_yaml(entry):
        match = _INCLUDES_OWN_CONFIG.search(text)
        if match:
            target = Path(match.group(1).strip("\"'")).expanduser()
            target = target if target.is_absolute() else root / target
            if target.is_file():
                return target
        return entry
    in_repo = root / "pitcrew.config.sh"
    if in_repo.is_file() and _SOURCES_OWN_CONFIG.search(text):
        return in_repo
    return entry

def current_project() -> str | None:
    marker = pitcrew_home() / "current"
    try:
        name = marker.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return name or None
