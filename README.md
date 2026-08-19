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

## Why

Most process launchers (`overmind`, `foreman`, `mprocs`, a `docker-compose`
stack) either assume one flat process list or assume everything is a
container. Real monorepos are messier: a handful of named apps, each with its
own backend + frontend, sharing a couple of infra dependencies, where you
usually only want *some* of them running, want to see which are actually
healthy (not just "the process didn't exit"), and want a RAM meter before
your laptop falls over running six JVMs and six Node processes at once.

## Platforms

- **Linux** — primary target, fully supported. RAM caps + precise cgroup
  meters when `systemd --user` is available (it usually is).
- **macOS** — fully supported through portable equivalents: `lsof` instead
  of `ss` for port lookups, `ps`-based process-tree RAM/CPU meters instead of
  cgroups, `vm_stat`/`top` instead of `/proc` for the system-wide gauges.
  There's no systemd on macOS, so hard RAM-cap *enforcement* isn't available
  there — the meters still work, a runaway process just isn't auto-killed.
- **Windows** — not supported natively (no bash, no `/dev/tcp`, no `systemd`,
  different `ps`). Run pitcrew inside **WSL2**, where it sees a normal Linux
  userland and needs nothing special — including real RAM caps, since modern
  WSL2 distros run systemd by default.

## Install

Requires **bash 5.0 or newer** (`$EPOCHREALTIME`, negative array indices and
`declare -gA` are used throughout; `pitcrew` checks this up front and tells you
rather than failing with a syntax error). macOS still ships bash 3.2, so
there you need `brew install bash` first. Also requires `docker` (only if you declare deps), and ideally `systemd
--user` on Linux for RAM caps (the tool still runs without it, just without
caps — this is the normal path on macOS). `lsof` is used for port lookups
(falls back to `ss` on Linux if missing). `fzf` is optional but strongly
recommended for the interactive menu.

```bash
git clone https://github.com/<you>/pitcrew ~/.local/share/pitcrew
~/.local/share/pitcrew/install.sh
```

`install.sh` symlinks `bin/pitcrew` onto your `$PATH` (default
`~/.local/bin`). Or just symlink it yourself:

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

## Dashboard

The live dashboard keeps a rolling history per component and draws it as a
sparkline where a single number used to be, so a leak looks like a leak
instead of a number that happens to be large today. Selecting a service and
pressing Enter expands its real process tree — the Gradle daemon, the `node`,
the `esbuild` — each with its own RAM and CPU.

Each graph is scaled to that service's own recent range, not to its RAM cap.
Scaling to the cap is what makes this kind of graph useless in practice: a
backend using 1.0G of an 8G cap sits at 12%, every sample lands on the bottom
row, and you get a flat line for every service you own. The cap still drives
the *colour* — the graph turns yellow then red as you approach it — so you
lose nothing by scaling the height to something you can actually read.

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
| `⏎` | expand/collapse that service's process tree |
| `e` | the error radar's actual matched log lines, not just the count |
| `l` `r` `s` `m` `q` | logs · restart · stop · menu · quit |

| Variable | Default | Purpose |
|---|---|---|
| `PITCREW_REFRESH` | `1` | seconds between frames; fractions like `0.25` are fine |
| `PITCREW_GRAPH` | `block` | `block` (▁▂▃) or `braille` (⣀⣤⣶), which packs 2 samples per cell |
| `PITCREW_HISTORY` | `240` | samples kept per component |
| `PITCREW_THEME` | `default` | `default` (Catppuccin Mocha), `tokyonight`, `rosepine`, `gruvbox`, `mono`, or your own |
| `PITCREW_THEME_FILE` | `~/.config/pitcrew/theme` | where `pitcrew theme <name>` remembers your choice |
| `PITCREW_COLOR` | auto | `truecolor` / `16` / `none` — detected from `$COLORTERM`, override to force |
| `PITCREW_ICONS` | `unicode` | `nerd` adds language and docker glyphs (needs a patched font) |
| `PITCREW_NARROW_AT` | `110` | below this width, one component per row instead of two columns |
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

## Development

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
