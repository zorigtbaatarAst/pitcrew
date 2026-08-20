"""pitcrew-gui — a desktop front-end for pitcrew.

The GTK version pins live here so they are declared exactly once, before any
submodule reaches for gi.repository; PyGObject warns (and may load the wrong
version) if a namespace is imported without one.

They are guarded because this package must stay importable on an interpreter
that has no bindings at all — that is precisely the case bootstrap.py exists to
fix, and it cannot fix it if importing it fails first. Once bootstrap re-execs,
this runs again on an interpreter where the import succeeds.
"""

try:
    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
except ImportError:
    pass
