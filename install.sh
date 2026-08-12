#!/usr/bin/env bash
# install.sh — symlink bin/pitcrew onto your PATH.
set -eu

BIN_DIR="${1:-$HOME/.local/bin}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$BIN_DIR"
ln -sf "$SELF_DIR/bin/pitcrew" "$BIN_DIR/pitcrew"
echo "linked $BIN_DIR/pitcrew -> $SELF_DIR/bin/pitcrew"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH — add it in your shell rc, e.g.:"
     echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
