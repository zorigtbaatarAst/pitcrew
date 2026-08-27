#!/usr/bin/env bash
# ext/jvm/install.sh — put pitcrew-jvm on your PATH, and its plugin where
# pitcrew will find it.
#
# Both halves are optional and independent. The tool is useful on a box that
# has never heard of pitcrew, and pitcrew is useful without it; installing one
# does not commit you to the other.
set -eu

BIN_DIR="${1:-$HOME/.local/bin}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${PITCREW_PLUGIN_DIR:-${PITCREW_HOME:-$HOME/.config/pitcrew}/plugins}"

mkdir -p "$BIN_DIR"

# The launcher resolves lib/ relative to its own REAL path, walking symlinks by
# hand, so a link works and keeps working after a `git pull`.
#
# Not under MSYS/Git Bash, where a symlink silently becomes a COPY unless
# Developer Mode is on — and a copy of the launcher cannot find lib/ any more.
# Same problem, and the same two-line shim, as pitcrew's own install.sh.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    printf '#!/usr/bin/env bash\nexec "%s/bin/pitcrew-jvm" "$@"\n' "$SELF_DIR" > "$BIN_DIR/pitcrew-jvm"
    chmod +x "$BIN_DIR/pitcrew-jvm"
    echo "wrote   $BIN_DIR/pitcrew-jvm -> $SELF_DIR/bin/pitcrew-jvm (a shim; Windows symlinks need Developer Mode)"
    ;;
  *)
    ln -sf "$SELF_DIR/bin/pitcrew-jvm" "$BIN_DIR/pitcrew-jvm"
    echo "linked  $BIN_DIR/pitcrew-jvm -> $SELF_DIR/bin/pitcrew-jvm"
    ;;
esac

# ── the plugin ──────────────────────────────────────────────────────────────
#
# An older pitcrew shipped examples/plugins/jvm.sh, which registered a check of
# the same name from its own copy of the parsers. If one is still installed,
# overwriting it silently would be the wrong call twice over: the user might
# have edited it, and a plugin they did not ask us to touch is theirs.
if [ -e "$PLUGIN_DIR/jvm.sh" ] && [ ! -L "$PLUGIN_DIR/jvm.sh" ]; then
  echo
  echo "note: $PLUGIN_DIR/jvm.sh already exists and is not a link to this checkout."
  echo "      That is probably the old bundled example. Left alone — but leaving BOTH"
  echo "      installed registers jvm_check twice, so every finding appears twice."
  echo "      Remove it and re-run this, or pass --force to replace it:"
  echo "        rm $PLUGIN_DIR/jvm.sh && $0"
  case "${2:-}" in
    --force) rm -f "$PLUGIN_DIR/jvm.sh" ;;
    *)       exit 0 ;;
  esac
fi

mkdir -p "$PLUGIN_DIR"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) cp -f "$SELF_DIR/plugin/jvm.sh" "$PLUGIN_DIR/jvm.sh" ;;
  *)                    ln -sf "$SELF_DIR/plugin/jvm.sh" "$PLUGIN_DIR/jvm.sh" ;;
esac
echo "linked  $PLUGIN_DIR/jvm.sh -> $SELF_DIR/plugin/jvm.sh"

echo
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH — add it in your shell rc, e.g."
     echo "        export PATH=\"$BIN_DIR:\$PATH\""
     # The plugin looks on PATH and then in two fixed places. Telling someone
     # who chose their own BIN_DIR that "it will be found anyway" would be
     # false for exactly the people who read this line.
     if [ "$BIN_DIR" != "$HOME/.local/bin" ]; then
       echo "      The plugin searches PATH and ~/.local/bin only, so until then"
       echo "      point it at the tool explicitly:"
       echo "        export PITCREW_JVM_BIN=\"$BIN_DIR/pitcrew-jvm\""
     else
       echo "      The plugin looks in ~/.local/bin by name, so it works regardless."
     fi
     echo ;;
esac

if ! command -v jcmd >/dev/null 2>&1; then
  echo "note: jcmd is not on your PATH. It ships with the JDK, not the JRE —"
  echo "      without it pitcrew-jvm can still report RSS, threads and the cgroup"
  echo "      cap, but nothing about the heap."
  echo
fi

echo "try:    pitcrew-jvm"
echo "        pitcrew plugins"
