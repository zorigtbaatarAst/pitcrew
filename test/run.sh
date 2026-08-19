#!/usr/bin/env bash
# test/run.sh — run every test file and summarise.
#
# Each file runs in its OWN process. Loading a pitcrew config mutates a lot of
# globals (and `declare -A` at file scope is global), so sharing one shell
# across files would let state leak between them and turn a real failure into
# a mystery.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

FILTER=${1:-}
failed=() passed=0

for f in *_test.sh; do
  [ -e "$f" ] || { echo "no test files found"; exit 1; }
  [ -n "$FILTER" ] && [[ $f != *$FILTER* ]] && continue
  if bash "$f"; then passed=$((passed + 1)); else failed+=("$f"); fi
done

echo
if [ ${#failed[@]} -eq 0 ]; then
  printf '\033[32m✔ %d test file(s) passed\033[0m\n' "$passed"
  exit 0
fi
printf '\033[31m✗ %d passed, %d failed:\033[0m %s\n' "$passed" "${#failed[@]}" "${failed[*]}"
exit 1
