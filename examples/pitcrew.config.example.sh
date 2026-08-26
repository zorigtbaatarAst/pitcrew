#!/usr/bin/env bash
# pitcrew.config.sh — example config, annotated with every supported variable.
#
# Drop a file like this at the root of your project as `pitcrew.config.sh`
# (or run `pitcrew init` to generate a starter one). pitcrew walks up from
# your current directory looking for it, so you can run `pitcrew` from any
# subdirectory — or run it from anywhere with `pitcrew -C <project dir>`.
# Everything below is optional except PITCREW_APPS and at least one *_CMD
# entry per app.
#
# This example models a small monorepo: "storefront" (Rails API + React
# frontend), "worker" (a backend-only queue processor, no frontend), and
# "admin" (a Next.js app with its own small Node API route, no separate
# backend process) — showing the asymmetric-role support.
#
# It's written with the raw per-app arrays below because that's what best
# shows the asymmetric-role model. For a monorepo where most apps follow the
# same pattern (same command shape, differing only by name/port), the
# `pitcrew_app` shorthand collects one app's whole config in a single call
# instead of scattering it across 5+ parallel arrays:
#
#   pitcrew_app storefront \
#     --be-cmd    "cd $ROOT/storefront && bundle exec rails s -p 4000" --be-port 4000 \
#     --fe-cmd    "cd $ROOT/storefront/frontend && npm run dev"        --fe-port 3000 \
#     --be-health "/health"
#
# The two styles freely mix in the same file — use whichever reads clearer
# for a given app. See PITCREW_APPS/*_CMD below for the equivalent written
# by hand.

# ── apps ──────────────────────────────────────────────────────────────────
# Ordered list of app names. Each app gets a "be" (backend) and/or "fe"
# (frontend) slot — a slot only exists if you set a *_CMD for it below.
PITCREW_APPS=(storefront worker admin)

# ── start commands ───────────────────────────────────────────────────────
# Plain shell command strings, run with CWD=$ROOT (the config's directory,
# or PITCREW_ROOT below). $ROOT is available here since it's set before this
# file is sourced.
declare -A PITCREW_BE_CMD=(
  [storefront]="cd $ROOT/storefront && bundle exec rails s -p 4000"
  [worker]="cd $ROOT/worker && bundle exec sidekiq"
)
declare -A PITCREW_FE_CMD=(
  [storefront]="cd $ROOT/storefront/frontend && { [ -d node_modules ] || npm install; } && npm run dev"
  [admin]="cd $ROOT/admin && { [ -d node_modules ] || npm install; } && npm run dev"
)
# worker has no PITCREW_FE_CMD entry → its frontend slot is simply absent
# (shows as "n/a" in the dashboard, never started, never counted as "down").
# admin has no PITCREW_BE_CMD entry → backend-only apps work the same way
# in reverse.

# ── ports (used for health checks, URL printing, and "is it up yet") ──────
declare -A PITCREW_BE_PORT=([storefront]=4000)
declare -A PITCREW_FE_PORT=([storefront]=3000 [admin]=3001)

# ── health checks (optional) ───────────────────────────────────────────────
# When set, pitcrew curls http://127.0.0.1:<port><path> and requires the body
# to contain "UP" (Spring Boot Actuator convention) before calling the
# component "up" instead of "starting". Omit for anything else — an open
# port is then enough.
declare -A PITCREW_BE_HEALTH_PATH=([storefront]="/health")

# Cosmetic suffix shown after the backend URL in `pitcrew urls` / doctor.
declare -A PITCREW_URL_PATH=([storefront]="/api")

# ── protected components (optional) ────────────────────────────────────────
# `pitcrew diagnose` will never PROPOSE stopping these to free memory, however
# idle they look. Not a lock — `pitcrew stop` still stops them — just a
# statement that they are load-bearing. They are still listed as protected, so
# a candidate missing from the list is never a mystery.
#
#   pitcrew_app storefront --be-cmd "..." --be-protected
#
# or by hand, keyed by component:
PITCREW_PROTECTED[be-storefront]=1

# ── docker dependencies ─────────────────────────────────────────────────────
PITCREW_DEPS=(postgres redis)
# Containers pitcrew will never stop, even with `pitcrew stop --deps` — use
# for anything holding state you don't want torn down by accident.
PITCREW_PROTECTED_DEPS=(postgres)
# Run once, best-effort, right after deps are (re)started — e.g. to init a
# replica set or wait for a healthcheck. Failures are ignored.
PITCREW_DEPS_READY_CMD='docker exec postgres pg_isready >/dev/null 2>&1'

# ── extra environment for every backend / frontend start command ──────────
# Prepended verbatim in front of the systemd-run invocation — set JAVA_HOME,
# credentials for local S3-alikes, whatever your processes need.
PITCREW_BE_ENV="RAILS_ENV=development"
PITCREW_FE_ENV=""

# ── RAM caps (systemd MemoryMax) and boot timeout ──────────────────────────
PITCREW_BE_MAX="4G"
PITCREW_FE_MAX="6G"
PITCREW_WAIT_SECS=180

# ── display ─────────────────────────────────────────────────────────────
PITCREW_PROJECT_NAME="Storefront"     # defaults to the project directory name
PITCREW_EMOJI="🛒"                    # defaults to 🏁

# ── stale detection (optional) ─────────────────────────────────────────────
# `pitcrew stale [--restart]` flags running components whose source changed
# since they started. Only checked for components with a watch dir — key by
# "be-app"/"fe-app" for one role, or just "app" to cover both. Space-separate
# multiple directories in one string.
declare -A PITCREW_WATCH_DIR=(
  [storefront]="$ROOT/storefront/app $ROOT/storefront/frontend/src"
  [worker]="$ROOT/worker/app"
)

# ── quick shells (optional) ─────────────────────────────────────────────────
# `pitcrew shell <name>` runs this command in your current terminal (a real
# foreground, interactive shell) — handy for a db shell, a REPL, whatever
# you reach for often.
declare -A PITCREW_SHELLS=(
  [db]="docker exec -it postgres psql -U postgres storefront_development"
  [redis]="docker exec -it redis redis-cli"
)

# ── project-specific doctor checks (optional) ───────────────────────────────
# Define this function and `pitcrew doctor` calls it after its own checks.
pitcrew_doctor_extra() {
  command -v bundle >/dev/null && ok "bundler present" || bad "bundler not found"
  [ -d "$ROOT/storefront/frontend/node_modules" ] \
    && ok "storefront frontend deps installed" \
    || warn "storefront frontend needs npm install (auto-runs on first start)"
}

# ── dashboard (optional; all of these are env vars too) ────────────────────
# PITCREW_REFRESH=0.5        # seconds between frames — fractions are fine
# PITCREW_GRAPH=braille      # block (default) | braille — 2 samples per cell
# PITCREW_HISTORY=240        # sparkline samples kept per component
# PITCREW_THEME=tokyonight   # default | tokyonight | rosepine | gruvbox | mono
# PITCREW_COLOR=truecolor    # truecolor | 16 | none — detected from $COLORTERM
# PITCREW_ICONS=nerd         # unicode (default) | nerd — needs a patched font
# PITCREW_NARROW_AT=110      # below this width, one component per row
# PITCREW_COMPACT_AT=24      # below this height, fold the gauges, drop the legend
# PITCREW_MICRO_AT=12        # below this height, title + table + keys and nothing else
# PITCREW_MOUSE=1            # click to select, click again to expand, wheel scrolls
#
# What the error radar (the ⚡ counter, and the `e` key) treats as an error.
# A Spring backend and a Vite frontend do not log failures the same way.
# PITCREW_ERROR_PATTERN='ERROR|FATAL|Exception|UnhandledRejection'
#
# How often the health endpoint above is probed, in seconds. Probes run in the
# background so a booting JVM can never stall a repaint, and back off to 3x
# this once a service reports UP.
# PITCREW_HEALTH_INTERVAL=5
# How long one probe may take before it counts as unanswered. A Spring Boot
# actuator that aggregates a database ping is slower than people expect —
# under this figure it is reported DOWN forever, which reads as a boot that
# never finishes.
# PITCREW_HEALTH_TIMEOUT=5
# PITCREW_DEP_INTERVAL=10    # how often `docker inspect` is run for deps

# ── crash handling (optional) ───────────────────────────────────────────────
# Bring crashed components back automatically, with exponential backoff and a
# budget so a service that crashes on a syntax error is not relaunched forever.
# Only active while the live dashboard is open — pitcrew has no daemon.
# PITCREW_RESTART=1
# PITCREW_RESTART_BACKOFF=2    # seconds before the first retry, doubling
# PITCREW_RESTART_MAX=5        # attempts before giving up (press r to retry)
# PITCREW_RESTART_RESET=60     # seconds up before the attempt budget resets
#
# Previous runs' logs to keep per component (<comp>.log.1, .log.2, ...).
# 0 restores the old behaviour of erasing the log on every restart.
# PITCREW_LOG_KEEP=2

# ── uncommon: point pitcrew at a project root other than this file's dir ───
# PITCREW_ROOT="$ROOT/.."
