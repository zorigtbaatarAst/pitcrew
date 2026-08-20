# pitcrew — development tasks. The tool itself needs none of this to run.
.PHONY: help test lint check setup install install-gui gui-deps

help:
	@echo "make setup   fresh clone -> working tool (add YES=1 to install packages)"
	@echo "make test    run the test suite"
	@echo "make lint    parse-check everything, then shellcheck if installed"
	@echo "make check   lint + test (what CI runs)"
	@echo "make install symlink bin/pitcrew onto your PATH"
	@echo "make install-gui  install the desktop app (Linux .desktop / macOS .app)"
	@echo "make gui-deps     show what the desktop app needs on this OS (add YES=1 to install)"
	@echo
	@echo "make test T=meters   run only test files matching 'meters'"

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
