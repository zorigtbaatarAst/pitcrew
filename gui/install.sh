#!/usr/bin/env bash
# gui/install.sh — put pitcrew-gui on your PATH and wherever this OS lists apps.
#
# The bash half of the platform seam. Every OS-specific decision lives in the
# `case` below and in pitcrewgui/platform.py — the same bargain lib/00-platform.sh
# strikes for the tool itself. Adding an OS means adding a branch here, not
# sprinkling `uname` through the script.
#
#   Linux    XDG: a .desktop file and an icon in the hicolor theme
#   macOS    a .app bundle in ~/Applications (Launchpad and Spotlight read it)
#   Windows  a Start Menu shortcut, launched with pythonw so there is no
#            console window behind the app
#
# The GTK bindings are NOT checked against a hardcoded interpreter here: the
# launcher finds one at runtime (pitcrewgui/bootstrap.py), because the right
# python differs per machine, not just per OS.
set -eu

APP_ID=mn.zb.PitcrewGui
APP_NAME=pitcrew
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${1:-$HOME/.local/bin}"

case "$(uname -s)" in
  Darwin)               PLATFORM=macos ;;
  Linux)                PLATFORM=linux ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  *)                    PLATFORM=unknown ;;
esac

have_bindings() { # any interpreter that can import both counts
  local py
  for py in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 python3; do
    command -v "$py" >/dev/null 2>&1 || continue
    "$py" -c 'import gi, cairo' >/dev/null 2>&1 && { printf '%s' "$py"; return 0; }
  done
  return 1
}

mkdir -p "$BIN_DIR"
ln -sf "$SELF_DIR/pitcrew-gui" "$BIN_DIR/pitcrew-gui"
echo "linked  $BIN_DIR/pitcrew-gui -> $SELF_DIR/pitcrew-gui"

install_linux() {
  local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"
  local apps_dir="$data_dir/applications"
  local icon_dir="$data_dir/icons/hicolor/scalable/apps"
  mkdir -p "$apps_dir" "$icon_dir"

  # Absolute Exec on purpose: the app grid launches with a minimal environment
  # whose $PATH frequently does not include ~/.local/bin.
  sed "s#@BIN@#$BIN_DIR/pitcrew-gui#" "$SELF_DIR/$APP_ID.desktop.in" > "$apps_dir/$APP_ID.desktop"
  cp "$SELF_DIR/$APP_ID.svg" "$icon_dir/$APP_ID.svg"

  if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$apps_dir/$APP_ID.desktop" || {
      echo "error: the generated .desktop is invalid (see above)" >&2; exit 1; }
  fi
  command -v gtk4-update-icon-cache >/dev/null 2>&1 &&
    gtk4-update-icon-cache -q -f -t "$data_dir/icons/hicolor" 2>/dev/null || true
  command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$apps_dir" 2>/dev/null || true

  echo "desktop $apps_dir/$APP_ID.desktop"
  echo "icon    $icon_dir/$APP_ID.svg"
}

install_macos() {
  local bundle="$HOME/Applications/$APP_NAME.app"
  local macos_dir="$bundle/Contents/MacOS"
  local res_dir="$bundle/Contents/Resources"
  mkdir -p "$macos_dir" "$res_dir"

  # A launcher script rather than a symlink: macOS derives the process name and
  # the Dock entry from CFBundleExecutable, and a symlink out of the bundle
  # confuses that. exec keeps it one process, so the Dock icon tracks the app.
  cat > "$macos_dir/$APP_NAME" <<LAUNCHER
#!/bin/sh
# Launchpad starts apps with a minimal PATH; give the launcher the usual places
# to find both python and the pitcrew CLI itself.
PATH="\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH"
export PATH
exec "$SELF_DIR/pitcrew-gui" "\$@"
LAUNCHER
  chmod +x "$macos_dir/$APP_NAME"

  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$APP_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

  # An .icns needs Apple's iconutil. Without it the bundle still works and just
  # shows a generic icon — worth saying so rather than failing the install.
  if command -v iconutil >/dev/null 2>&1 && command -v rsvg-convert >/dev/null 2>&1; then
    local iconset; iconset=$(mktemp -d)/"$APP_NAME.iconset"
    mkdir -p "$iconset"
    local size
    for size in 16 32 128 256 512; do
      rsvg-convert -w $size -h $size "$SELF_DIR/$APP_ID.svg" -o "$iconset/icon_${size}x${size}.png"
      rsvg-convert -w $((size * 2)) -h $((size * 2)) "$SELF_DIR/$APP_ID.svg" \
        -o "$iconset/icon_${size}x${size}@2x.png"
    done
    iconutil -c icns "$iconset" -o "$res_dir/$APP_NAME.icns" 2>/dev/null || true
    rm -rf "$(dirname "$iconset")"
  else
    echo "note    no .icns built (needs iconutil + rsvg-convert) — generic icon"
  fi

  echo "bundle  $bundle"
}

# ── Windows ─────────────────────────────────────────────────────────────────
# A .lnk, because that is what the Start Menu reads. Building one needs
# PowerShell's WScript.Shell — there is no file format to write by hand.
#
# The shortcut targets pythonw.exe, not python.exe: the two are the same
# interpreter and the difference is a console window sitting behind the app for
# its whole life. That window is the single thing that makes a GTK app on
# Windows feel like someone's script rather than a program.
install_windows() {
  local start_menu ico target
  start_menu="$APPDATA/Microsoft/Windows/Start Menu/Programs"
  [ -d "$start_menu" ] || { echo "note    no Start Menu directory at $start_menu — skipped"; return 0; }

  target=$(have_bindings) || target=""
  if [ -z "$target" ]; then
    echo "note    no python with the GTK bindings yet — the shortcut would not run, so it is not written"
    return 0
  fi
  # pythonw is the same interpreter without a console. Prefer it where it sits
  # next to the one we found.
  case "$target" in
    *python3.exe) [ -f "${target%python3.exe}pythonw.exe" ] && target="${target%python3.exe}pythonw.exe" ;;
    *python.exe)  [ -f "${target%python.exe}pythonw.exe" ]  && target="${target%python.exe}pythonw.exe" ;;
  esac

  ico="$SELF_DIR/$APP_ID.ico"
  [ -f "$ico" ] || ico=""

  # The shortcut is built by a SCRIPT FILE rather than `powershell -Command`.
  # A .lnk needs five properties set on a COM object, and inlining that meant
  # bash quoting wrapped around PowerShell quoting wrapped around paths with
  # spaces in them — unreadable, and wrong in a way that writes a shortcut
  # pointing nowhere instead of failing.
  #
  # cygpath throughout: PowerShell wants Windows paths and everything here is
  # a POSIX one.
  local ps1; ps1=$(mktemp).ps1
  {
    printf '$s = (New-Object -ComObject WScript.Shell).CreateShortcut("%s")\n' "$(cygpath -w "$start_menu/$APP_NAME.lnk")"
    printf '$s.TargetPath = "%s"\n'        "$(cygpath -w "$target")"
    printf '$s.Arguments = %s\n'           "'\"$(cygpath -w "$SELF_DIR/pitcrew-gui")\"'"
    printf '$s.WorkingDirectory = "%s"\n'  "$(cygpath -w "$SELF_DIR")"
    printf '$s.Description = "pitcrew - local dev-stack launcher"\n'
    [ -n "$ico" ] && printf '$s.IconLocation = "%s"\n' "$(cygpath -w "$ico")"
    printf '$s.Save()\n'
  } > "$ps1"

  if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
       -File "$(cygpath -w "$ps1")" >/dev/null 2>&1; then
    echo "shortcut $start_menu/$APP_NAME.lnk"
  else
    echo "note    could not write the Start Menu shortcut (PowerShell refused) — run pitcrew-gui directly"
  fi
  rm -f "$ps1"
}

case "$PLATFORM" in
  linux)   install_linux ;;
  macos)   install_macos ;;
  windows) install_windows ;;
  *)     echo "note    $(uname -s) has no app-listing step yet — run pitcrew-gui directly" ;;
esac

if ! have_bindings >/dev/null; then
  # One place knows package names per OS, and it is not this file.
  echo
  echo "warning: no python here can import the GTK bindings yet." >&2
  echo "  see what this OS needs:  make gui-deps" >&2
  echo "  or install it:           make gui-deps YES=1" >&2
fi

echo
echo "It reads whichever project \`pitcrew use\` selected; pick another from the"
echo "header, or pin one with:  pitcrew-gui -p <name>"
