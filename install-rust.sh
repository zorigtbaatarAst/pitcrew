#!/usr/bin/env bash
# install-rust.sh — put the Rust pitcrew on your PATH.
#
# Two ways in, and the difference matters:
#
#   * a downloaded release binary — one file, nothing to build, and the one
#     this script assumes by default
#   * a local `cargo build --release` — what you want while working on it
#
# The bash implementation installs through install.sh and the two can coexist:
# they are different binaries with the same name, so whichever is first on your
# PATH wins. That is deliberate during the port — `pitcrew --version` says
# which you have.
set -eu

BIN_DIR="${PITCREW_BIN_DIR:-$HOME/.local/bin}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC=""

usage() {
  cat <<'USAGE'
usage: install-rust.sh [--build] [<binary>]

  --build      cargo build --release first, and install that
  <binary>     install this file instead of looking for one

  PITCREW_BIN_DIR  where to install (default ~/.local/bin)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --build) SRC=build; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) SRC=$1; shift ;;
  esac
done

case "$SRC" in
  build)
    command -v cargo >/dev/null 2>&1 || { echo "cargo is not installed" >&2; exit 1; }
    ( cd "$SELF_DIR" && cargo build --release --locked -p pitcrew-cli )
    SRC="$SELF_DIR/target/release/pitcrew"
    ;;
  "")
    # Prefer a release build if one is already here; fall back to a debug one
    # so that a checkout somebody has only ever run `cargo test` in still works.
    for candidate in "$SELF_DIR/target/release/pitcrew" "$SELF_DIR/target/debug/pitcrew"; do
      [ -x "$candidate" ] && { SRC=$candidate; break; }
    done
    [ -n "$SRC" ] || { echo "no built binary found — run with --build" >&2; exit 1; }
    ;;
esac

[ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 1; }

mkdir -p "$BIN_DIR"
# Copied, not symlinked: a release binary is a single self-contained file with
# no lib/ to find, so there is nothing a link would keep in sync — and a copy
# survives the checkout being moved or deleted.
install -m 0755 "$SRC" "$BIN_DIR/pitcrew"
echo "installed $BIN_DIR/pitcrew"
"$BIN_DIR/pitcrew" --version

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH — add it in your shell rc, e.g.:"
     echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
