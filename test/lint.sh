#!/usr/bin/env bash
# test/lint.sh — parse every script, then shellcheck if it is available.
#
# `bash -n` needs nothing installed and catches the syntax errors that would
# otherwise only surface when a rarely-taken branch runs. shellcheck is the
# real linter but is not a hard requirement: this tool has to stay runnable on
# a box where you cannot install anything, so a missing shellcheck is a notice,
# not a failure. CI installs it, so nothing is skipped there.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

rc=0
echo "── parse check"
for f in bin/pitcrew install.sh lib/*.sh themes/*.sh test/*.sh examples/plugins/*.sh; do
  if bash -n "$f" 2>/dev/null; then
    printf '  \033[32m✓\033[0m %s\n' "$f"
  else
    printf '  \033[31m✗\033[0m %s\n' "$f"; bash -n "$f"; rc=1
  fi
done

echo
if ! command -v shellcheck >/dev/null 2>&1; then
  printf '\033[33m⚠\033[0m shellcheck not installed — skipping (dnf install ShellCheck / apt install shellcheck)\n'
  exit $rc
fi
# ── python ──────────────────────────────────────────────────────────────────
# The GUI had no static analysis at all until this was added, and ruff's first
# run found three undefined names — one of them a live NameError on the "add
# project" folder picker that no test could reach. Same deal as shellcheck: a
# missing ruff is a notice, not a failure, because pitcrew has to stay usable on
# a box where you cannot install anything. CI installs it.
if [ -d gui/pitcrewgui ]; then
  echo "── python"
  if command -v ruff >/dev/null 2>&1; then
    ( cd gui && ruff check . ) || rc=1
    [ $rc -eq 0 ] && printf '  \033[32m✓\033[0m ruff\n'
  elif [ -x "$HOME/.local/bin/ruff" ]; then
    ( cd gui && "$HOME/.local/bin/ruff" check . ) || rc=1
    [ $rc -eq 0 ] && printf '  \033[32m✓\033[0m ruff\n'
  else
    printf '\033[33m⚠\033[0m ruff not installed — skipping (pip install ruff)\n'
  fi
  echo
fi

echo "── shellcheck"
# SC1090/SC1091: sourced paths are computed at runtime, by design.
# SC2034: lib files define variables consumed by other lib files.
#
# --severity=warning is the point of the gate, not a way of lowering the bar.
# At `style` this reported 58 findings, 43 of them cosmetic, so `make lint`
# always failed — and a check that is always red is a check nobody reads. It
# had been hiding two real bugs (a case pattern that shadowed another, and a
# `local` reading the caller's variable). Anything at warning or above now
# fails; anything below is either fixed or annotated at the line with why.
# examples/plugins/ is linted too: a worked example that does not pass the
# project's own gate is not a worked example.
shellcheck --shell=bash --severity=warning --exclude=SC1090,SC1091,SC2034 \
  bin/pitcrew install.sh lib/*.sh themes/*.sh examples/plugins/*.sh || rc=1
[ $rc -eq 0 ] && printf '\033[32m✔ clean\033[0m\n'
exit $rc
