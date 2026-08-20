"""Re-exec into an interpreter that has the GTK bindings.

Pure stdlib on purpose: this runs BEFORE we know whether `gi` is importable,
so it cannot import anything from the rest of the package that needs it.

This replaces a hardcoded `#!/usr/bin/python3` shebang. That shebang was right
on one machine and wrong on the next: it is the system python on Fedora, a stub
with no bindings on macOS, and does not exist at all under MSYS2. Asking the
question at runtime is the only answer that travels.
"""

from __future__ import annotations

import os
import subprocess
import sys

GUARD = "PITCREW_GUI_REEXEC"


def _has_bindings(interpreter: str) -> bool:
    try:
        result = subprocess.run([interpreter, "-c", "import gi, cairo"],
                                capture_output=True, timeout=15, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def ensure_bindings(script: str, argv: list[str]) -> None:
    """Return if this interpreter can run the GUI; otherwise exec one that can.

    Exits with a per-OS install hint if none can, rather than letting the
    import blow up somewhere less explicable.
    """
    try:
        import cairo  # noqa: F401
        import gi  # noqa: F401
        return
    except ImportError:
        pass

    # One hop only. A candidate that imports `gi` in the probe but not for real
    # would otherwise re-exec forever, and a boot loop is worse than an error.
    if os.environ.get(GUARD):
        _die("the GTK bindings are still missing after switching interpreter")

    from .platform import missing_bindings_message, python_candidates

    for candidate in python_candidates():
        if os.path.realpath(candidate) == os.path.realpath(sys.executable):
            continue
        if not _has_bindings(candidate):
            continue
        os.environ[GUARD] = "1"
        try:
            os.execvp(candidate, [candidate, script, *argv])
        except OSError as error:
            _die(f"could not switch to {candidate}: {error}")
    _die(missing_bindings_message())


def _die(message: str) -> None:
    print(f"pitcrew-gui: {message}", file=sys.stderr)
    raise SystemExit(1)
