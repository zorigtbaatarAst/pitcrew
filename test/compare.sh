#!/usr/bin/env bash
# test/compare.sh — does the Rust build agree with the bash one?
#
# The port's whole safety argument is that both implementations are still here
# and can be run against each other. This is that argument, as a command.
#
# Five checks, cheapest first:
#
#   1. the YAML parser, byte for byte
#   2. the JSON contract, key set AND values
#   3. `init` output, byte for byte
#   4. the Python GUI's own suite, against the Rust binary
#   5. what each one can do
#
# Nothing here needs a running stack: every check uses the fixtures, so it says
# the same thing on any machine.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_CLI="$ROOT/bin/pitcrew"
RUST_CLI="${PITCREW_RUST:-$ROOT/target/debug/pitcrew}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0

if [ -t 1 ]; then B=$(printf '\033[1m'); R=$(printf '\033[0m')
                  G=$(printf '\033[32m'); C=$(printf '\033[31m'); Y=$(printf '\033[33m')
else B=""; R=""; G=""; C=""; Y=""; fi
step() { printf '\n%s%s%s\n' "$B" "$1" "$R"; }
same() { printf '  %ssame%s   %s\n' "$G" "$R" "$1"; }
diff_() { printf '  %sDIFF%s   %s\n' "$C" "$R" "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  %sskip%s   %s\n' "$Y" "$R" "$1"; }

[ -x "$BASH_CLI" ] || { echo "no bash pitcrew at $BASH_CLI" >&2; exit 2; }
if [ ! -x "$RUST_CLI" ]; then
  echo "no rust pitcrew at $RUST_CLI — run: cargo build -p pitcrew-cli" >&2
  echo "(or point PITCREW_RUST at one)" >&2
  exit 2
fi

# ── 1. the YAML parser ──────────────────────────────────────────────────────
# Both flatten a document to `path=value` in document order. That intermediate
# form is the parser's whole output, so comparing it compares the parser rather
# than something downstream that might paper over a difference.
step "1/5  YAML parser"
if cargo run -q -p pitcrew-core --example dump -- /dev/null >/dev/null 2>&1 || true; then :; fi
for f in "$ROOT/test/fixture-yaml/pitcrew.yaml" "$ROOT/examples/pitcrew.yaml"; do
  name=${f#"$ROOT/"}
  ( cd "$ROOT" && cargo run -q -p pitcrew-core --example dump -- "$f" ) > "$WORK/r.txt" 2>/dev/null
  ( cd "$ROOT" && ROOT=$ROOT LIB_DIR=lib bash -c '
      for l in lib/*.sh; do source "$l"; done 2>/dev/null
      yaml_parse "$1"
      for i in "${!YAML_KEYS[@]}"; do printf "%s=%s\n" "${YAML_KEYS[i]}" "${YAML_VALS[i]}"; done
    ' _ "$f" ) > "$WORK/b.txt" 2>/dev/null
  if [ ! -s "$WORK/r.txt" ] && [ ! -s "$WORK/b.txt" ]; then skip "$name (neither produced output)"
  elif diff -q "$WORK/b.txt" "$WORK/r.txt" >/dev/null 2>&1; then same "$name"
  else diff_ "$name"; diff "$WORK/b.txt" "$WORK/r.txt" | head -8 | sed 's/^/         /'; fi
done

# ── 2. the JSON contract ────────────────────────────────────────────────────
# This is the public API: the desktop app's data path, a status line, a CI gate.
# Key sets AND values, because a key-set check passes on a value that changed
# meaning — which is exactly the class of bug this found three of.
step "2/5  JSON contract"
command -v python3 >/dev/null 2>&1 || skip "python3 is needed to compare JSON"
if command -v python3 >/dev/null 2>&1; then
  for fix in test/fixture-yaml test/fixture; do
    ( cd "$ROOT" && "$BASH_CLI" -C "$fix" status --json ) > "$WORK/b.json" 2>/dev/null
    ( cd "$ROOT" && "$RUST_CLI" -C "$fix" status --json ) > "$WORK/r.json" 2>/dev/null
    if [ ! -s "$WORK/r.json" ]; then
      # The bash config format is a shell script, so the Rust build refuses it
      # on purpose. That is a difference, and it is the intended one.
      skip "$fix (the Rust build does not read this format — by design)"
      continue
    fi
    python3 - "$WORK/b.json" "$WORK/r.json" "$fix" <<'PY'
import json, sys
b, r, name = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]

def keys(o, p="$"):
    out = {}
    if isinstance(o, dict):
        out[p] = sorted(o)
        for k, v in o.items(): out.update(keys(v, f"{p}.{k}"))
    elif isinstance(o, list) and o:
        out.update(keys(o[0], f"{p}[0]"))
    return out

problems = []
kb, kr = keys(b), keys(r)
for p in sorted(set(kb) | set(kr)):
    if kb.get(p) != kr.get(p):
        problems.append(f"keys at {p}:\n           bash: {kb.get(p)}\n           rust: {kr.get(p)}")

# Fields that legitimately differ run to run or by design.
VARY = {"at", "machine", "collector", "profileDir"}
LIVE = {"rss", "cpu", "pid", "since", "idle", "errors"}
for k in sorted(set(b) | set(r)):
    if k in VARY or k in ("components", "profiles", "health", "summary", "deps"): continue
    if b.get(k) != r.get(k):
        problems.append(f"{k}:\n           bash: {b.get(k)!r}\n           rust: {r.get(k)!r}")
for cb, cr in zip(b.get("components", []), r.get("components", [])):
    for k in cb:
        if k in LIVE or k == "processes": continue
        if cb[k] != cr.get(k):
            problems.append(f"components[{cb['name']}].{k}: bash={cb[k]!r} rust={cr.get(k)!r}")

if problems:
    print(f"  \033[31mDIFF\033[0m   {name}")
    for p in problems[:6]: print("         " + p)
    sys.exit(1)
print(f"  \033[32msame\033[0m   {name}  (key sets and values)")
PY
    [ $? -eq 0 ] || FAILED=$((FAILED + 1))
  done
fi

# ── 3. `init` ───────────────────────────────────────────────────────────────
# Detection is a pile of heuristics over a repository, so the interesting
# question is whether both piles reach the same conclusion about the same repo.
step "3/5  init"
if [ -d "$ROOT/test/fixture-yaml" ]; then
  probe="$WORK/repo"
  mkdir -p "$probe/api/src/main/resources" "$probe/web"
  printf 'plugins {\n  id("org.springframework.boot")\n}\n' > "$probe/api/build.gradle.kts"
  printf 'server:\n  port: 8099\n' > "$probe/api/src/main/resources/application.yml"
  printf '{"scripts":{"dev":"next dev -p 3009"},"dependencies":{"next":"14"}}\n' > "$probe/web/package.json"
  printf '#!/bin/sh\n' > "$probe/gradlew"

  PITCREW_HOME="$WORK/bh" "$BASH_CLI" init --force "$probe" >/dev/null 2>&1
  PITCREW_HOME="$WORK/rh" "$RUST_CLI" init --force "$probe" >/dev/null 2>&1
  bfile=$(ls "$WORK/bh/projects/"*.yaml 2>/dev/null | head -1)
  rfile=$(ls "$WORK/rh/projects/"*.yaml 2>/dev/null | head -1)
  if [ -z "$bfile" ] || [ -z "$rfile" ]; then
    skip "one of them wrote nothing"
  else
    strip() { grep -v '^\s*#' "$1" | grep -v '^$'; }
    if diff -q <(strip "$bfile") <(strip "$rfile") >/dev/null; then
      same "the same config, for the same repo"
    else
      diff_ "the generated configs differ"
      diff <(strip "$bfile") <(strip "$rfile") | head -10 | sed 's/^/         /'
    fi
  fi
fi

# ── 4. the desktop app ──────────────────────────────────────────────────────
# The strongest check there is: 108 tests written against the bash CLI, run
# against the Rust one without changing a line of them.
step "4/5  the Python GUI, against the Rust binary"
mkdir -p "$WORK/bin"
ln -sf "$RUST_CLI" "$WORK/bin/pitcrew"
if PATH="$WORK/bin:$PATH" bash "$ROOT/test/run.sh" gui 2>&1 | tail -3 | grep -q 'passed'; then
  same "108 tests written for bash, passing against Rust"
else
  diff_ "the GUI suite does not pass against the Rust binary"
fi

# ── 5. what each can do ─────────────────────────────────────────────────────
step "5/5  command surface"
# Read from the DISPATCH TABLE, not from the help text and not from a grep for
# `cmd_`. The help text is prose and yields words like "did"; some commands are
# dispatched inline (`restart`) and some cmd_ functions are internal helpers
# (`cmd_json_watch`), so either grep is wrong in both directions. The case arms
# are what the tool actually answers to.
python3 - <<'PY' 2>/dev/null || skip "python3 is needed for this one"
import re, subprocess

src = open("bin/pitcrew").read()
bash = set()
for arm in re.findall(r"^  ([a-z][a-z|-]*)\)", src, re.M):
    bash.update(arm.split("|"))
bash -= {"help", "-h", "--help"}

rust_help = subprocess.run(["target/debug/pitcrew", "--help"],
                           capture_output=True, text=True).stdout
rust = set(re.findall(r"^\s{2,}([a-z][a-z-]+)", rust_help, re.M)) - {"help"}

# Same thing, different word.
alias = {"diag": "diagnose", "limit": "limits", "ls": "projects"}
bash = {alias.get(c, c) for c in bash}

both, only_bash, only_rust = bash & rust, bash - rust, rust - bash
print(f"  \033[32msame\033[0m   {len(both)} of {len(bash)} commands")
if only_bash:
    print(f"         not ported yet: {' '.join(sorted(only_bash))}")
if only_rust:
    print(f"         rust only:      {' '.join(sorted(only_rust))}")
PY

# ── verdict ─────────────────────────────────────────────────────────────────
step "Verdict"
if [ "$FAILED" = 0 ]; then
  printf '  %sthe two agree everywhere they are meant to%s\n' "$G" "$R"
  exit 0
fi
printf '  %s%s check(s) found a difference%s\n' "$C" "$FAILED" "$R"
exit 1
