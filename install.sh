#!/usr/bin/env bash
# install.sh — symlink bin/pitcrew onto your PATH.
set -eu

BIN_DIR="${1:-$HOME/.local/bin}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$BIN_DIR"

# A symlink under MSYS/Git Bash is a copy unless Developer Mode is on or
# MSYS=winsymlinks:nativestrict is set — and a COPY of bin/pitcrew cannot find
# its own lib/, because the launcher resolves lib/ relative to the real file.
# So write a two-line shim there instead: it is not a link, but it works, and
# it keeps working after a `git pull`.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    printf '#!/usr/bin/env bash\nexec "%s/bin/pitcrew" "$@"\n' "$SELF_DIR" > "$BIN_DIR/pitcrew"
    chmod +x "$BIN_DIR/pitcrew"
    echo "wrote $BIN_DIR/pitcrew -> $SELF_DIR/bin/pitcrew (a shim; Windows symlinks need Developer Mode)"
    ;;
  *)
    ln -sf "$SELF_DIR/bin/pitcrew" "$BIN_DIR/pitcrew"
    echo "linked $BIN_DIR/pitcrew -> $SELF_DIR/bin/pitcrew"
    ;;
esac

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH — add it in your shell rc, e.g.:"
     echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
