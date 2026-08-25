#!/usr/bin/env bash
# setup-rust.sh — take a bare machine to a working Rust pitcrew.
#
# Everything here is idempotent: run it again after a pull and it re-checks
# rather than re-does.
#
# It installs nothing privileged on its own. `--yes` opts into the package
# steps; without it they print the exact command they would run and continue,
# so you can read it, run it yourself, and come back.
#
# Deliberately bash 3.2 compatible. This is the script that runs on the machine
# that has nothing, and a setup script needing what it installs is no use there.
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${PITCREW_BIN_DIR:-$HOME/.local/bin}"
ASSUME_YES=0
WANT_GUI=1
DRY_RUN=0
PROBLEMS=0

usage() {
  cat <<'USAGE'
usage: ./setup-rust.sh [--yes] [--no-gui] [--dry-run]

  --yes       allow the package steps to install things (needs sudo on Linux).
              Without it they print what they would run and continue.
  --no-gui    command line only: skip the desktop app and its dev headers.
  --dry-run   report what is missing and stop. Installs nothing, builds nothing.
  --help

  PITCREW_BIN_DIR   where to install (default ~/.local/bin)

Safe to re-run.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)   ASSUME_YES=1; shift ;;
    --no-gui)   WANT_GUI=0; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --help|-h)  usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ── output ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$(printf '\033[1m'); R=$(printf '\033[0m')
                  G=$(printf '\033[32m'); Y=$(printf '\033[33m'); C=$(printf '\033[31m')
else B=""; R=""; G=""; Y=""; C=""; fi
step() { printf '\n%s%s%s\n' "$B" "$1" "$R"; }
ok()   { printf '  %sok%s    %s\n' "$G" "$R" "$1"; }
warn() { printf '  %swarn%s  %s\n' "$Y" "$R" "$1"; PROBLEMS=$((PROBLEMS + 1)); }
bad()  { printf '  %s✗%s     %s\n' "$C" "$R" "$1"; PROBLEMS=$((PROBLEMS + 1)); }
note() { printf '        %s\n' "$1"; }

# ── which package manager ───────────────────────────────────────────────────
# One case, one line per OS: this is the whole platform seam for dependencies.
detect_manager() {
  case "$(uname -s)" in
    Darwin) command -v brew >/dev/null 2>&1 && { echo brew; return; } ;;
    MINGW*|MSYS*) command -v pacman >/dev/null 2>&1 && { echo msys2; return; } ;;
  esac
  for m in dnf apt-get pacman zypper apk; do
    command -v "$m" >/dev/null 2>&1 || continue
    case "$m" in apt-get) echo apt ;; *) echo "$m" ;; esac
    return
  done
  echo ""
}
MANAGER=$(detect_manager)

# The compiler and pkg-config that any -sys crate needs to build at all.
build_packages_for() {
  case "$1" in
    dnf)    echo "gcc pkgconf-pkg-config" ;;
    apt)    echo "build-essential pkg-config" ;;
    pacman) echo "base-devel" ;;
    zypper) echo "gcc pkg-config" ;;
    apk)    echo "build-base pkgconf" ;;
    brew)   echo "" ;;   # the Xcode command line tools provide these
    msys2)  echo "mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-pkgconf" ;;
    *)      echo "" ;;
  esac
}

# GTK4 and libadwaita DEVELOPMENT headers. A separate install from the runtime
# libraries — a machine can run the Python app and still not build the Rust one.
gui_packages_for() {
  case "$1" in
    dnf)    echo "gtk4-devel libadwaita-devel" ;;
    apt)    echo "libgtk-4-dev libadwaita-1-dev" ;;
    # Arch ships headers with the library rather than in a -dev split.
    pacman) echo "gtk4 libadwaita" ;;
    zypper) echo "gtk4-devel libadwaita-devel" ;;
    apk)    echo "gtk4.0-dev libadwaita-dev" ;;
    brew)   echo "gtk4 libadwaita" ;;
    msys2)  echo "mingw-w64-ucrt-x86_64-gtk4 mingw-w64-ucrt-x86_64-libadwaita" ;;
    *)      echo "" ;;
  esac
}

install_command_for() { # $1 manager, $2 packages
  case "$1" in
    dnf)    echo "sudo dnf install -y $2" ;;
    apt)    echo "sudo apt-get install -y $2" ;;
    pacman) echo "sudo pacman -S --needed --noconfirm $2" ;;
    zypper) echo "sudo zypper install -y $2" ;;
    apk)    echo "sudo apk add $2" ;;
    brew)   echo "brew install $2" ;;
    msys2)  echo "pacman -S --needed --noconfirm $2" ;;
    *)      echo "" ;;
  esac
}

# Install a set, or say exactly what to run. Returns non-zero if it did not.
ensure_packages() { # $1 what, $2 packages
  local what=$1 packages=$2 cmd
  [ -n "$packages" ] || { ok "$what: nothing to install on this platform"; return 0; }
  if [ -z "$MANAGER" ]; then
    warn "$what: no known package manager — install by hand: $packages"
    return 1
  fi
  cmd=$(install_command_for "$MANAGER" "$packages")
  if [ "$ASSUME_YES" != 1 ]; then
    warn "$what: not installed, and --yes was not passed"
    note "run: $cmd"
    return 1
  fi
  note "$cmd"
  # Not `set -e`'d: a failed install should report and let the rest continue,
  # so one missing package does not hide everything else that is wrong.
  if sh -c "$cmd"; then ok "$what: installed"; return 0
  else bad "$what: that command failed"; return 1; fi
}

# ── 1. the rust toolchain ───────────────────────────────────────────────────
step "1/5  Rust toolchain"
if command -v cargo >/dev/null 2>&1; then
  ok "cargo $(cargo --version 2>/dev/null | awk '{print $2}')"
  # rustfmt and clippy are what `make rust` runs. Missing they are a broken
  # gate, not a broken build, so this warns rather than failing.
  for tool in fmt clippy; do
    if cargo "$tool" --version >/dev/null 2>&1; then ok "cargo $tool"
    else
      warn "cargo $tool is missing — \`make rust\` will not run"
      if command -v rustup >/dev/null 2>&1; then
        note "run: rustup component add ${tool/fmt/rustfmt}"
      else
        note "install your distro's ${tool/fmt/rustfmt} package"
      fi
    fi
  done
else
  bad "cargo is not installed"
  note "the official installer: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
  note "or your distro's rust/cargo package"
  note "rustup is preferred: it is the one that also gives you rustfmt and clippy"
fi

# ── 2. build prerequisites ──────────────────────────────────────────────────
step "2/5  Build prerequisites"
missing_build=""
command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 \
  || missing_build="no C compiler"
command -v pkg-config >/dev/null 2>&1 || command -v pkgconf >/dev/null 2>&1 \
  || missing_build="${missing_build:+$missing_build, }no pkg-config"
if [ -z "$missing_build" ]; then
  ok "a C compiler and pkg-config"
else
  warn "$missing_build — any -sys crate will fail to build"
  ensure_packages "build tools" "$(build_packages_for "$MANAGER")" || true
fi

# ── 3. the desktop app's headers ────────────────────────────────────────────
step "3/5  Desktop app"
HAVE_GUI_DEPS=0
if [ "$WANT_GUI" != 1 ]; then
  ok "skipped (--no-gui)"
else
  gtk_ok=0; adw_ok=0
  pkg-config --exists gtk4 2>/dev/null && gtk_ok=1
  pkg-config --exists libadwaita-1 2>/dev/null && adw_ok=1
  if [ "$gtk_ok" = 1 ] && [ "$adw_ok" = 1 ]; then
    ok "gtk4 $(pkg-config --modversion gtk4) · libadwaita $(pkg-config --modversion libadwaita-1)"
    HAVE_GUI_DEPS=1
  else
    # Worth naming: the runtime libraries and the headers are separate
    # packages, so "the Python app works here" is not evidence either way.
    warn "the GTK4/libadwaita DEVELOPMENT headers are missing"
    note "these are separate from the runtime libraries — the Python app can"
    note "work on a machine where the Rust one cannot be built"
    if ensure_packages "gtk4 headers" "$(gui_packages_for "$MANAGER")"; then
      pkg-config --exists gtk4 2>/dev/null && pkg-config --exists libadwaita-1 2>/dev/null \
        && HAVE_GUI_DEPS=1
    fi
  fi
  # libadwaita 1.5 is the floor: what Ubuntu 24.04 LTS ships. Older ones do not
  # degrade, they ABORT the process.
  if [ "$HAVE_GUI_DEPS" = 1 ]; then
    adw_version=$(pkg-config --modversion libadwaita-1 2>/dev/null || echo 0)
    adw_major=${adw_version%%.*}; adw_rest=${adw_version#*.}; adw_minor=${adw_rest%%.*}
    if [ "${adw_major:-0}" -lt 1 ] || { [ "$adw_major" = 1 ] && [ "${adw_minor:-0}" -lt 5 ]; }; then
      warn "libadwaita $adw_version is older than the 1.5 floor — the app will refuse to start"
      note "1.5 is what Ubuntu 24.04 LTS ships; older ones abort rather than degrade"
      HAVE_GUI_DEPS=0
    fi
  fi
fi

if [ "$DRY_RUN" = 1 ]; then
  step "Dry run"
  if [ "$PROBLEMS" = 0 ]; then
    ok "this machine is ready"
    exit 0
  fi
  # Non-zero when something is missing, so `--dry-run` is usable as a readiness
  # check in a provisioning script rather than only as something to read.
  printf '  %s%s thing(s) to sort out first%s\n' "$Y" "$PROBLEMS" "$R"
  exit 1
fi

# ── 4. build and install ────────────────────────────────────────────────────
step "4/5  Build and install"
if ! command -v cargo >/dev/null 2>&1; then
  bad "cannot build without cargo — see step 1"
else
  printf '        cargo build --release -p pitcrew-cli\n'
  if ( cd "$SELF_DIR" && cargo build --release --locked -p pitcrew-cli ); then
    mkdir -p "$BIN_DIR"
    # Copied, not symlinked: a release binary is one self-contained file with
    # no lib/ to find, and a copy survives the checkout being moved.
    install -m 0755 "$SELF_DIR/target/release/pitcrew" "$BIN_DIR/pitcrew"
    ok "pitcrew -> $BIN_DIR/pitcrew"
  else
    bad "the CLI did not build"
  fi

  if [ "$WANT_GUI" = 1 ] && [ "$HAVE_GUI_DEPS" = 1 ]; then
    printf '        cargo build --release -p pitcrew-gui\n'
    if ( cd "$SELF_DIR" && cargo build --release --locked -p pitcrew-gui ); then
      install -m 0755 "$SELF_DIR/target/release/pitcrew-gui" "$BIN_DIR/pitcrew-gui"
      ok "pitcrew-gui -> $BIN_DIR/pitcrew-gui"
    else
      bad "the desktop app did not build"
    fi
  elif [ "$WANT_GUI" = 1 ]; then
    warn "skipping the desktop app: its headers are not available"
  fi
fi

# ── 5. a way to launch it ───────────────────────────────────────────────────
step "5/5  Desktop entry"
if [ "$WANT_GUI" != 1 ] || [ ! -x "$BIN_DIR/pitcrew-gui" ]; then
  ok "skipped (no desktop app)"
else
  case "$(uname -s)" in
    Linux)
      apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
      icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
      mkdir -p "$apps" "$icons"
      [ -f "$SELF_DIR/gui/mn.zb.PitcrewGui.svg" ] \
        && cp "$SELF_DIR/gui/mn.zb.PitcrewGui.svg" "$icons/mn.zb.PitcrewGui.svg"
      cat > "$apps/mn.zb.PitcrewGui.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=pitcrew
Comment=Local dev-stack launcher
Exec=$BIN_DIR/pitcrew-gui
Icon=mn.zb.PitcrewGui
Terminal=false
Categories=Development;
StartupNotify=true
DESKTOP
      # Validated where the validator exists: a malformed entry is silently
      # ignored by the desktop rather than reported, which is the worst
      # possible failure mode for a thing you find by looking for it.
      if command -v desktop-file-validate >/dev/null 2>&1; then
        if desktop-file-validate "$apps/mn.zb.PitcrewGui.desktop"; then
          ok "desktop entry: $apps/mn.zb.PitcrewGui.desktop"
        else
          bad "the desktop entry is malformed — the desktop will ignore it silently"
        fi
      else
        ok "desktop entry: $apps/mn.zb.PitcrewGui.desktop"
      fi
      command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$apps" 2>/dev/null || true
      ;;
    Darwin)
      appdir="$HOME/Applications/pitcrew.app"
      mkdir -p "$appdir/Contents/MacOS"
      cat > "$appdir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>pitcrew</string>
  <key>CFBundleIdentifier</key><string>mn.zb.PitcrewGui</string>
  <key>CFBundleExecutable</key><string>pitcrew</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
      printf '#!/bin/sh\nexec "%s/pitcrew-gui" "$@"\n' "$BIN_DIR" \
        > "$appdir/Contents/MacOS/pitcrew"
      chmod +x "$appdir/Contents/MacOS/pitcrew"
      ok "app bundle: $appdir"
      ;;
    *)
      ok "no desktop entry on this platform — run pitcrew-gui directly"
      ;;
  esac
fi

# ── what to do next ─────────────────────────────────────────────────────────
step "Ready"
case ":$PATH:" in
  *":$BIN_DIR:"*) ok "$BIN_DIR is on your PATH" ;;
  *) warn "$BIN_DIR is not on your PATH"
     note "add to your shell rc:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

if [ -x "$BIN_DIR/pitcrew" ]; then
  note ""
  note "  pitcrew init <your repo>   look at it and write a config"
  note "  pitcrew                    the dashboard"
  note "  pitcrew doctor             is this machine able to run it"
fi

if [ "$PROBLEMS" != 0 ]; then
  printf '\n  %s%s thing(s) above want attention%s\n' "$Y" "$PROBLEMS" "$R"
  # Non-zero so this is usable in a provisioning script without a wrapper
  # deciding what counts as a failure.
  exit 1
fi
exit 0
