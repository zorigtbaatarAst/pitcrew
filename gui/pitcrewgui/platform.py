"""Every OS-specific decision in the GUI, in one file.

The same bargain lib/00-platform.sh strikes for the tool itself: nothing else
here knows what it is running on. Adding an OS should mean editing this file
and gui/install.sh, and nothing else.

What is deliberately NOT platform-varying:

  The config directory. macOS convention would put it under
  ~/Library/Application Support, and that would be wrong — the GUI has to read
  the SAME registry the `pitcrew` command writes, and pitcrew uses
  $HOME/.config/pitcrew on every OS with no branch (lib/15-registry.sh). A
  tidier path that disagreed with the CLI would be a bug, not good manners.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
from pathlib import Path

SYSTEM = platform.system()          # 'Linux' | 'Darwin' | 'Windows' | …
IS_MACOS = SYSTEM == "Darwin"
IS_WINDOWS = SYSTEM == "Windows"


def pitcrew_home() -> Path:
    """Where pitcrew keeps its registry — the same on every OS, on purpose."""
    return Path(os.environ.get("PITCREW_HOME", Path.home() / ".config" / "pitcrew"))


# ── finding the pitcrew CLI ─────────────────────────────────────────────────

def _cli_fallbacks() -> tuple[Path, ...]:
    """Where pitcrew's own install.sh puts the symlink when $PATH misses it.

    The app grid (and macOS Launchpad) start a process with a minimal
    environment that frequently lacks ~/.local/bin, which is install.sh's
    default target on both Linux and macOS.
    """
    home = Path.home()
    paths = [home / ".local" / "bin" / "pitcrew"]
    if IS_MACOS:
        # Homebrew's bin is not on a GUI-launched process's PATH either.
        paths += [Path("/opt/homebrew/bin/pitcrew"), Path("/usr/local/bin/pitcrew")]
    return tuple(paths)


def find_pitcrew() -> str | None:
    found = shutil.which("pitcrew")
    if found:
        return found
    for candidate in _cli_fallbacks():
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


# ── finding a bash the way pitcrew does ─────────────────────────────────────

def _bash_candidates() -> tuple[str, ...]:
    """$PATH first: pitcrew's macOS install note is "put brew's bash ahead of
    /bin/bash", so honouring $PATH honours what the user was told to do."""
    paths = ["bash"]
    if IS_MACOS:
        paths += ["/opt/homebrew/bin/bash", "/usr/local/bin/bash"]
    return tuple(paths)


def _bash_major(command: str) -> int:
    try:
        result = subprocess.run([command, "-c", "echo ${BASH_VERSINFO[0]}"],
                                capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return 0
    return int(result.stdout.strip()) if result.stdout.strip().isdigit() else 0


def bash5() -> str | None:
    """A bash 5+, or None.

    pitcrew refuses to run under anything older (bin/pitcrew), so validating a
    pitcrew config with an older bash would pass or fail for reasons pitcrew
    would never agree with. macOS still ships bash 3.2 as /bin/bash, which is
    exactly how you get a config the editor accepts and the tool rejects.
    """
    for candidate in _bash_candidates():
        resolved = shutil.which(candidate)
        if resolved is None and os.path.isabs(candidate) and os.access(candidate, os.X_OK):
            resolved = candidate
        if resolved and _bash_major(resolved) >= 5:
            return resolved
    return None


def missing_bash_message() -> str:
    if IS_MACOS:
        return ("no bash 5 found — macOS ships 3.2, which pitcrew refuses to run under.\n"
                "brew install bash, and put it ahead of /bin/bash on your PATH.")
    return "no bash 5 found on PATH — pitcrew needs bash 5.0 or newer."


# ── finding an interpreter that can actually import the GTK bindings ────────

def python_candidates() -> tuple[str, ...]:
    """Interpreters likely to have PyGObject, most likely first.

    The bindings belong to whichever python the OS package manager installed
    them for, which is rarely the first `python3` on $PATH — a Homebrew or
    pyenv python shadows the system one on Linux, and on macOS the system one
    is a stub with no bindings at all. Guessing wrong is an invisible failure:
    ModuleNotFoundError at launch, from a launcher with no terminal attached.
    """
    if IS_MACOS:
        return ("/opt/homebrew/bin/python3", "/usr/local/bin/python3", "python3")
    if IS_WINDOWS:
        return ("python3", "python")
    return ("/usr/bin/python3", "python3")


def missing_bindings_message() -> str:
    if IS_MACOS:
        return ("no python with the GTK bindings found.\n"
                "  brew install pygobject3 gtk4 libadwaita")
    if IS_WINDOWS:
        return ("no python with the GTK bindings found.\n"
                "  install MSYS2, then: pacman -S mingw-w64-ucrt-x86_64-python-gobject "
                "mingw-w64-ucrt-x86_64-libadwaita")
    return ("no python with the GTK bindings found.\n"
            "  fedora: sudo dnf install python3-gobject python3-cairo gtk4 libadwaita\n"
            "  debian: sudo apt install python3-gi python3-gi-cairo gir1.2-adw-1")
