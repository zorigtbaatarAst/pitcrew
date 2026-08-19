# pitcrew — development tasks. The tool itself needs none of this to run.
.PHONY: help test lint check install

help:
	@echo "make test    run the test suite"
	@echo "make lint    parse-check everything, then shellcheck if installed"
	@echo "make check   lint + test (what CI runs)"
	@echo "make install symlink bin/pitcrew onto your PATH"
	@echo
	@echo "make test T=meters   run only test files matching 'meters'"

test:
	@bash test/run.sh $(T)

lint:
	@bash test/lint.sh

check: lint test

install:
	@./install.sh
