#!/usr/bin/env bash
# test/lint.sh — parse every script, then shellcheck if it is available.
#
# `bash -n` needs nothing installed and catches the syntax errors that would
# otherwise only surface when a rarely-taken branch runs. shellcheck is the
# real linter but is not a hard requirement: this tool has to stay runnable on
# a box where you cannot install anything, so a missing shellcheck is a notice,
# not a failure. CI installs it, so nothing is skipped there.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."

rc=0
echo "── parse check"
for f in bin/pitcrew install.sh lib/*.sh themes/*.sh test/*.sh; do
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
echo "── shellcheck"
# SC1090/SC1091: sourced paths are computed at runtime, by design.
# SC2034: lib files define variables consumed by other lib files.
shellcheck --shell=bash --exclude=SC1090,SC1091,SC2034 \
  bin/pitcrew install.sh lib/*.sh themes/*.sh || rc=1
[ $rc -eq 0 ] && printf '\033[32m✔ clean\033[0m\n'
exit $rc
