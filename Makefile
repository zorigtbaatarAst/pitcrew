# pitcrew — development tasks. The tool itself needs none of this to run.
.PHONY: help test lint check compare setup install install-gui gui-deps rust rust-test rust-lint rust-setup rust-install rust-gui rust-gui-check

help:
	@echo "make setup   fresh clone -> working tool (add YES=1 to install packages)"
	@echo "make test    run the test suite"
	@echo "make lint    parse-check everything, then shellcheck if installed"
	@echo "make check   lint + test (what CI runs)"
	@echo "make install symlink bin/pitcrew onto your PATH"
	@echo "make install-gui  install the desktop app (Linux .desktop / macOS .app / Windows shortcuts)"
	@echo "make gui-deps     show what the desktop app needs on this OS (add YES=1 to install)"
	@echo
	@echo "make test T=meters   run only test files matching 'meters'"
	@echo
	@echo "make rust      the Rust port: fmt check, clippy, tests"
	@echo "make rust-test the CLI test suite (the desktop app has its own)"
	@echo "make compare       does the Rust build agree with the bash one?"
	@echo "make rust-setup    fresh machine -> working Rust pitcrew (add YES=1)"
	@echo "make rust-install  build the release binary and put it on your PATH"
	@echo "make rust-gui      run the Rust desktop app (needs gtk4/libadwaita dev headers)"

test:
	@bash test/run.sh $(T)

lint:
	@bash test/lint.sh

check: lint test

setup:
	@./setup.sh $(if $(YES),--yes,)

install:
	@./install.sh

install-gui:
	@./gui/install.sh

# YES=1 opts in to running the privileged install; without it this only reports.
gui-deps:
	@./gui/install-deps.sh $(if $(YES),--yes,)

# ── the Rust port ───────────────────────────────────────────────────────────
# Runs alongside `make check`, not instead of it: both implementations are live
# until the port reaches parity. Needs rustfmt and clippy — on Fedora those are
# separate packages (`rustfmt`, `clippy`), or `rustup component add` elsewhere.
rust: rust-lint rust-test

# Build the release binary and put it on your PATH. The bash implementation
# installs through `make install` and the two coexist — whichever is first on
# your PATH wins, and `pitcrew --version` says which you have.
# Take a bare machine to a working Rust pitcrew: toolchain, build tools, GTK
# headers, both binaries, and a desktop entry. Add YES=1 to let it install
# packages; without it, it prints the exact command and continues.
# Does the Rust build agree with the bash one? Five checks against the
# fixtures, so it says the same thing on any machine.
compare:
	@bash test/compare.sh

rust-setup:
	@./setup-rust.sh $(if $(YES),--yes,)

rust-install:
	@./install-rust.sh --build

# The Rust desktop app. Needs the GTK4 and libadwaita DEVELOPMENT headers,
# which are a separate install from the runtime libraries the Python app uses:
#   Fedora  sudo dnf install gtk4-devel libadwaita-devel
#   Debian  sudo apt install libgtk-4-dev libadwaita-1-dev
#   macOS   brew install gtk4 libadwaita
rust-gui:
	@cargo run -p pitcrew-gui

# The desktop app's own gate, separate because it needs those headers.
rust-gui-check:
	@cargo clippy -p pitcrew-gui --all-targets -- -D warnings
	@cargo test -p pitcrew-gui

rust-test:
	@cargo test

rust-lint:
	@cargo fmt --all -- --check
	@cargo clippy --all-targets -- -D warnings
