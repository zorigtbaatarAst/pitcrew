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

Requires `bash`, `docker` (only if you declare deps), and ideally `systemd
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

## Quick start

1. Drop a `pitcrew.config.sh` at your project root — either run
   `pitcrew init` inside the project (prompts for a name and app list, then
   generates a starter file), or copy
   [`examples/pitcrew.config.example.sh`](examples/pitcrew.config.example.sh)
   by hand and edit it. See that file for the full annotated schema.
2. `cd` anywhere inside your project (pitcrew walks up looking for the
   config, like `git` does for `.git`) and run:

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
| `⏎` | expand/collapse that service's process tree |
| `e` | the error radar's actual matched log lines, not just the count |
| `l` `r` `s` `m` `q` | logs · restart · stop · menu · quit |

| Variable | Default | Purpose |
|---|---|---|
| `PITCREW_REFRESH` | `1` | seconds between frames; fractions like `0.25` are fine |
| `PITCREW_GRAPH` | `block` | `block` (▁▂▃) or `braille` (⣀⣤⣶), which packs 2 samples per cell |
| `PITCREW_HISTORY` | `240` | samples kept per component |
| `PITCREW_THEME` | — | a file in `~/.config/pitcrew/themes/<name>.sh` or `themes/` |
| `PITCREW_MOUSE` | `0` | `1` enables click-to-select / click-again-to-expand / wheel |
| `PITCREW_ERROR_PATTERN` | `ERROR\|FATAL\|Exception\|UnhandledRejection` | what the error radar counts |
| `PITCREW_HEALTH_INTERVAL` | `5` | seconds between health probes (×3 once a service reports UP) |
| `PITCREW_DEP_INTERVAL` | `10` | seconds between docker dep checks |

`NO_COLOR` (or `PITCREW_NO_COLOR`) drops every color. A theme is a plain bash
file that reassigns `$RED`, `$GREEN`, `$BOLD` and friends — no new format and
no parser; see [`themes/default.sh`](themes/default.sh).

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

## License

MIT — see [LICENSE](LICENSE).
