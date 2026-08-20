#!/usr/bin/env bash
# gui/install.sh — put pitcrew-gui on your PATH and in the GNOME app grid.
#
# A GNOME app is three things that must agree: the binary, a .desktop file
# named for the app id, and an icon named for the app id. Get the names out of
# step and the Shell shows a generic cog and will not group the running window
# with its launcher — which is why the id appears here exactly once, as $APP_ID.
set -eu

APP_ID=mn.zb.PitcrewGui
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${1:-$HOME/.local/bin}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS_DIR="$DATA_DIR/applications"
ICON_DIR="$DATA_DIR/icons/hicolor/scalable/apps"

command -v /usr/bin/python3 >/dev/null 2>&1 || {
  echo "error: /usr/bin/python3 not found" >&2; exit 1; }

# The GTK bindings live in the SYSTEM python. A Homebrew or pyenv python earlier
# on $PATH has no `gi`, so check the interpreter the app actually shebangs into
# rather than whatever `python3` resolves to in this shell.
/usr/bin/python3 -c 'import gi, cairo' 2>/dev/null || {
  echo "error: missing GTK bindings for /usr/bin/python3" >&2
  echo "  sudo dnf install python3-gobject python3-cairo gtk4 libadwaita" >&2
  echo "  (debian/ubuntu: apt install python3-gi python3-gi-cairo gir1.2-adw-1)" >&2
  exit 1; }

mkdir -p "$BIN_DIR" "$APPS_DIR" "$ICON_DIR"
ln -sf "$SELF_DIR/pitcrew-gui" "$BIN_DIR/pitcrew-gui"

# Absolute Exec on purpose: the app grid launches with a minimal environment
# whose $PATH frequently does not include ~/.local/bin.
sed "s#@BIN@#$BIN_DIR/pitcrew-gui#" "$SELF_DIR/$APP_ID.desktop.in" > "$APPS_DIR/$APP_ID.desktop"
cp "$SELF_DIR/$APP_ID.svg" "$ICON_DIR/$APP_ID.svg"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$APPS_DIR/$APP_ID.desktop" || {
    echo "error: the generated .desktop is invalid (see above)" >&2; exit 1; }
fi
command -v gtk4-update-icon-cache >/dev/null 2>&1 &&
  gtk4-update-icon-cache -q -f -t "$DATA_DIR/icons/hicolor" 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 &&
  update-desktop-database "$APPS_DIR" 2>/dev/null || true

echo "linked  $BIN_DIR/pitcrew-gui -> $SELF_DIR/pitcrew-gui"
echo "desktop $APPS_DIR/$APP_ID.desktop"
echo "icon    $ICON_DIR/$APP_ID.svg"
echo
echo "It reads whichever project \`pitcrew use\` selected; pick another from the"
echo "header, or pin one with:  pitcrew-gui -p <name>"
