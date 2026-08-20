# pitcrew

A config-driven local dev-stack launcher for multi-service monorepos.

If your project is "N apps, each with a backend + frontend, plus a couple of
docker dependencies" and you're tired of hunting down which port is which,
or watching a service spin forever because nobody told you it actually
crashed — pitcrew gives you one command with a live dashboard, per-service
RAM/CPU meters, an error radar over the logs, and fzf menus to
start/stop/restart/inspect anything.

Every component is a plain background process — RAM-capped via
`systemd-run --user --scope` where systemd is available — with its output
captured to a log file and its pid tracked in a pidfile. No terminal
multiplexer, no session to attach to, nothing to configure beyond your own
project.

![status](https://img.shields.io/badge/status-early-yellow)

## Contents

- [Why](#why)
- [Platforms](#platforms)
- [Install](#install)
- [Projects](#projects)
- [What `init` works out for you](#what-init-works-out-for-you)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Config](#config)
- [Scripting it](#scripting-it)
- [Two projects, one machine](#two-projects-one-machine)
- [Starting in waves](#starting-in-waves)
- [RAM caps](#ram-caps)
- [Dashboard](#dashboard)
- [Desktop app](#desktop-app)
- [How it works](#how-it-works)
- [Not (yet) supported](#not-yet-supported)
- [When something dies](#when-something-dies)
- [What pitcrew runs](#what-pitcrew-runs)
- [Development](#development)
- [License](#license)

## Why

Most process launchers (`overmind`, `foreman`, `mprocs`, a `docker-compose`
stack) either assume one flat process list or assume everything is a
container. Real monorepos are messier: a handful of named apps, each with its
own backend + frontend, sharing a couple of infra dependencies, where you
usually only want *some* of them running, want to see which are actually
healthy (not just "the process didn't exit"), and want a RAM meter before
your laptop falls over running six JVMs and six Node processes at once.

## Platforms

Linux and macOS are both supported targets, tested on both in CI. Every
OS-specific decision lives in one file, `lib/00-platform.sh` — nothing else in
the tool knows what it is running on.

- **Linux** — reads everything out of `/proc` with bash builtins, so a
  dashboard frame forks *nothing*. With `systemd --user` (usually present)
  RAM caps are real: each component runs in its own `systemd-run --user
  --scope` with `MemoryMax`, enforced by the kernel.
- **macOS** — same features, same numbers, different plumbing: `lsof` for
  port lookups, one `ps` sweep per frame for process-tree RAM/CPU,
  `vm_stat` + `hw.memsize` for the system gauges, `kern.boottime` for the
  reboot check. A frame costs exactly two forks regardless of how many
  services you run.

  The one thing macOS cannot do is **enforce** a RAM cap — there is no cgroup
  equivalent, and `ulimit -v` is not honoured there. `PITCREW_BE_MAX` /
  `PITCREW_FE_MAX` remain budgets: the meters measure against them and
  `pitcrew doctor` warns when the stack does not fit in the machine, but a
  runaway process is not auto-killed. `doctor` says so plainly rather than
  letting the identical-looking meters imply otherwise.
- **Windows** — not supported natively, and not pretending to be: no bash 5,
  no `/dev/tcp`, no POSIX `ps`. Run pitcrew inside **WSL2**, where it sees a
  normal Linux userland and needs nothing special — including real RAM caps,
  since modern WSL2 distros run systemd by default. Under Git Bash / MSYS,
  `pitcrew doctor` tells you this instead of failing in pieces.

The portable collector is not a fallback that rots: `PITCREW_FORCE_COLLECTOR=ps`
runs it on Linux, and CI runs the whole suite that way on every push, so the
path macOS depends on is exercised even by people who never touch a Mac.

## Install

Requires **bash 5.0 or newer** (`$EPOCHREALTIME`, negative array indices and
`declare -gA` are used throughout; `pitcrew` checks this up front and tells you
rather than failing with a syntax error). macOS still ships bash 3.2, so there
you need `brew install bash` first — and make sure it is ahead of `/bin/bash`
on your `$PATH`.

Everything else is optional or already on the box. `docker` only if you
declare deps. `systemd --user` only for enforced RAM caps on Linux. `lsof` for
port lookups (present on macOS; falls back to `ss` on Linux). `fzf` is
optional but strongly recommended for the interactive menu. Nothing here needs
GNU coreutils — no `timeout`, no `readlink -f`, no GNU-only `sed`/`grep`
flags — so a stock macOS has what it needs after the bash upgrade.

```bash
git clone https://github.com/<you>/pitcrew ~/.local/share/pitcrew
cd ~/.local/share/pitcrew
./setup.sh            # or: ./setup.sh --yes   to let it install packages
```

`setup.sh` takes a fresh clone to a working tool on any OS, and is safe to
re-run after a pull:

1. **dependencies** — reports what this OS needs (`--yes` installs them)
2. **the command** — symlinks `bin/pitcrew` onto your `$PATH`
3. **the desktop app** — `.desktop` on Linux, `.app` on macOS; skipped cleanly
   if the GTK bindings are not there yet
4. **next** — checks `$PATH`, and tells you the one thing it cannot guess:
   which checkout you meant

It installs nothing privileged unless you pass `--yes`. `--no-gui` gets you the
command line only. `make setup` / `make setup YES=1` do the same.

Then point it at something:

```bash
pitcrew init ~/path/to/your/project   # look at it, write a config
pitcrew doctor                        # sanity-check what it guessed
pitcrew                               # the dashboard
```

If you would rather do it by hand, `install.sh` alone is the whole command-line
install — it just symlinks `bin/pitcrew` (default `~/.local/bin`):

```bash
ln -s "$(pwd)/pitcrew/bin/pitcrew" ~/.local/bin/pitcrew
```

## Projects

pitcrew keeps its own record of the projects it knows about, in
`~/.config/pitcrew/projects/`. You do not have to add a file to a repository
to use it — which matters for a repo you do not own, and for a config full of
your local paths, ports and JDK that has no business in version control.

```bash
pitcrew init ~/work/some-repo   # look at it, write a config, remember it
pitcrew projects                # what pitcrew knows about, and what is running
pitcrew use some-repo           # make it the current project
pitcrew                         # ...and just run, from anywhere
pitcrew -p other-repo status    # one command against a different one
pitcrew edit                    # open the current project's config in $EDITOR
pitcrew forget some-repo        # unregister it; the checkout is untouched
```

You can also switch without leaving the dashboard: press **`p`**, or pick
**switch project…** from the `m` menu. The picker previews each project's
root, app list and how many of its services are currently running.

Switching re-executes pitcrew against the new project rather than reloading in
place. That is deliberate: a config's bare `declare -A` is scoped to whatever
*function* sources it, so re-sourcing from inside a running dashboard would
silently discard the new project's arrays and leave you looking at one
project's components with another's ports. Re-exec cannot leave half-updated
state behind, and per-project history and error counters correctly start
fresh.

A project is found in this order — first hit wins:

1. `-C <dir>` — an explicit directory
2. `-p <name>` — a registered project by name
3. `$PITCREW_CONFIG`
4. a `pitcrew.config.sh` walked up from `$PWD`
5. a registered project whose root contains `$PWD`
6. whatever `pitcrew use` last selected

An **in-project `pitcrew.config.sh` outranks the registry**. A repo that ships
one is stating how it wants to be run, and that should not be silently
overridden by whatever happens to be registered on your machine. `pitcrew init
--in-project` writes one, for a team that all use pitcrew.

## What `init` works out for you

`pitcrew init` reads the repository rather than writing placeholders. It
finds apps in two shapes — `<app>/backend` + `<app>/frontend` at the top
level, and grouping directories (`apis/`, `apps/`, `packages/`, `services/`,
`modules/`) whose children are each an app — and skips the obvious noise
(`node_modules`, `build`, `target`, `dist`, `vendor`, `shared`, …).

For each component it works out:

| | |
|---|---|
| **toolchain** | gradle, maven, npm/yarn/pnpm/bun, go, cargo, django, python, ruby |
| **command** | the real one — `./gradlew :sales:backend:bootRun`, `npm run dev`, `go run ./...` |
| **port** | Spring's `server.port`, a port pinned in a `dev` script, or a framework default; anything left over gets the next free port |
| **role** | from the directory name, or from the framework (Next/Vite/Angular → frontend, everything else → backend) |
| **health** | `/actuator/health` when it sees Spring Boot |
| **watch dir** | the component's `src/`, for `pitcrew stale` |
| **deps** | services named in a `docker-compose.yml`, written out commented for you to confirm |

Run it against a six-app Gradle + Next monorepo and you get a config that
starts it. It is still a guess: the header says so, and `pitcrew edit` opens it.

## Quick start

1. Point pitcrew at a project once: `pitcrew init ~/work/your-repo`. It
   inspects the repo and writes a working config into
   `~/.config/pitcrew/projects/`. Correct anything it guessed wrong with
   `pitcrew edit`; the full annotated schema is in
   [`examples/pitcrew.config.example.sh`](examples/pitcrew.config.example.sh).
2. From anywhere inside that project — or from anywhere at all, once
   `pitcrew use <name>` has selected it — run:

```bash
pitcrew start          # bring everything up, with a live boot dashboard
pitcrew                # live dashboard (also the default with no args) — observes
                        # only, starts nothing on its own
pitcrew menu           # fzf menu for everything below
pitcrew logs           # in-place log viewer, Tab/←→ to switch services
pitcrew stop           # stop everything (deps stay up unless --deps)
```

## Commands

```
pitcrew                  live dashboard (default) — ↑↓ select · ⏎ process tree
                          l logs · e errors · r restart · s stop · m menu · q quit
                          observes only — nothing is started for you
                          (in logs: Tab/←→ switch · x stop · r restart · Enter full log)
pitcrew menu              interactive fzf menu
pitcrew start [all|backends|frontends|deps|@profile|<app>...]
pitcrew up                 start whatever isn't already running, then the live dashboard
pitcrew stop  [all|@profile|<app>...]     stops tool-managed AND external
pitcrew stop --deps                       also stop non-protected deps
pitcrew restart <app>...
pitcrew status                    one-shot dashboard
pitcrew watch                     same as bare `pitcrew` — live dashboard, no auto-start
pitcrew logs [<component>]        in-place log viewer
pitcrew stale [--restart]         apps whose code changed since they started
pitcrew profile save <name> <targets...> | list | rm <name>
pitcrew shell [<name>]            run a configured quick shell (PITCREW_SHELLS), foreground
pitcrew doctor                    check the local environment
pitcrew init [<dir>]              generate a starter pitcrew.config.sh (default: $PWD)
pitcrew theme [<name>]            list themes, or switch and remember (--reset to forget)
pitcrew urls | help

pitcrew -C <dir> <command>        run against <dir>'s project instead of walking up from $PWD
pitcrew --project <dir> <command> same as -C — <dir> may be the project root or the config file itself
```

A "target" is an app name (`sales`), a specific role (`be-sales`, `fe-sales`),
a group (`all`, `backends`, `frontends`, `deps`), or a saved `@profile`.

`pitcrew` with no arguments and `pitcrew watch` are the same thing — a live
dashboard that only observes. Nothing gets started unless you explicitly ask
for it with `pitcrew start` or `pitcrew up` (the latter starts whatever's
missing, then drops into the same dashboard — handy, but opt-in).

`-C`/`--project` let you run pitcrew against a project without `cd`-ing into
it first — handy for an alias like `alias autoland='pitcrew -C ~/workspace/autoland-management'`.
It must come before the subcommand and takes priority over `$PITCREW_CONFIG`
and the usual walk-up-from-`$PWD` search.

## Config

Full schema with comments:
[`examples/pitcrew.config.example.sh`](examples/pitcrew.config.example.sh).
Run `pitcrew init` to generate a starter file instead of copying by hand.

For an app that follows the usual pattern, `pitcrew_app <name> --be-cmd ...
--be-port ... [--fe-cmd ...] [--fe-port ...] [--url-path ...] [--be-health
...] [--watch-be ...] [--watch-fe ...]` sets everything for that app in one
call instead of an entry in each of the arrays below — the two styles mix
freely in the same config. Loading also runs a few sanity checks (typo'd app
name in a per-app array, an app with no be/fe command at all, two components
sharing a port, an unknown name in `PITCREW_PROTECTED_DEPS`) and prints a
warning, not a hard failure, when something looks off.

The short version — everything except `PITCREW_APPS` and start commands is
optional:

| Variable | Purpose |
|---|---|
| `PITCREW_APPS` | ordered list of app names |
| `PITCREW_BE_CMD[app]` / `PITCREW_FE_CMD[app]` | shell command to start that role; omit to skip the role for that app |
| `PITCREW_BE_PORT[app]` / `PITCREW_FE_PORT[app]` | port used for health checks + URLs |
| `PITCREW_BE_HEALTH_PATH[app]` | actuator-style `/health` path; omit to treat an open port as "up" |
| `PITCREW_URL_PATH[app]` | cosmetic API path suffix for `pitcrew urls` |
| `PITCREW_DEPS` / `PITCREW_PROTECTED_DEPS` | docker containers to start; ones never auto-stopped |
| `PITCREW_DEPS_READY_CMD` | best-effort command run once after deps start |
| `PITCREW_BE_ENV` / `PITCREW_FE_ENV` | env vars prepended to every start command for that role |
| `PITCREW_BE_MAX` / `PITCREW_FE_MAX` / `PITCREW_WAIT_SECS` | RAM caps and boot timeout |
| `PITCREW_PROJECT_NAME` / `PITCREW_EMOJI` | banner display |
| `PITCREW_WATCH_DIR[app]` | source dirs to watch for `pitcrew stale` |
| `PITCREW_SHELLS[name]` | named quick shells for `pitcrew shell <name>` |
| `pitcrew_doctor_extra()` | optional function — your own `pitcrew doctor` checks |
| `PITCREW_ROOT` | override the project root (defaults to the config file's directory) |

Env var overrides (higher precedence than the config file):
`PITCREW_CONFIG`, `PITCREW_ROOT`, `PITCREW_FE_MAX`, `PITCREW_BE_MAX`,
`PITCREW_WAIT`.

## Scripting it

The dashboard is for looking at. For everything else:

```bash
pitcrew status --json     # the whole state, for a status line or a CI gate
pitcrew json --watch      # the same object once per interval, as NDJSON
pitcrew wait sales --timeout 90   # block until it is up
pitcrew ps                # everything running, across every registered project
pitcrew ports             # every port every project claims, and any clashes
```

`wait` exits **0** when everything came up, **1** on timeout, **2** if something
crashed on the way — so a script can branch on it. A port served by a process
pitcrew did not start satisfies the wait by default *and says so*; `--strict`
refuses it, which is what CI wants when the question is whether **this** build
came up.

```bash
pitcrew status --json | jq -r '.summary | "\(.up) up, \(.crashed) crashed"'
```

Numbers that are not known come through as `null`, never `0` — a stopped
service has no RSS, and a status line should not plot a zero for it.

That includes **cpu**, which is a *delta* between two samples: a one-shot
`status --json` has nothing to subtract and reports `null`, not a `0` that a
consumer could not tell apart from an idle service. To get real cpu you need
one process sampling repeatedly, which is what `json --watch` is:

```bash
# one JSON object per line, forever; first line has null cpu, the rest are real
pitcrew json --watch --interval 5 | while read -r frame; do
  jq -r '"\(.summary.up) up  \(.summary.crashed) crashed"' <<<"$frame"
done
```

It exits quietly on SIGPIPE, so closing the reader is a normal way to stop it.

### The JSON contract

`status --json` has consumers now — the desktop app, status lines, CI gates — so
it is versioned and its whole key set is pinned by `test/output_test.sh`. A
renamed or dropped field fails there rather than in your dashboard.

| | |
|---|---|
| top level | `schema` `project` `root` `collector` `at` `logDir` `errorPattern` `machine` `components` `deps` `summary` |
| component | `name` `app` `role` `state` `port` `pid` `rss` `cpu` `errors` `exit` `limit` `limitSource` |
| machine | `memTotal` `memUsed` `cpuPercent` |
| dep | `name` `state` |
| summary | `up` `starting` `crashed` `external` `down` |

`schema` is **1**. Adding a field is backwards compatible and does not bump it;
removing one or changing what it means does. Bytes are bytes, `cpu` is an
integer percent, and anything unknown is `null` — never `0`.

`pitcrew doctor --json` is the same idea for the environment, and is a **gate**:
it exits non-zero when the caps do not fit the machine or ports clash with
another registered project, so CI can run it directly.

```bash
pitcrew doctor --json | jq -r '.capsWarning // "ok"'
```

## Two projects, one machine

pitcrew decides a component is up from its port. That is what lets it adopt a
service you started by hand — and it is also how two projects that both use
`8080` end up each reporting the other's services as their own. So:

- a port that is open while **our** pid is not alive is `◇ external`, not
  `● up`, and the summary counts it separately
- `pitcrew ports` shows the whole map and flags every clash
- `pitcrew doctor` fails the check if this project clashes with another
  registered one

`doctor` also checks that the RAM caps fit the machine.

## Starting in waves

`pitcrew up` used to launch every component at once. On a six-app monorepo that
is six Gradle daemons and six Next dev servers compiling against the same cores
— the machine is unusable for a minute, and it is often *slower* in wall-clock
terms than starting them in waves.

Components now queue: at most `PITCREW_START_CONCURRENCY` (default **3**) may be
`starting` at a time, and a slot frees as soon as one opens its port.

```bash
PITCREW_START_CONCURRENCY=6 pitcrew up   # a bigger machine
PITCREW_START_CONCURRENCY=0 pitcrew up   # all at once, as before
```

A component that never comes up would otherwise hold the queue forever, so a
slot is released after `PITCREW_START_SLOT_SECS` (default 45) regardless and the
dashboard reports it as still starting.

## RAM caps

Two numbers for a whole stack is the wrong shape once the stack is not uniform:
a Spring backend wants 8G and the cron worker beside it wants 512M, and giving
both 8G means the caps never bite and the OOM killer picks the victim instead.
A cap resolves through three layers, highest first:

| | where | for |
|---|---|---|
| per component | `~/.config/pitcrew/<session>/limits` | this machine |
| per app | `pitcrew_app api --be-max 2G` in the config | everyone on the project |
| per role | `PITCREW_BE_MAX` / `PITCREW_FE_MAX` | the default |

```bash
pitcrew limit                      # every component, its cap, and where it came from
pitcrew limit be-orders 3G         # override it here
pitcrew limit be-orders default    # and back
```

The top layer is a machine-local file rather than more config on purpose: **a
cap is a property of the machine, not the project.** 8G is generous on a 64G
workstation and suicidal on a 16G laptop, and two developers sharing a repo
should not be editing each other's numbers in git. The middle layer still
exists for a project that genuinely wants to say "this one is small" for
everybody.

Caps are applied when a component **starts**, so changing one under a running
service does nothing until it restarts — `pitcrew limit` says so when that is
the case. The cap also reaches `pitcrew status --json` as `limit` and
`limitSource`, so the dashboard, the preflight, systemd's `MemoryMax` and the
GUI are all reading one number.

### From the terminal

The dashboard colours the RAM figure by how close it is to the cap, which
answers "am I near it" but not "near what". `render ram cap` spells it out:

```bash
pitcrew render ram cap      # 1.0G/2G instead of 1.0G
pitcrew render ram value    # back to just the figure
```

It is an ordinary render setting, so it shows up in `pitcrew render` with a
swatch of both styles, and in the dashboard's **📈 graph & gauge style…**
picker, alongside graph/scale/gauge.

Changing a cap without leaving the dashboard is **🧠 RAM caps…** in the menu:
pick a component (with its current cap and where it came from), then a size.
`default` says what it would fall back to, so clearing an override is not a
guess.

In the desktop app it is **RAM caps…** in the menu: every component with its
effective cap and where that came from. It writes nothing itself — each change
goes through `pitcrew limit`, the same way adding a project goes through
`pitcrew init`. Sixteen backends at the
8G default commit 128G on a 31G box, at which point no cap ever fires and the
kernel's OOM killer picks the victim instead — better to be told.

## Dashboard

The live dashboard keeps a rolling history per component and draws it as a
sparkline where a single number used to be, so a leak looks like a leak
instead of a number that happens to be large today. Selecting a service and
pressing Enter expands its real process tree — the Gradle daemon, the `node`,
the `esbuild` — each with its own RAM and CPU.

**Height and colour answer two different questions.** The height of a graph is
where the sample sits in that service's own recent range: it answers *is this
moving?*, so a leak climbs off the baseline and a service holding steady stays
a flat line. Scaled from zero instead — or to the RAM cap — a busy service puts
every sample at the top of the scale and the graph saturates into a solid
block that says nothing except "this service exists". The colour carries the
other question, *how close to the cap am I*, and it is the same colour as the
RAM figure beside it, because it is the same question.

Both are settings, not verdicts — `pitcrew render`, or `m` → **graph & gauge
style** in the menu, with a live swatch of every option:

| Setting | Values | |
|---|---|---|
| `graph` | `block` · `braille` · `bar` | one cell per sample · two samples per cell · no history, just how full the cap is |
| `scale` | `range` · `cap` | height is movement · height is absolute against the RAM cap |
| `gauge` | `bar` · `graph` | the CPU/RAM gauges as loading bars · as history |

Choices are remembered in `~/.config/pitcrew/render`, and resolve the same way
the theme does: the environment beats the project's config, which beats your
saved preference, which beats the default.

```bash
pitcrew render                  # every setting, every option, drawn
pitcrew render graph braille    # switch, and remember it
pitcrew render --reset          # back to the defaults
```

**The frame fits the window, whatever the window is, and reflows the moment
it changes.** Auto-wrap is off, so a row one column too wide is eaten silently
by the terminal and a frame one row too tall scrolls the alt screen and
corrupts every repaint after it. The layout is therefore a function of the
real terminal size, re-measured on every `SIGWINCH` and on every return from a
pager or an `fzf` menu — the two places a resize can happen behind the
dashboard's back.

The width tiers, and what each one gives up:

| Tier | Columns | Row |
|---|---|---|
| `xl` | ≥ 160 | two cells; the graph and the name column stop growing — a wide window buys more history, not a row that sprawls |
| `lg` | ≥ `PITCREW_NARROW_AT` (110) | backend and frontend side by side |
| `md` | ≥ ~62 | one component per row, with its sparkline — one readable cell beats two squeezed ones |
| `sm` | ≥ ~46 | no sparkline. History is cheap to lose; "which port, how much RAM" is not |
| `xs` | below that | the cascade continues into the numbers: the error count goes, then CPU, then RAM, each buying columns back for the name. A 30-column split still says which service is on which port |

Vertically, a short pane folds the CPU/RAM gauges onto one line and drops the
legend (`PITCREW_COMPACT_AT`), and a really short one — a tmux split, a
terminal tucked under an editor — keeps only the title, the table and the key
hints (`PITCREW_MICRO_AT`). The key hints are pinned to the bottom row at
every size, so they stay where your eye already is instead of drifting down
the screen as services start. The service list scrolls with the selection
instead of stopping at the bottom, and says how many rows are above and below
it.

Under all of that sits one guard: every row of the finished frame is cut to
the terminal's width before it is painted, colour sequences skipped and closed
off at the cut. A layout mistake costs you a truncated row, never a corrupted
screen.

**Actions never leave the dashboard.** Starting, stopping or restarting from
the menu (`m`) closes the picker and returns you to the live view, where you
watch components go `○ down → ◐ starting → ● up` in place; a one-line toast
says what was triggered. The dashboard is the only surface — nothing prints
over it. `pitcrew start` on the command line is unchanged and still prints its
boot report, failure log tails and URL table.

| Key | |
|---|---|
| `↑` `↓` | select a service (mouse click also selects, when enabled) |
| `p` | switch to another registered project |
| `space` | mark a service; `a` `s` `r` then act on the marked set |
| `/` | filter by name — the list narrows as you type |
| `o` | cycle sort: name → state → ram → cpu |
| `x` | clear marks, filter and sort |
| `⏎` | expand/collapse that service's process tree |
| `e` | the error radar's actual matched log lines, not just the count |
| `l` `r` `s` `m` `q` | logs · restart · stop · menu · quit |
| `m` → 🌈 / 📈 | change theme · change graph & gauge style, both with live swatches |

| Variable | Default | Purpose |
|---|---|---|
| `PITCREW_REFRESH` | `1` | seconds between frames; fractions like `0.25` are fine |
| `PITCREW_GRAPH` | `block` | `block` (▁▂▃), `braille` (⣀⣤⣶) which packs 2 samples per cell, or `bar` |
| `PITCREW_GRAPH_SCALE` | `range` | `range` (height is movement) or `cap` (absolute against the RAM cap) |
| `PITCREW_GAUGE` | `bar` | the system CPU/RAM gauges: `bar` (a loading bar) or `graph` (history) |
| `PITCREW_RENDER_FILE` | `~/.config/pitcrew/render` | where `pitcrew render` remembers those three |
| `PITCREW_HISTORY` | `240` | samples kept per component |
| `PITCREW_THEME` | `default` | `default` (Catppuccin Mocha), `tokyonight`, `rosepine`, `gruvbox`, `mono`, or your own |
| `PITCREW_THEME_FILE` | `~/.config/pitcrew/theme` | where `pitcrew theme <name>` remembers your choice |
| `PITCREW_COLOR` | auto | `truecolor` / `16` / `none` — detected from `$COLORTERM`, override to force |
| `PITCREW_ICONS` | `unicode` | `nerd` adds language and docker glyphs (needs a patched font) |
| `PITCREW_NARROW_AT` | `110` | below this width, one component per row instead of two columns |
| `PITCREW_XL_AT` | `160` | above this width the table stops growing (it is already at its caps) |
| `PITCREW_COLS` / `PITCREW_LINES` | auto | pin the frame size instead of measuring the terminal — for recordings, screenshots and scripts |
| `PITCREW_COMPACT_AT` | `24` | below this height, the gauges fold onto one line and the legend goes |
| `PITCREW_MICRO_AT` | `12` | below this height, only the title, the table and the key hints survive |
| `PITCREW_MOUSE` | `0` | `1` enables click-to-select / click-again-to-expand / wheel |
| `PITCREW_ERROR_PATTERN` | `ERROR\|FATAL\|Exception\|UnhandledRejection` | what the error radar counts |
| `PITCREW_HEALTH_INTERVAL` | `5` | seconds between health probes (×3 once a service reports UP) |
| `PITCREW_DEP_INTERVAL` | `10` | seconds between docker dep checks |

`NO_COLOR` (or `PITCREW_NO_COLOR`) drops every colour.

```bash
pitcrew theme              # every theme, drawn in its own colours
pitcrew theme tokyonight   # switch, and remember it for next time
pitcrew theme --reset      # forget the saved choice
```

Or press `m` in the dashboard and pick **change theme…** — the fzf preview
draws each palette as you move through the list, and choosing one applies it
immediately and remembers it.

Four settings decide the theme, most specific first: `PITCREW_THEME` in the
environment (a one-off for this run), `PITCREW_THEME` in the project's
`pitcrew.config.sh` (so a repo can look the same for everyone who opens it),
the saved preference from `pitcrew theme <name>` (how you like your terminal),
and finally the built-in palette.

Colours are addressed by **role**, not by hue — `C_CRIT`, `C_MUTED`,
`C_SURFACE` rather than `RED`, `GREY`. A theme is still a plain bash file, and
it sets nothing but hex values; pitcrew converts them to 24-bit, to the 16
ANSI colours, or to nothing at all depending on what the terminal reports. One
theme file therefore works everywhere, including an old ssh target. See
[`themes/default.sh`](themes/default.sh) — five lines.

Graphs are coloured by each cell's **height**, cool at the bottom to hot at
the top, so a climb is legible before you read a number. Height auto-scales to
the series; how close a service is to its configured RAM cap moves to the
colour of the number, which is where you look for it anyway.

## Desktop app

`gui/` is a GTK4 / libadwaita front-end, laid out like GNOME System Monitor: a
component list, a Resources view of live CPU and memory graphs, and a Projects
view that manages the registry.

```bash
make install-gui     # symlink, plus whatever this OS uses to list apps
pitcrew-gui          # or launch "pitcrew" from the app grid / Launchpad
```

| | |
|---|---|
| **Linux** | a `.desktop` entry and a hicolor icon, per XDG |
| **macOS** | a `.app` bundle in `~/Applications`, for Launchpad and Spotlight |
| **Windows** | not yet — the launcher and package are ready, the install step is not |

macOS support is **written but untested** — there is no Mac here to run it on.
The parts that were Linux-only have been fixed (see the seam below); what
remains unverified is how well GTK4 and libadwaita themselves behave on
quartz. Expect it to work and to look distinctly non-native.

### Structure

```
gui/pitcrew-gui           launcher: find an interpreter with the bindings, then run
gui/pitcrewgui/
  platform.py             the ONLY file that knows which OS this is
  bootstrap.py            re-exec into a python that has PyGObject
  settings.py  registry.py  model.py                 no GTK, unit-testable
  runner.py    widgets.py   dialogs.py   window.py   app.py
```

Same bargain `lib/00-platform.sh` strikes for the tool itself: **every
OS-specific decision lives in one file**, and a test fails if OS knowledge leaks
anywhere else. Adding an OS means a branch in `platform.py` and one in
`gui/install.sh` — nothing else.

Two decisions worth knowing:

- **There is no shebang pinning an interpreter.** One was hardcoded to
  `/usr/bin/python3`, which is the system python on Fedora, a stub with no
  bindings on macOS, and absent under MSYS2. The launcher asks at runtime and
  re-execs into whichever python can import `gi` — which also fixes the case
  where a Homebrew or pyenv python shadows the system one on Linux.
- **The config directory does not follow platform convention.** macOS would
  want `~/Library/Application Support`; the GUI uses `~/.config/pitcrew`
  anyway, because it has to read the registry the `pitcrew` *command* writes,
  and that has no OS branch. A tidier path that disagreed with the CLI would be
  a bug, not good manners.

It owns **no** measurement logic. Every number on screen arrives over
`pitcrew json --watch`, the same snapshot the terminal dashboard draws, so the
two can never disagree and a fix in `lib/03a-snapshot.sh` lands in both. The
GUI is a renderer plus start/stop/restart buttons.

- picks up whichever project `pitcrew use` selected; switch from the header, or
  pin one with `pitcrew-gui -p <name>`
- the header carries a live **`2/12 up`** pill, coloured by the worst thing
  happening — a crash outranks the nine components that are fine. This used to
  be the window title, which the view switcher makes invisible
- a **Logs** view tails any component live, with the lines the error radar
  counts highlighted in place. It learns where logs are from the stream
  (`logDir`) and what counts as an error from `errorPattern`, so it shows the
  same lines the dashboard counts rather than a second opinion. **All /
  Backend / Frontend** filters the picker, backends first — they start first,
  and are what a frontend is usually failing to reach
- **it tells you when something crashes** — a desktop notification on any
  `up → crashed` transition, with a *Show logs* button that opens that
  component's log. Not for a crash that was already in progress when you
  started watching, and not twice for a service that flaps. Off with
  `--notify none`
- every running row carries a **sparkline** of its memory, scaled to its cap —
  the terminal dashboard has drawn one per row from the start, and the GUI made
  you switch to Resources and find the line in a legend to answer "is this
  climbing"
- rows say **how long** they have been up (`up 2h14m`), how many times they have
  **restarted** in the current crash streak, and spin while `starting` — a
  gradle backend sits there for a minute and you could not tell waiting from
  stuck
- **click a row** for everything pitcrew knows: pid, uptime, restarts, memory
  against its cap and where that cap came from, URL, health, log path, and the
  process tree
- a **filter box**, because twelve rows plus six headings is a lot of scrolling
  to answer "is sales up"
- the port on a running row is a **button**: it opens the real URL, including
  the `--url-path` every backend sits behind, and backends with a configured
  health path say `health ✓`
- **`n` errors** is a button too — it jumps to that component's log with
  errors-only on
- group headings **start / restart / stop a whole app**, and the menu has
  **Start everything**, **Stop everything**, and your saved **Profiles**
- the log view has a **filter box** and an **errors-only** toggle, both of
  which work on a live tail
- **keyboard**: `Ctrl+1…4` for views, `/` to filter the log, `Ctrl+M` for RAM
  caps, `Ctrl+Enter` to start everything, `?` for the list
- window size and last view are remembered
- **Resources** says what the project costs against what the box actually has:
  *"using 1.5 GiB of 31.0 GiB · machine total 11.2 GiB used · 5% cpu · caps
  commit 108.0 GiB — more than the machine has"*. The memory graph has a
  **Fit / Machine** scale: auto-scaled, 1.5 GiB and 15 GiB draw the identical
  picture, which is exactly the question being asked
- components are **grouped by app** by default, so a backend and its frontend
  sit together under one heading with a `2/2 up · 1.6 GiB` rollup
- errors surface in a banner with a Retry, never as a window quietly showing
  stale numbers — and a list filtered down to nothing says why it is empty

### Projects

A third view manages the registry itself, so a new machine never needs the CLI
to get started:

- **Add project** runs `pitcrew init` against a folder you pick — same detection,
  same generated config, and its report shown verbatim. The GUI does not have a
  second opinion about what is in your repo.
- **Edit config** opens the project's config in the app. It follows the
  indirection: a registry entry for a repo that ships its own
  `pitcrew.config.sh` only sets `PITCREW_ROOT` and sources it, so the editor
  opens the file in the repo, not the stub that points at it.
- **Watch** makes a project current; **Forget** drops it from the registry after
  a confirmation, leaving the checkout alone.

The config is edited **as bash**, not as a form. A pitcrew config is a sourced
shell script — the autoland one builds its apps from a `for` loop over a
`declare -A` of ports — and a structured editor that could not round-trip that
would quietly drop it. Instead the editor refuses to save anything `bash -n`
rejects (a config that will not parse breaks every pitcrew command for that
project, including the one that would tell you why), and **Check** runs
`pitcrew doctor` against it.

### Preferences

Editable in-app (**Ctrl+,**) and stored in `~/.config/pitcrew/gui`, in the same
`key=value` shape as `render` — plain text you can cat, diff and edit over ssh.
A value this version does not recognise falls back to its default rather than
crashing, exactly like `render_resolve`.

| key | values | default | |
|-----|--------|---------|--|
| `group` | `app` · `role` · `flat` | `app` | how the component list is grouped |
| `interval` | 1–60 | `2` | seconds between samples |
| `history` | 30–600 | `120` | samples kept per graph line |
| `stopped` | `show` · `hide` | `show` | whether stopped components are listed |
| `plot` | `running` · `all` | `running` | which components get a graph line |

Every one is also a flag for a single run — `pitcrew-gui --group role --interval 5`
— and an env var, `PITCREW_GUI_GROUP=flat`, which beats the file the same way
`PITCREW_GRAPH` beats `render`. Unlike the file, a bad **flag** is rejected with
a message instead of silently falling back: a command line is an explicit
instruction, and guessing at a typo there is how you end up debugging the wrong
setting.

### Dependencies

```bash
make gui-deps          # what does this OS need, and what would install it
make gui-deps YES=1    # go ahead and install it
```

`gui/install-deps.sh` detects the package manager and knows what each one calls
PyGObject, pycairo, GTK 4 and libadwaita — plus **bash 5** on macOS, where the
system bash is 3.2 and pitcrew refuses to run under it.

| | |
|---|---|
| detected | `dnf` `apt` `pacman` `zypper` `apk` `brew` MSYS2 `pacman` |
| override | `PITCREW_PKG=apt make gui-deps` |

**It will not install anything unless you say so.** The default prints the exact
command and stops; `YES=1` is the opt-in. A script that installs system packages
the moment you run it is a script people learn not to run — and `sudo` is not
something an installer should help itself to.

Two constraints the script lives under, both of which rule out the obvious
implementation: it cannot be written in python-with-`gi` (the bindings are what
it installs) and it cannot use bash 5 (that is what it installs on macOS), so it
is bash 3.2 throughout.

Only the Fedora path has actually been run. The other tables are written from
the documented package names and are unverified — which is the other reason the
command is printed before anything happens.

The terminal dashboard stays the primary interface — it is the one that works
over ssh, which a GTK app never will.

## How it works

- Each backend/frontend is a plain background process — wrapped in
  `systemd-run --user --scope` for a live RAM/CPU cgroup and a hard memory
  cap when systemd is available, a bare backgrounded process otherwise.
  Output goes to `.pitcrew/logs/<component>.log`, its pid to
  `.pitcrew/logs/<component>.pid`, both in your project root (add
  `.pitcrew/` to `.gitignore`).
- RAM/CPU are summed over each component's whole process tree, so they work
  identically with or without systemd. On Linux the dashboard reads all of it
  — listening ports, process trees, per-process RSS and CPU jiffies — straight
  out of `/proc` with bash builtins, which means **a frame costs no forks at
  all**: 158ms and ~5s of child CPU per 25 frames became 6ms and zero. That is
  what makes a sub-second refresh and per-service history affordable. RSS is
  taken from `statm`, so it matches what `ps -o rss` reports to the page, and
  CPU is a real utime+stime delta over the sampling window rather than `ps`'s
  lifetime average. macOS (or any Linux without a readable `/proc`) falls back
  to one `ps` plus one port listing per frame — same numbers, two forks
  instead of none, and a 1s floor on the refresh rate. `pitcrew doctor` tells
  you which collector is active.
- "Up" means: the port is open, and — if you configured a health path — the
  health endpoint reports `"UP"`. Anything else is "starting" while the
  pidfile's process is alive, or "crashed" if it died on its own (a leftover
  pidfile pointing at a dead pid). A component with no start command
  configured for that role is "n/a", not "down".
- `pitcrew stop` stops both tool-managed processes (via the systemd scope, or
  by killing the whole process tree) *and* anything else already listening
  on that port — so it also cleans up a service you started by hand outside
  pitcrew (shown as `ext` in the dashboard).

## Not (yet) supported

pitcrew models each app as up to two roles: backend and frontend. If your
project has services that don't fit that shape (a worker fleet, multiple
backends per app, etc.), point the extra process at whichever role slot is
free, or open an issue — the two-role model is a scope decision, not a hard
architectural limit.

## When something dies

A crashed component now says *why*: the launcher wraps each start so something
outlives the process and records how it ended, and the dashboard shows
`✗ :8082  exit 3 · 12:04:15` instead of a bare `✗ crashed`.

Restarting a service no longer erases the log you were restarting it to read.
The previous run is kept as `<component>.log.1`, the one before that as
`.log.2`, up to `PITCREW_LOG_KEEP` (default 2; set 0 for the old truncating
behaviour).

pitcrew can also bring crashed components back:

| Variable | Default | |
|---|---|---|
| `PITCREW_RESTART` | `0` | `1` = auto-restart components that crash |
| `PITCREW_RESTART_BACKOFF` | `2` | seconds before the first retry, doubling each attempt |
| `PITCREW_RESTART_MAX` | `5` | attempts before giving up on a crash loop |
| `PITCREW_RESTART_RESET` | `60` | seconds a component must stay up to earn its budget back |
| `PITCREW_LOG_KEEP` | `2` | previous runs' logs to keep per component |

Two things this deliberately is not. It **only runs while the live dashboard
is open** — pitcrew has no daemon and nothing to attach to, and adding a
background supervisor would mean inventing a pidfile for the supervisor, a way
to stop it, and a way to notice when it dies. Restarting while you're watching
covers the case that actually hurts without any of that, and `pitcrew doctor`
tells you which mode you are in. And it **gives up**: a service that crashes on
a syntax error is not something to relaunch forever, because the log you need
ends up buried under a thousand identical boot attempts. Press `r` on a
component to clear its give-up and try again.

## What pitcrew runs

`pitcrew init` reads a repository and **writes shell commands** into a config;
`pitcrew up` **executes them**. That is the whole point, and it means a pitcrew
config is exactly as trusted as the repository it was generated from — treat one
that arrived from somewhere else the way you would treat any other script before
running it. `pitcrew edit` shows you the file, and `pitcrew doctor` runs no
project commands at all.

## Development

`make check` is lint + tests, and it is green — `make lint` fails on anything
shellcheck rates **warning** or above. It used to run at `style`, where 58
findings (43 of them cosmetic) meant it always failed, so nobody read it. It had
been hiding two real bugs the whole time: `*bun*` shadowing `*bundle*`, so every
`bundle exec rails` app drew the node icon, and a `rail_color` `local` line that
read the *caller's* `$app` — the exact trap `lib/07a-start.sh` already documents.
Anything below warning is either fixed or annotated at the line with why.

```bash
make check      # lint + tests, the same thing CI runs
make test       # tests only
make test T=meters   # just the files matching "meters"
make lint       # bash -n everything, then shellcheck if it is installed
```

The suite is plain bash — no bats, no npm, no submodule — because pitcrew
installs with `ln -s` and has to stay runnable on a box where you cannot
install anything. `test/harness.sh` is the whole framework.

The most important test is `test/perf_test.sh`, which asserts that **a
dashboard frame forks nothing at all**. That invariant is the reason
sub-second refresh and per-service history are affordable, and it is easy to
break by accident: a single `$(helper)` looks harmless and costs a subshell a
dozen times per frame. It is measured with a SIGCHLD trap, which counts this
shell's children exactly — `/proc/stat`'s counter is system-wide and far too
noisy, and the `times` builtin misses a cheap subshell entirely because it
burns no measurable CPU.

## License

MIT — see [LICENSE](LICENSE).
