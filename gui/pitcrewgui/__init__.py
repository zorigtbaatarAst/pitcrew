"""pitcrew-gui — a desktop front-end for pitcrew.

The GTK version pins live here so they are declared exactly once, before any
submodule reaches for gi.repository; PyGObject warns (and may load the wrong
version) if a namespace is imported without one.

They are guarded because this package must stay importable on an interpreter
that has no bindings at all — that is precisely the case bootstrap.py exists to
fix, and it cannot fix it if importing it fails first. Once bootstrap re-execs,
this runs again on an interpreter where the import succeeds.

ValueError as well as ImportError. PyGObject raises ImportError when it is not
installed and ValueError when it IS but the typelib for a namespace is not —
which is the normal state of a headless machine with python3-gi pulled in by
something else. Catching only the first meant `import pitcrewgui.yamledit`,
which touches no GTK at all, died there: the pure-text editor's own test suite
could not run anywhere without a desktop.
"""

try:
    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
except (ImportError, ValueError):
    pass
