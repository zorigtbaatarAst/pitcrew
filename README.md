# pitcrew

A config-driven local dev-stack launcher for multi-service monorepos.

If your project is "N apps, each with a backend + frontend, plus a couple of
docker dependencies" and you're tired of juggling `tmux` windows, forgetting
which port is which, or watching a service spin forever because nobody told
you it actually crashed — pitcrew gives you one command with a live
dashboard, per-service RAM/CPU meters, an error radar over the logs, and fzf
menus to start/stop/restart/inspect anything.

Everything runs inside a single tmux session, RAM-capped per service via
`systemd-run --user --scope`, with logs captured to disk so nothing is lost
when a pane closes.

![status](https://img.shields.io/badge/status-early-yellow)

## Why

Most process launchers (`overmind`, `foreman`, `mprocs`, a `docker-compose`
stack) either assume one flat process list or assume everything is a
container. Real monorepos are messier: a handful of named apps, each with its
own backend + frontend, sharing a couple of infra dependencies, where you
usually only want *some* of them running, want to see which are actually
healthy (not just "the process didn't exit"), and want a RAM meter before
your laptop falls over running six JVMs and six Node processes at once.

## Install

Requires `bash`, `tmux`, `docker` (only if you declare deps), and `systemd
--user` (for RAM caps/meters — the tool still runs without it, just without
caps). `fzf` is optional but strongly recommended for the interactive menu.

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

1. Drop a `pitcrew.config.sh` at your project root — copy
   [`examples/pitcrew.config.example.sh`](examples/pitcrew.config.example.sh)
   and edit it. See that file for the full annotated schema.
2. `cd` anywhere inside your project (pitcrew walks up looking for the
   config, like `git` does for `.git`) and run:

```bash
pitcrew start          # bring everything up, with a live boot dashboard
pitcrew                # live dashboard (also the default with no args)
pitcrew menu           # fzf menu for everything below
pitcrew logs           # in-place log viewer, Tab/←→ to switch services
pitcrew stop           # stop everything (deps stay up unless --deps)
```

## Commands

```
pitcrew                  live dashboard (default) — l logs · s stop · g grid · m menu · q quit
                          (in logs: Tab/←→ switch · x stop · r restart · Enter attach)
pitcrew menu              interactive fzf menu
pitcrew start [all|backends|frontends|deps|@profile|<app>...]
pitcrew stop  [all|@profile|<app>...]     stops tool-managed AND external
pitcrew stop --deps                       also stop non-protected deps
pitcrew restart <app>...
pitcrew status                    one-shot dashboard
pitcrew watch                     live auto-refreshing dashboard
pitcrew grid                      tiled tmux view of ALL service logs
pitcrew logs [<component>]        in-place log viewer
pitcrew stale [--restart]         apps whose code changed since they started
pitcrew profile save <name> <targets...> | list | rm <name>
pitcrew shell [<name>]            open a configured quick shell (PITCREW_SHELLS)
pitcrew doctor                    check the local environment
pitcrew attach | urls | help
```

A "target" is an app name (`sales`), a specific role (`be-sales`, `fe-sales`),
a group (`all`, `backends`, `frontends`, `deps`), or a saved `@profile`.

## Config

Full schema with comments:
[`examples/pitcrew.config.example.sh`](examples/pitcrew.config.example.sh).
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

## How it works

- Each backend/frontend runs in its own tmux window, wrapped in
  `systemd-run --user --scope` for a live RAM/CPU cgroup and a hard memory
  cap. Output is piped to `.pitcrew/logs/<component>.log` in your project
  root (add that directory to `.gitignore`).
- "Up" means: the port is open, and — if you configured a health path — the
  health endpoint reports `"UP"`. Anything else is "starting". A dead tmux
  pane is "crashed". A component with no start command configured for that
  role is "n/a", not "down".
- `pitcrew stop` stops both tool-managed processes (via the systemd scope /
  tmux window) *and* anything else already listening on that port — so it
  also cleans up a service you started by hand outside pitcrew.

## Not (yet) supported

pitcrew models each app as up to two roles: backend and frontend. If your
project has services that don't fit that shape (a worker fleet, multiple
backends per app, etc.), point the extra process at whichever role slot is
free, or open an issue — the two-role model is a scope decision, not a hard
architectural limit.

## License

MIT — see [LICENSE](LICENSE).
