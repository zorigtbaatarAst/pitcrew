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
#   Windows  a Start Menu AND a Desktop shortcut, launched with pythonw so
#            there is no console window behind the app
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

# One file knows where a python with the bindings might be, on every OS —
# gui/pyfind.sh. Looking only in Unix places here is what left Windows with a
# desktop app that no documented sequence of commands could install.
# shellcheck source=gui/pyfind.sh
. "$SELF_DIR/pyfind.sh"

have_bindings() { pitcrew_find_python; }

mkdir -p "$BIN_DIR"
# Under MSYS/Git Bash `ln -s` writes a COPY unless Developer Mode is on, and a
# copy of pitcrew-gui cannot find the pitcrewgui/ package that has to sit next
# to it — the launcher resolves it from its own realpath. install.sh has always
# written a shim there for exactly this reason; this file had not, so `pitcrew-gui`
# on Windows died with ModuleNotFoundError.
if [ "$PLATFORM" = windows ]; then
  printf '#!/usr/bin/env bash\nexec "%s/pitcrew-gui" "$@"\n' "$SELF_DIR" > "$BIN_DIR/pitcrew-gui"
  chmod +x "$BIN_DIR/pitcrew-gui"
  echo "wrote   $BIN_DIR/pitcrew-gui -> $SELF_DIR/pitcrew-gui (a shim; Windows symlinks need Developer Mode)"
else
  ln -sf "$SELF_DIR/pitcrew-gui" "$BIN_DIR/pitcrew-gui"
  echo "linked  $BIN_DIR/pitcrew-gui -> $SELF_DIR/pitcrew-gui"
fi

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
# Two .lnk files — Start Menu and Desktop — because that is what "install an
# app" means here, and because a Start Menu entry alone is a program most
# people never find twice.
#
# The shortcut targets pythonw.exe, not python.exe: the two are the same
# interpreter and the difference is a console window sitting behind the app for
# its whole life. That window is the single thing that makes a GTK app on
# Windows feel like someone's script rather than a program.
#
# PowerShell resolves the folders ITSELF, through WScript.Shell.SpecialFolders,
# rather than this script building them out of $APPDATA. Three reasons, all of
# which were bugs here:
#   * $APPDATA is a WINDOWS path with backslashes, so `[ -d "$APPDATA/..." ]`
#     in bash is testing a filename that cannot exist. The Start Menu was
#     therefore never found and the install said so and gave up.
#   * OneDrive relocates the Desktop to %USERPROFILE%\OneDrive\Desktop on a
#     great many machines, and no hardcoded path is right on both.
#   * a redirected profile (a domain login) moves both.
install_windows() {
  local target ico ps1 out
  target=$(have_bindings) || target=""
  if [ -z "$target" ]; then
    echo "note    no python with the GTK bindings yet — a shortcut would not run, so none was written"
    echo "        install them first:  make gui-deps YES=1   (then: make install-gui)"
    return 0
  fi

  # pythonw is the same interpreter without a console. Prefer it where it sits
  # next to the one we found — which is why pyfind.sh returns an absolute path
  # and not the word "python3".
  case "$target" in
    *python3.exe) [ -f "${target%python3.exe}pythonw.exe" ] && target="${target%python3.exe}pythonw.exe" ;;
    *python.exe)  [ -f "${target%python.exe}pythonw.exe" ]  && target="${target%python.exe}pythonw.exe" ;;
    # Not fatal: Windows appends .exe to an extensionless target itself. Worth
    # saying, because it means pyfind fell all the way through to a bare name.
    *) echo "note    the interpreter found is $target — not an MSYS2 mingw python, so check the app opens" ;;
  esac

  ico="$SELF_DIR/$APP_ID.ico"
  [ -f "$ico" ] || ico=""

  if ! command -v powershell.exe >/dev/null 2>&1 && ! command -v pwsh.exe >/dev/null 2>&1; then
    echo "note    no PowerShell on PATH — cannot write a .lnk. Run pitcrew-gui from a shell instead."
    return 0
  fi
  local shell_exe=powershell.exe
  command -v powershell.exe >/dev/null 2>&1 || shell_exe=pwsh.exe

  # A SCRIPT FILE rather than `powershell -Command`: a .lnk needs five
  # properties set on a COM object, and inlining that meant bash quoting
  # wrapped around PowerShell quoting wrapped around paths with spaces in them
  # — unreadable, and wrong in a way that writes a shortcut pointing nowhere
  # instead of failing.
  #
  # cygpath throughout: PowerShell wants Windows paths and everything here is a
  # POSIX one.
  # ASCII only inside the PowerShell, deliberately: Windows PowerShell 5.1
  # reads a .ps1 with no BOM in the system ANSI codepage, not UTF-8, so a
  # nicely-typeset dash in a message comes out as mojibake on exactly the
  # machines least able to explain it.
  ps1=$(mktemp).ps1
  {
    printf '$ErrorActionPreference = "Stop"\n'
    printf '$shell = New-Object -ComObject WScript.Shell\n'
    printf '$target = "%s"\n'    "$(cygpath -w "$target")"
    printf '$argline = %s\n'     "'\"$(cygpath -w "$SELF_DIR/pitcrew-gui")\"'"
    printf '$workdir = "%s"\n'   "$(cygpath -w "$SELF_DIR")"
    printf '$icon = "%s"\n'      "${ico:+$(cygpath -w "$ico")}"
    cat <<'PS1'
foreach ($folder in @("Programs", "Desktop")) {
  $dir = $shell.SpecialFolders($folder)
  if (-not $dir) { Write-Output ("skip     " + $folder + " - Windows reports no such folder"); continue }
  $path = Join-Path $dir "pitcrew.lnk"
  try {
    $s = $shell.CreateShortcut($path)
    $s.TargetPath = $target
    $s.Arguments = $argline
    $s.WorkingDirectory = $workdir
    $s.Description = "pitcrew - local dev-stack launcher"
    if ($icon) { $s.IconLocation = $icon }
    $s.Save()
    Write-Output ("shortcut " + $path)
  } catch {
    # One failing folder must not cost the other: a locked-down Desktop is
    # common on a managed machine, and the Start Menu entry is the one that
    # matters most.
    Write-Output ("note     could not write " + $path + " - " + $_.Exception.Message)
  }
}
PS1
  } > "$ps1"

  out=$("$shell_exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
          -File "$(cygpath -w "$ps1")" 2>&1 | tr -d '\r') || true
  rm -f "$ps1"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    echo "note    PowerShell wrote no shortcut and said nothing — run pitcrew-gui from a shell instead"
  fi
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
