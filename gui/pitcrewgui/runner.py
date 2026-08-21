"""Talking to the pitcrew CLI: the live NDJSON stream and one-shot commands."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile

from gi.repository import Gio, GLib

from .platform import bash5, missing_bash_message


class LineReader:
    """Complete lines out of a pipe, without confusing a blank line for EOF.

    `Gio.DataInputStream.read_line_async` cannot express the difference. At end
    of stream it completes with `(b"", 0)` — and a BLANK LINE completes with
    `(b"", 0)` as well. There is no third value to tell them apart, so code
    built on it has to pick which bug to have:

      * treat the pair as EOF, and the reader stops dead at the first empty
        line. A starting Spring Boot or npm process emits one within its first
        dozen lines, so the log tail froze almost immediately and never
        recovered.
      * treat it as a line, and at real EOF the async read completes
        IMMEDIATELY, forever. Re-arming spins the main loop above GTK's redraw
        priority and the whole window stops painting.

    Raw byte reads have no such ambiguity: on a pipe, zero bytes means the
    writer is gone, and anything else is data. Splitting the lines here costs a
    few lines of code and removes the choice entirely.
    """

    CHUNK = 65536
    # A "line" longer than this is not a line. Flushed rather than buffered so
    # a process spewing binary cannot grow this without bound.
    MAX_PARTIAL = 1 << 20

    def __init__(self, stream, on_line, on_eof=None, cancellable=None,
                 priority: int = GLib.PRIORITY_DEFAULT):
        self._stream = stream
        self._on_line = on_line
        self._on_eof = on_eof
        self._cancel = cancellable
        self._priority = priority
        self._buffer = b""
        self._stopped = False

    def start(self) -> None:
        self._arm()

    def stop(self) -> None:
        self._stopped = True

    @property
    def running(self) -> bool:
        return not self._stopped

    def _arm(self) -> None:
        if self._stopped or (self._cancel is not None and self._cancel.is_cancelled()):
            return
        self._stream.read_bytes_async(self.CHUNK, self._priority, self._cancel, self._done)

    def _done(self, stream, result) -> None:
        try:
            data = stream.read_bytes_finish(result)
        except GLib.Error:
            self._finish()               # cancelled, or the pipe went away
            return
        if data is None or data.get_size() == 0:
            # Anything held back was a line with no terminator. It is still
            # output someone wants to see.
            if self._buffer:
                self._emit(self._buffer)
                self._buffer = b""
            self._finish()
            return
        self._buffer += data.get_data()
        parts = self._buffer.split(b"\n")
        self._buffer = parts.pop()
        for part in parts:
            self._emit(part)
        if len(self._buffer) > self.MAX_PARTIAL:
            self._emit(self._buffer)
            self._buffer = b""
        self._arm()

    def _emit(self, raw: bytes) -> None:
        self._on_line(raw.rstrip(b"\r").decode("utf-8", "replace"))

    def _finish(self) -> None:
        self._stopped = True
        if self._on_eof is not None:
            self._on_eof()


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
        # Raw pipes, not DataInputStreams: see LineReader for why a blank line
        # on either of these used to end the stream for good.
        self._out = LineReader(self._proc.get_stdout_pipe(), self._on_line,
                               cancellable=self._cancel)
        self._err = LineReader(self._proc.get_stderr_pipe(), self._on_stderr,
                               cancellable=self._cancel)
        self._out.start()
        self._err.start()
        self._proc.wait_check_async(None, self._on_exit)

    def stop(self) -> None:
        self._stopping = True
        for reader in (getattr(self, "_out", None), getattr(self, "_err", None)):
            if reader is not None:
                reader.stop()
        self._cancel.cancel()            # our side first, then the child's
        if self._proc:
            # SIGKILL, so no half-dead bash lingers holding the pipe. Its `sleep`
            # grandchild is orphaned but exits within one interval on its own,
            # and we have already stopped reading from it.
            self._proc.force_exit()

    def _on_line(self, raw: str) -> None:
        if not raw.strip():              # a blank line is not a malformed frame
            return
        try:
            self._on_state(json.loads(raw))
        except json.JSONDecodeError as error:
            # Never silently: a malformed frame means the contract broke.
            self._on_error(f"malformed state from pitcrew: {error}")

    def _on_stderr(self, raw: str) -> None:
        if raw.strip():
            self._stderr_tail = (self._stderr_tail + [raw.strip()])[-5:]

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

    def run_json(self, args: list[str], on_done) -> None:
        """A pitcrew command whose stdout is JSON, parsed off the main loop.

        Separate from `run` because that one MERGES stderr into stdout so a
        failure's explanation is visible — which is right for human output and
        fatal for a payload, since one config warning on stderr would land in
        the middle of the object. Here stderr is captured separately and only
        used to explain a failure.
        """
        launcher = Gio.SubprocessLauncher.new(
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE)
        launcher.setenv("NO_COLOR", "1", True)
        try:
            proc = launcher.spawnv([self._pitcrew, *args])
        except GLib.Error as error:
            on_done(None, f"could not run pitcrew: {error.message}")
            return

        def finished(p, result) -> None:
            try:
                _, out, err = p.communicate_utf8_finish(result)
            except GLib.Error as error:
                on_done(None, error.message)
                return
            try:
                on_done(json.loads(out or ""), "")
            except ValueError:
                # `diagnose` exits non-zero on a critical finding, so a bad exit
                # is not itself an error — unparseable output is.
                on_done(None, (err or "pitcrew produced no JSON").strip().splitlines()[-1:][0]
                        if (err or "").strip() else "pitcrew produced no JSON")

        proc.communicate_utf8_async(None, None, finished)

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
