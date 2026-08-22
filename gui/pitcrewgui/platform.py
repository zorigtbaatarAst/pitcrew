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
import sys
from pathlib import Path, PureWindowsPath

SYSTEM = platform.system()          # 'Linux' | 'Darwin' | 'Windows' | …
IS_MACOS = SYSTEM == "Darwin"
# Not just == "Windows". MSYS2 ships two kinds of python: the mingw/ucrt builds
# are native Windows and report "Windows", but the msys one reports
# "MSYS_NT-10.0-22631" — and under that interpreter every Windows special case
# below silently switched off, which is a GUI that runs a bash script by path
# on an OS that has no shebangs.
IS_WINDOWS = SYSTEM == "Windows" or SYSTEM.startswith(("MSYS", "MINGW", "CYGWIN"))

# The checkout this file was installed from: <repo>/gui/pitcrewgui/platform.py.
REPO_ROOT = Path(__file__).resolve().parents[2]


# ── reporting a failure when there is nowhere to print it ───────────────────

def report_fatal(message: str) -> None:
    """Say something the user will actually see, console or not.

    The Windows shortcut runs pythonw.exe, which has NO stdout and NO stderr —
    CPython's print() returns silently when sys.stdout is None, so every
    startup failure (no bindings, no bash, no CLI) came out as a double-click
    that did nothing at all. A message box is the only channel a GUI-subsystem
    process has before it manages to open a window.
    """
    if sys.stderr is not None:
        print(f"pitcrew-gui: {message}", file=sys.stderr)
        return
    if not IS_WINDOWS:
        return                       # no console and no Windows: nothing to do
    try:
        import ctypes  # noqa: PLC0415  — only needed on this one path
        # MB_OK | MB_ICONERROR, and no owner window because there is not one yet.
        ctypes.windll.user32.MessageBoxW(None, message, "pitcrew-gui", 0x10)
    except Exception:                # noqa: BLE001 — a failed report must not
        pass                         # replace the failure it was reporting


# Deliberately NOT IS_WINDOWS. That question is "does this OS behave like
# Windows" and MSYS2's msys python answers yes; this one is "will subprocess
# accept creationflags", and on that interpreter — a Cygwin-style POSIX build —
# passing it raises ValueError: creationflags is only supported on Windows
# platforms. Which would break the launcher on the exact interpreter whose only
# job is to find a better one.
_TAKES_CREATIONFLAGS = sys.platform == "win32"


def no_window_kwargs() -> dict:
    """subprocess kwargs that keep a console from flashing on Windows.

    Every helper the GUI shells out to — bash, python -c, pitcrew check — is a
    console program. Started from pythonw, which has no console of its own,
    Windows gives each one a fresh console window: a black rectangle that
    appears and vanishes on a timer for as long as the app is open.
    """
    if not _TAKES_CREATIONFLAGS:
        return {}
    # 0x08000000 = CREATE_NO_WINDOW. Named rather than imported from subprocess
    # because the attribute only exists on Windows builds, and this module is
    # imported and unit-tested everywhere.
    return {"creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)}


def pitcrew_home() -> Path:
    """Where pitcrew keeps its registry — the same on every OS, on purpose."""
    return Path(os.environ.get("PITCREW_HOME", Path.home() / ".config" / "pitcrew"))


# ── finding the pitcrew CLI ─────────────────────────────────────────────────

def _cli_fallbacks() -> tuple[Path, ...]:
    r"""Where to look for the CLI when $PATH does not have it.

    The app grid (and macOS Launchpad, and a Windows shortcut) start a process
    with a minimal environment that frequently lacks ~/.local/bin, which is
    install.sh's default target everywhere.

    The FIRST fallback is the checkout this GUI was installed from. That is not
    a guess: gui/ and bin/ are siblings in the repo, so the CLI is always
    exactly there, on every OS, whatever $PATH and $HOME happen to say. It also
    fixes Windows outright, where the two disagree — MSYS2's bash has
    $HOME=C:\msys64\home\you and writes the shim under it, while the native
    python the shortcut runs reports Path.home() as C:\Users\you and found
    nothing. Every button in the app was dead for that reason alone.
    """
    home = Path.home()
    paths = [REPO_ROOT / "bin" / "pitcrew", home / ".local" / "bin" / "pitcrew"]
    if IS_MACOS:
        # Homebrew's bin is not on a GUI-launched process's PATH either.
        paths += [Path("/opt/homebrew/bin/pitcrew"), Path("/usr/local/bin/pitcrew")]
    if IS_WINDOWS:
        # MSYS2 and Git Bash keep separate home directories, and a shortcut
        # inherits neither's idea of one.
        paths += [Path(r"C:\msys64\home") / os.environ.get("USERNAME", "") / ".local" / "bin" / "pitcrew",
                  Path(r"C:\msys64\usr\local\bin\pitcrew"),
                  home / "AppData" / "Local" / "pitcrew" / "pitcrew"]
    return tuple(paths)


# ── running the CLI ─────────────────────────────────────────────────────────
# `pitcrew` is a bash script with a shebang. On Linux and macOS the kernel
# honours that and the path alone is executable. Windows has no shebang: handing
# CreateProcess a file starting with `#!` fails with "not a valid application",
# which from a GUI with no console attached is an app that simply does nothing
# when you click a button. So there the interpreter has to be named explicitly.
#
# One function builds every argv, and nothing else in the GUI constructs one —
# otherwise this would be right in the three places someone remembered and
# wrong in the fourth.

_BASH_FALLBACKS = (
    r"C:\msys64\usr\bin\bash.exe",
    r"C:\Program Files\Git\bin\bash.exe",
    r"C:\Program Files (x86)\Git\bin\bash.exe",
    r"C:\msys32\usr\bin\bash.exe",
)


def _is_wsl_stub(path: str) -> bool:
    r"""C:\Windows\System32\bash.exe is the WSL launcher, not a bash.

    It is on the Windows PATH of every machine with WSL enabled, and it is what
    `shutil.which("bash")` finds first from a Start Menu shortcut. Running the
    CLI through it would execute pitcrew inside a Linux VM against a filesystem
    that has none of the user's project in it — which fails in a way that reads
    like pitcrew being broken rather than like the wrong bash.

    PureWindowsPath, not Path: this only ever sees a Windows path, and on a
    POSIX Path a backslash is an ordinary character — so the whole thing would
    be one "part" and the check would quietly never fire. It would also be
    untestable anywhere but Windows, which is where it has to be right.
    """
    parts = PureWindowsPath(path).parts
    return len(parts) >= 2 and parts[-1].lower() == "bash.exe" and \
        parts[-2].lower() in {"system32", "sysnative", "syswow64"}


def find_bash() -> str | None:
    """The bash that will run the CLI, or None where one is not needed."""
    if not IS_WINDOWS:
        return None
    found = shutil.which("bash")
    if found and not _is_wsl_stub(found):
        return found
    for candidate in _BASH_FALLBACKS:
        if Path(candidate).is_file():
            return candidate
    # Nothing better than the WSL stub is still better than nothing: the spawn
    # will at least produce a message naming it.
    return found


def cli_argv(pitcrew: str, args: list[str] | tuple[str, ...] = ()) -> list[str]:
    """The argv for one pitcrew invocation, correct for this OS."""
    if not IS_WINDOWS:
        return [pitcrew, *args]
    bash = find_bash()
    # No bash found: return the plain argv anyway. The spawn will fail with a
    # message naming the file, which is a better diagnostic than this function
    # inventing one — and `find_pitcrew` will usually have failed first.
    return [bash, pitcrew, *args] if bash else [pitcrew, *args]


def find_pitcrew() -> str | None:
    found = shutil.which("pitcrew")
    if found:
        return found
    for candidate in _cli_fallbacks():
        # The executable bit is meaningless on Windows and os.access reports it
        # for anything readable, so testing it there proves nothing — but a
        # missing file still has to be skipped.
        if candidate.is_file() and (IS_WINDOWS or os.access(candidate, os.X_OK)):
            return str(candidate)
    return None


# ── finding a bash the way pitcrew does ─────────────────────────────────────

def _bash_candidates() -> tuple[str, ...]:
    """$PATH first: pitcrew's macOS install note is "put brew's bash ahead of
    /bin/bash", so honouring $PATH honours what the user was told to do."""
    paths = ["bash"]
    if IS_MACOS:
        paths += ["/opt/homebrew/bin/bash", "/usr/local/bin/bash"]
    if IS_WINDOWS:
        # find_bash() already knows which bash can run the CLI, and it is the
        # one that must validate a config too — including its refusal to hand
        # back the WSL launcher.
        found = find_bash()
        if found:
            paths.insert(0, found)
        paths += list(_BASH_FALLBACKS)
    return tuple(paths)


def _bash_major(command: str) -> int:
    try:
        result = subprocess.run([command, "-c", "echo ${BASH_VERSINFO[0]}"],
                                capture_output=True, text=True, timeout=5, check=False,
                                **no_window_kwargs())
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
        # MSYS2 keeps the GTK stack in a per-environment PREFIX, and the plain
        # `python` on the Windows PATH is a store stub or a python.org build
        # with no bindings at all. pythonw first: it is the same interpreter
        # without a console window attached, which is the difference between an
        # app and a script.
        #
        # $MINGW_PREFIX is set by whichever MSYS2 shell the user opened
        # (UCRT64, MINGW64, CLANG64), so it beats any guess — and it is the
        # only way to find an MSYS2 installed somewhere other than C:\msys64.
        found: list[str] = []
        prefix = os.environ.get("MINGW_PREFIX", "")
        for base in ([prefix] if prefix else []) + [
                r"C:\msys64\ucrt64", r"C:\msys64\mingw64", r"C:\msys64\clang64",
                r"C:\msys32\ucrt64", r"C:\msys32\mingw64"]:
            found += [str(Path(base) / "bin" / name)
                      for name in ("pythonw.exe", "python3.exe", "python.exe")]
        return (*found, "pythonw", "python3", "python")
    return ("/usr/bin/python3", "python3")


# The oldest libadwaita this app is known to work on. 1.5 is what Ubuntu 24.04
# LTS ships, and supporting the current LTS is worth more than any widget added
# since. Raising this is a decision, not an accident: check what the LTS has
# first, and remember that using a newer widget does not fail with an
# ImportError — GTK aborts the process, which from a Start Menu shortcut is an
# app that does nothing at all.
ADW_MINIMUM = (1, 5)


def adwaita_too_old() -> str:
    """A message naming the version found, or "" when it is new enough."""
    try:
        # Deferred on purpose, and not a style slip: this module is imported by
        # bootstrap.py BEFORE the bindings are known to exist — that is the
        # whole reason bootstrap can re-exec into an interpreter that has them.
        # A top-level `from gi.repository import Adw` here would make the file
        # unimportable in exactly the case it exists to handle.
        from gi.repository import Adw  # noqa: PLC0415
    except (ImportError, ValueError):
        return ""            # no bindings at all is a different question
    found = (Adw.MAJOR_VERSION, Adw.MINOR_VERSION)
    if found >= ADW_MINIMUM:
        return ""
    want = ".".join(str(part) for part in ADW_MINIMUM)
    have = ".".join(str(part) for part in found)
    return (f"libadwaita {want} or newer is needed; this system has {have}.\n"
            "  the terminal dashboard needs none of this — just run `pitcrew`")


def missing_bindings_message() -> str:
    if IS_MACOS:
        return ("no python with the GTK bindings found.\n"
                "  brew install pygobject3 gtk4 libadwaita")
    if IS_WINDOWS:
        return ("no python with the GTK bindings found.\n"
                "  install MSYS2 (https://www.msys2.org), open the UCRT64 shell, then:\n"
                "  pacman -S mingw-w64-ucrt-x86_64-python-gobject "
                "mingw-w64-ucrt-x86_64-gtk4 mingw-w64-ucrt-x86_64-libadwaita\n"
                "  then re-run: ./setup.sh")
    return ("no python with the GTK bindings found.\n"
            "  fedora: sudo dnf install python3-gobject python3-cairo gtk4 libadwaita\n"
            "  debian: sudo apt install python3-gi python3-gi-cairo gir1.2-adw-1")
