"""Talking to the pitcrew CLI: the live NDJSON stream and one-shot commands."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile

from gi.repository import Gio, GLib

from .platform import bash5, missing_bash_message


class Stream:
    """Owns the `pitcrew json --watch` child and turns its stdout into dicts.

    A long-lived child, not a poll loop: CPU% is a delta between consecutive
    snapshots, so only one process sampling repeatedly can report it. A GUI that
    ran `status --json` on a timer would get null cpu forever.
    """

    def __init__(self, pitcrew: str, project: str | None, interval: int, on_state, on_error):
        self._argv = [pitcrew]
        if project:
            self._argv += ["-p", project]
        self._argv += ["json", "--watch", "--interval", str(interval)]
        self._on_state = on_state
        self._on_error = on_error
        self._proc: Gio.Subprocess | None = None
        self._stderr_tail: list[str] = []
        self._stopping = False
        # Cancelled on stop(), so a stream belonging to a project the user has
        # already switched away from can never deliver one last frame into a
        # window that has moved on.
        self._cancel = Gio.Cancellable()

    def start(self) -> None:
        try:
            self._proc = Gio.Subprocess.new(
                self._argv,
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE,
            )
        except GLib.Error as error:
            self._on_error(f"cannot start pitcrew: {error.message}")
            return
        self._read(Gio.DataInputStream.new(self._proc.get_stdout_pipe()), self._on_line)
        self._read(Gio.DataInputStream.new(self._proc.get_stderr_pipe()), self._on_stderr)
        self._proc.wait_check_async(None, self._on_exit)

    def stop(self) -> None:
        self._stopping = True
        self._cancel.cancel()            # our side first, then the child's
        if self._proc:
            # SIGKILL, so no half-dead bash lingers holding the pipe. Its `sleep`
            # grandchild is orphaned but exits within one interval on its own,
            # and we have already stopped reading from it.
            self._proc.force_exit()

    def _read(self, stream: Gio.DataInputStream, handler) -> None:
        if self._stopping:
            return
        stream.read_line_async(GLib.PRIORITY_DEFAULT, self._cancel, handler)

    def _on_line(self, stream: Gio.DataInputStream, result) -> None:
        raw = self._finish_line(stream, result)
        if raw is None:                  # EOF or cancelled; _on_exit explains why
            return
        if raw.strip():                  # a blank line is not a malformed frame
            try:
                self._on_state(json.loads(raw))
            except json.JSONDecodeError as error:
                # Never silently: a malformed frame means the contract broke.
                self._on_error(f"malformed state from pitcrew: {error}")
        self._read(stream, self._on_line)

    def _on_stderr(self, stream: Gio.DataInputStream, result) -> None:
        raw = self._finish_line(stream, result)
        if raw is None:
            return
        if raw.strip():
            self._stderr_tail = (self._stderr_tail + [raw.strip()])[-5:]
        self._read(stream, self._on_stderr)

    def _finish_line(self, stream: Gio.DataInputStream, result) -> str | None:
        """One line, or None at end-of-stream.

        GIO reports EOF as a NULL *or empty* line — in PyGObject it is `b""`,
        never None — and an async read on a pipe that has hit EOF completes
        IMMEDIATELY, every time. Re-arming on that spins the main loop at
        G_PRIORITY_DEFAULT (0), which outranks GTK's redraw (G_PRIORITY_HIGH_IDLE
        + 20 = 120), so the window stops painting and the process pegs a core.
        That is what "switching project freezes the GUI" was: stop() killed the
        child, and the dead stream then starved the compositor.
        """
        try:
            data, length = stream.read_line_finish(result)
        except GLib.Error as error:
            if not self._stopping and not error.matches(
                    Gio.io_error_quark(), Gio.IOErrorEnum.CANCELLED):
                self._on_error(f"stream read failed: {error.message}")
            return None
        if data is None or length == 0:
            return None
        return data.decode("utf-8", "replace")

    def _on_exit(self, proc: Gio.Subprocess, result) -> None:
        if self._stopping:               # we killed it; that is not a failure
            return
        try:
            proc.wait_check_finish(result)
        except GLib.Error as error:
            detail = " — ".join(self._stderr_tail) if self._stderr_tail else error.message
            self._on_error(f"pitcrew stopped: {detail}")
            return
        self._on_error("pitcrew stopped unexpectedly")

class Runner:
    """One-shot pitcrew commands, run off the main loop with colour turned off.

    pitcrew's human output is themed escape codes; NO_COLOR is its documented
    way to turn that off (lib/01-core.sh), which beats stripping SGR sequences
    back out afterwards. stderr is merged in because a failure's explanation is
    the thing most worth showing.
    """

    def __init__(self, pitcrew: str):
        self._pitcrew = pitcrew

    @property
    def pitcrew(self) -> str:
        """The CLI this Runner drives — some checks shell out to it directly."""
        return self._pitcrew

    def run(self, args: list[str], on_done) -> None:
        launcher = Gio.SubprocessLauncher.new(
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_MERGE)
        launcher.setenv("NO_COLOR", "1", True)
        try:
            proc = launcher.spawnv([self._pitcrew, *args])
        except GLib.Error as error:
            on_done(False, f"could not run pitcrew: {error.message}")
            return
        proc.communicate_utf8_async(
            None, None, lambda p, r: self._finish(p, r, on_done))

    @staticmethod
    def _finish(proc: Gio.Subprocess, result, on_done) -> None:
        try:
            _, out, _ = proc.communicate_utf8_finish(result)
        except GLib.Error as error:
            on_done(False, error.message)
            return
        on_done(proc.get_successful(), (out or "").strip())

def yaml_config_error(pitcrew: str, text: str) -> str:
    """`pitcrew check` on a candidate YAML config: the message, or "" if it loads.

    The tool's own parser, not a second one written here: a GUI that accepted a
    file the CLI then refused would be the worst of both, and a YAML subset has
    exactly one authoritative definition (lib/18-yaml.sh).
    """
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False,
                                         encoding="utf-8") as handle:
            handle.write(text)
            probe = handle.name
    except OSError as error:
        return f"could not write a temporary file to check: {error}"
    try:
        result = subprocess.run([pitcrew, "check", probe], env={**os.environ, "NO_COLOR": "1"},
                                capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        return f"could not run pitcrew check: {error}"
    finally:
        try:
            os.unlink(probe)
        except OSError:
            pass
    if result.returncode == 0:
        return ""
    output = f"{result.stdout}\n{result.stderr}".replace(probe, "config")
    # `check` prints the path and a verdict line too; the middle is the reason.
    return "\n".join(line.strip() for line in output.splitlines()
                     if line.strip() and "not loadable" not in line).strip() or "pitcrew rejected it"

def bash_syntax_error(text: str) -> str:
    """`bash -n` on a candidate config: the message, or "" if it parses."""
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False,
                                         encoding="utf-8") as handle:
            handle.write(text)
            probe = handle.name
    except OSError as error:
        return f"could not write a temporary file to check: {error}"
    bash = bash5()
    if bash is None:
        os.unlink(probe)
        return missing_bash_message()
    try:
        result = subprocess.run([bash, "-n", probe],
                                capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        return f"could not run bash -n: {error}"
    finally:
        try:
            os.unlink(probe)
        except OSError:
            pass
    if result.returncode == 0:
        return ""
    return (result.stderr or "bash rejected it").replace(probe, "config").strip()
