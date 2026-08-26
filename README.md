# pitcrew

A config-driven local dev-stack launcher for multi-service monorepos.

If your project is "N apps, each with a backend + frontend, plus a couple of
docker dependencies" and you're tired of hunting down which port is which,
or watching a service spin forever because nobody told you it actually
crashed — pitcrew gives you one command with a live dashboard, per-service
RAM/CPU meters, an error radar over the logs, and menus to
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
- [Diagnostics](#diagnostics)
- [Plugins](#plugins)
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
- **Windows** — runs natively under **Git Bash** (2.35+, which ships bash 5) or
  **MSYS2**. The shell was never the problem; the POSIX userland underneath it
  was. So the process table comes from `wmic` (or PowerShell, where wmic has
  been removed), listening ports from `netstat -ano`, and the pidfiles hold
  MSYS pids — translated to Windows pids only where a native tool is on the
  other end.

  Two things are worse here and `pitcrew doctor` says both. **RAM caps are not
  enforceable**: Windows has Job Objects but nothing on the command line puts a
  process in one, so the caps are budgets the meters measure against, exactly
  as on macOS. And a frame costs one process-table call plus one `netstat` —
  `wmic` is ~80ms, PowerShell a few hundred — against *zero* forks on Linux, so
  raise `PITCREW_REFRESH` if it feels heavy.

  **WSL2 is still the better experience** and needs nothing special: pitcrew
  sees a normal Linux userland, gets real cgroup RAM caps, and draws a
  fork-free dashboard.

  The desktop app installs itself here too: `./setup.sh --yes` from an MSYS2
  **UCRT64** shell installs the GTK stack, puts `pitcrew` on your `PATH`, and
  writes a Start Menu entry *and* a Desktop icon. See
  [Desktop app](#desktop-app).

  One known gap, which `pitcrew doctor` reports: `stop` walks a component's
  process tree with `pgrep -P`, and **Git Bash has no `pgrep`** while MSYS2
  only has one if you installed `procps-ng`. Without it, stopping reaches the
  process pitcrew launched but not the ones *it* launched — the JVM under a
  gradle wrapper survives, and the port stays taken. `pacman -S procps-ng`
  fixes it on MSYS2.

  > Honest caveat: CI now runs the whole suite on `windows-latest` under Git
  > Bash, and installs the desktop app end to end on a real MSYS2 — including
  > failing if the shortcuts are not on disk afterwards. What is still
  > unverified is **integration**: a real stack of real services, started and
  > watched on a real Windows box. Reports welcome.

The portable collector is not a fallback that rots: `PITCREW_FORCE_COLLECTOR=ps`
runs it on Linux, and CI runs the whole suite that way on every push, so the
path macOS depends on is exercised even by people who never touch a Mac. The
menus get the same treatment — `PITCREW_PICKER=plain` runs the no-fzf pickers
on a box that has fzf, and CI runs the suite that way too, because "nobody here
has that setup" is exactly how the menu came to be unopenable on a Mac.

## Install

On Windows, install [Git for Windows](https://gitforwindows.org/) 2.35 or newer
(it ships bash 5) or MSYS2, and run everything below from its Bash prompt. For
the **desktop app** it has to be MSYS2's UCRT64 shell — that is where the GTK
stack lives; see [Desktop app](#desktop-app). `install.sh` writes a small shim
rather than a symlink there, because a Windows symlink needs Developer Mode and
a *copy* of the launcher cannot find its own `lib/` (nor, for the GUI, its own
`pitcrewgui/`).

Requires **bash 5.0 or newer** (`$EPOCHREALTIME`, negative array indices and
`declare -gA` are used throughout; `pitcrew` checks this up front and tells you
rather than failing with a syntax error). macOS still ships bash 3.2, so there
you need `brew install bash` first — and make sure it is ahead of `/bin/bash`
on your `$PATH`.

Everything else is optional or already on the box. `docker` only if you
declare deps. `systemd --user` only for enforced RAM caps on Linux. `lsof` for
port lookups (present on macOS; falls back to `ss` on Linux). `fzf` is
optional: with it the menus are fuzzy pickers, without it the same menus are
numbered prompts that take a number or a substring. Nothing is out of reach
either way, which matters because a stock macOS has no fzf. Nothing here needs
GNU coreutils — no `timeout`, no `readlink -f`, no GNU-only `sed`/`grep`
flags — so a stock macOS has what it needs after the bash upgrade.

**One line, clone to ready:**

```bash
git clone https://github.com/zorigtbaatarAst/pitcrew.git ~/.local/share/pitcrew && ~/.local/share/pitcrew/setup.sh
```

Add `--yes` to let it install the packages it reports as missing (that step
needs sudo on Linux, which is why it is opt-in). `--no-gui` gets you the
command line only. Re-run it any time after a `git pull`.

HTTPS in the line above because it works for anyone; if you have push access,
clone `git@github.com:zorigtbaatarAst/pitcrew.git` instead — everything after
the clone is identical. And it is not a `curl | bash`: you get a script you can
read first, in a directory you can update later.

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
4. a `pitcrew.yaml` (or `pitcrew.yml`, or `pitcrew.config.sh`) walked up from `$PWD`
5. a registered project whose root contains `$PWD`
6. whatever `pitcrew use` last selected

An **in-project config outranks the registry**. A repo that ships
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
| **health** | `/actuator/health` when it sees Spring Boot — behind `server.servlet.context-path` when the app sets one |
| **watch dir** | the component's `src/`, for `pitcrew stale` |
| **deps** | services named in a `docker-compose.yml`, written out commented for you to confirm |

Run it against a six-app Gradle + Next monorepo and you get a config that
starts it. It is still a guess: the header says so, and `pitcrew edit` opens it.

**Gradle version catalogs are read.** A module built in the last few years does
not name its plugins: `alias(libs.plugins.spring.boot)` is the whole line, and
the id it stands for lives in `settings.gradle.kts` or
`gradle/libs.versions.toml`. Reading only the module made a Kotlin/Spring
backend invisible — `init` wrote a config with the frontend in it and nothing
to talk to. The alias is resolved through the catalog now, in both of the
places a catalog can be declared, and `apply false` is understood: a root build
file that declares every plugin for its subprojects is not itself an app.

```bash
pitcrew detect [--json] [<dir>]
```

The same guess, printed instead of written — what pitcrew thinks is in a
directory, with the command, port and health path it would give each part, and
not a byte written anywhere. Useful before `init`, and it is what the desktop
app's **Add an app** list is built from, so the app and the CLI cannot come to
different conclusions about a project.

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
pitcrew menu           # action menu for everything below
pitcrew logs           # in-place log viewer, Tab/←→ to switch services
pitcrew stop           # stop everything (deps stay up unless --deps)
```

## Commands

```
pitcrew                  live dashboard (default) — ↑↓ select · ⏎ process tree
                          l logs · e errors · r restart · s stop · m menu · q quit
                          observes only — nothing is started for you
                          (in logs: Tab/←→ switch · x stop · r restart · Enter full log)
pitcrew menu              interactive action menu (fzf if installed)
pitcrew start [all|backends|frontends|deps|@profile|<app>...]
pitcrew up                 start whatever isn't already running, then the live dashboard
pitcrew stop  [all|@profile|<app>...]     stops tool-managed AND external
pitcrew stop --deps                       also stop non-protected deps
pitcrew restart <app>...
pitcrew status                    one-shot dashboard
pitcrew watch                     same as bare `pitcrew` — live dashboard, no auto-start
pitcrew logs [<component>]        in-place log viewer
pitcrew stale [--restart]         apps whose code changed since they started
pitcrew profile save <name> <targets...> | list | show <name> | rm <name>
pitcrew shell [<name>]            run a configured quick shell (shells:), foreground
pitcrew doctor                    check the local environment
pitcrew diagnose [--json] [--watch]
                                  what is wrong with the STACK, why, and what
                                    to do about it (exit 1 on a critical finding)
pitcrew plugins                   what is loaded from ~/.config/pitcrew/plugins
pitcrew detect [--json] [<dir>]   what pitcrew thinks is in a directory, and the
                                   command and port it would give each part — the
                                   guess `init` makes, written nowhere
pitcrew init [<dir>] [--sh]       look at a project and write a pitcrew.yaml (--sh
                                    for the older bash format; default dir: $PWD)
pitcrew check [<file>]            load a config and say what is wrong with it
pitcrew theme [<name>]            list themes, or switch and remember (--reset to forget)
pitcrew urls | help

pitcrew -C <dir> <command>        run against <dir>'s project instead of walking up from $PWD
pitcrew --project <dir> <command> same as -C — <dir> may be the project root or the config file itself
```

A "target" is an app name (`sales`), a specific role (`be-sales`, `fe-sales`),
a group (`all`, `backends`, `frontends`, `deps`), or a saved `@profile`.

### Profiles

A profile is a named set of targets — the three services you actually need on
a Tuesday, out of the twelve the project has.

```bash
pitcrew profile save morning sales backoffice     # or save what is running,
pitcrew start @morning                            #   from the desktop app
pitcrew profile list
pitcrew profile show morning
```

`list` answers the questions you open it to ask, not the words you typed:

```
  @morning        3/5 up  +1                     1.4 GiB      :8082  :3002  :8091
  @everything     0/12 up                        —            :8082  :3002  …
  @legacy         0/2 up
   └ crm no longer exists — this profile will not start
```

That last line matters. **A profile stores target WORDS, not components** — on
purpose, so `sales` keeps covering sales when that app grows a worker. The cost
is that a profile can rot: rename an app and the file still names the old one,
and `pitcrew start @legacy` dies on a target that no longer exists. So
everything reports what a profile resolves to *today*, missing words included,
rather than echoing the file back. `pitcrew profile show <name>` lists every
component it covers, what is up, and what it commits if all of it runs.

In the desktop app they are on the **Overview**, one row each with the same
numbers and a start button — plus **Alt+1…9** to launch one without touching
the mouse. Everything on those rows arrives over `pitcrew json`, which is
pitcrew resolving its own target words; the app never reads the profile
directory, because a directory listing cannot know what `sales` covers now.

`pitcrew` with no arguments and `pitcrew watch` are the same thing — a live
dashboard that only observes. Nothing gets started unless you explicitly ask
for it with `pitcrew start` or `pitcrew up` (the latter starts whatever's
missing, then drops into the same dashboard — handy, but opt-in).

`-C`/`--project` let you run pitcrew against a project without `cd`-ing into
it first — handy for an alias like `alias autoland='pitcrew -C ~/workspace/autoland-management'`.
It must come before the subcommand and takes priority over `$PITCREW_CONFIG`
and the usual walk-up-from-`$PWD` search.

## Config

A config is one YAML file. Full schema with comments:
[`examples/pitcrew.yaml`](examples/pitcrew.yaml). Run `pitcrew init` to
generate one from what is actually in the repository instead of copying by
hand, and `pitcrew check` to load a config and be told what is wrong with it
without starting anything.

```yaml
name: Storefront
emoji: "🛒"

apps:
  storefront:
    url_path: /api
    be:
      dir: storefront                       # relative to the project root
      cmd: bundle exec rails s -p 4000      # `dir` becomes a cd in front of it
      port: 4000
      health: /health
      watch: [storefront/app]               # for `pitcrew stale`
    fe:
      root: ~/work/storefront-web           # its own checkout, not this repo
      cmd: npm run dev
      port: 3000
    worker:                                 # any name you like — see below
      dir: storefront
      cmd: bundle exec sidekiq

  reports:
    enabled: false                          # listed, never started by `all`
    be: { dir: reports, cmd: bundle exec rails s -p 4100, port: 4100 }

  admin:
    fe: { dir: admin, cmd: npm run dev, port: 3001 }   # one line is fine

deps: [postgres, redis]
protected_deps: [postgres]                  # never stopped by `stop --deps`

max: {be: 4G, fe: 6G, worker: 1G}
wait: 180

shells:
  db: docker exec -it postgres psql -U postgres storefront_development

doctor:                                     # your own `pitcrew doctor` checks
  bundler present: command -v bundle
```

### An app is a group, and the group is open

`be` and `fe` are two ordinary **role names**, not the only two there can be.
Add a `worker:`, a `scheduler:`, a second `admin_web:` — whatever your team
calls them. A role exists for an app **only if it has a `cmd:`**; a missing one
shows as `n/a`, is never started, and is never counted as down.

A component is named `<role>-<app>` and the two are split on the **first** dash,
so a role name is letters, digits and `_` (an app name may contain dashes —
`be-report-api` is one component, not two). Every role is a target of its own:

```bash
pitcrew restart worker              # every app's worker
pitcrew restart worker-storefront   # just that one
pitcrew start shop                  # the whole group
```

### Where a component lives

`root:` is a component's own checkout, `dir:` is relative to it, and the
command becomes a correctly-quoted `cd` in front of whatever you wrote. Put
`root:` under the app to give a whole group one, and under a component to
override it — a backend and a frontend in two different repositories is two
lines, not an absolute path repeated in front of every command.

Absolute paths, `~/…` and `../…` all work, and `watch:` resolves against the
same root as its component (defaulting to `dir:` when you do not set it).
`$ROOT` and `$HOME` expand if you write them; every other `$VAR` is left alone
and reaches the shell that runs the command.

### Excluding something without deleting it

`enabled: false` on a component — or on a whole app — takes it out of
`pitcrew start all`, out of `backends`/`frontends`, and out of its group. It
stays on the dashboard, greyed out and marked `off`, keeping its port and its
cap: an excluded service that *vanished* is one you spend an afternoon looking
for. Naming it outright still starts it, because a switch you cannot override
is a trap.

The keys, all optional except `apps:` and one `cmd:`:

| Key | Purpose |
|---|---|
| `apps.<name>.<role>` | a component: `cmd`, `port`, `root`, `dir`, `health`, `watch`, `max`, `protected`, `enabled` |
| `apps.<name>.root` | a checkout for the whole group; a component's own `root:` wins |
| `apps.<name>.enabled` | `false` excludes every component in the group |
| `apps.<name>.url_path` | cosmetic API path suffix for `pitcrew urls` |
| `deps` / `protected_deps` | docker containers to start; ones never auto-stopped |
| `deps_ready` | best-effort command run once after deps start |
| `env.<role>` | env vars prepended to every start command for that role |
| `max.<role>` / `wait` | role RAM caps and boot timeout |
| `name` / `emoji` | banner display |
| `shells.<name>` | named quick shells for `pitcrew shell <name>` |
| `doctor.<label>` | a command per line — exit 0 is a tick in `pitcrew doctor` |
| `dashboard.*` | pin how this project is drawn (`theme`, `refresh`, `error_pattern`, …) |
| `root` | project root, if it is not the config file's own directory |
| `include` | pull in another config; must be the first key in the file |

Loading runs sanity checks and warns rather than failing: an unknown key
(reported with its exact path, so a typo is visible instead of silent), an app
with no command at all, two components sharing a port, a `protected_deps` entry
that is not a dep.

### The YAML subset

The parser is ~200 lines of bash, because a config format that needs a package
installed is a config format that fails on the box you actually have to work
on. It handles block mappings, block and flow sequences of scalars, quoted
scalars, `|` and `>` block scalars, flow mappings of scalars (`be: { cmd: x,
port: 1 }` — a group with four roles reads far better as four lines than as
twenty), comments and `include:`. It **rejects**, with a file and line number,
everything it does not implement: tabs for indentation, anchors and aliases,
tags, sequences of mappings, nested flow collections.
Refusing loudly is the point — a config format that half-parses a start command
is worse than one that does not parse it at all.

### Converting one to YAML

`pitcrew migrate` writes the YAML that means the same thing:

```bash
pitcrew migrate --print     # see it first
pitcrew migrate             # write pitcrew.yaml next to the .sh
```

This works precisely because pitcrew has already **run** the config by the time
`migrate` starts. A file that builds six apps from a `for` loop over a
`declare -A` of ports — compact to write, and unreadable to anyone asking what
port `sales` is on — has by then become six concrete apps in the model, and
that is what gets written out. Along the way it undoes what the shell format
made you open-code: a `cd $ROOT/x && …` in front of a command becomes `dir: x`,
absolute paths become relative or `$ROOT`/`$HOME`, and values are quoted only
where leaving them bare would change them.

**The result is checked before anything is written.** The generated file is
loaded in a subshell and its model compared, field by field, against the one in
memory — every command, port, health path, cap, environment prefix, protection
flag and exclusion. If they differ, nothing is written and you get the diff. A
migration that silently changed a port would be worse than no migration.

One difference is expected and reported rather than refused: in YAML a
component with a `dir:` and no `watch:` of its own watches the directory it
runs in, which a `.sh` config had no way to say. `migrate` names every
component that gains a watch dir, because it changes what `pitcrew stale`
reports.

What YAML cannot carry is named up front — a `pitcrew_doctor_extra()` shell
function has to be rewritten as `doctor:` label/command pairs by hand.

Your `.sh` is left in place. pitcrew reads YAML in preference to it, so the new
file is live immediately; delete the old one once you are happy.

**The registry entry moves with it.** A registered project resolves through
`~/.config/pitcrew/projects/<name>.*`, and the entry `pitcrew init` writes for
a repo that ships its own config names the file in a `source` line — so a
conversion that left it alone would write a file that `pitcrew -p <name>`, the
dashboard and the desktop app all carried on ignoring. `migrate` rewrites that
pointer to `include:` the new YAML and says so. A registry entry that *holds* a
config rather than pointing at one is your file: that one is reported, never
rewritten, with the `pitcrew init` command that would replace it.

The desktop app offers the same conversion as a **Convert to YAML** button
whenever it opens a `.sh` config, since that is the one it cannot show you as a
form. It names the file it wrote, keeps the warnings on screen until you have
read them, and the same button then reopens the editor on the new YAML.

### The older bash format

`pitcrew.config.sh` still loads, unchanged, and nothing about it is deprecated:
a config that has to branch on the machine it is running on, or define a
`pitcrew_doctor_extra()` that does something real, is a shell script and should
stay one. Its schema is
[`examples/pitcrew.config.example.sh`](examples/pitcrew.config.example.sh) and
`pitcrew init --sh` still writes it.

The two formats describe one model — YAML is a front end onto the same
`PITCREW_*` variables, not a second implementation — so everything downstream
behaves identically. If a directory holds both, the YAML is read and pitcrew
says so on the way past rather than choosing silently.

Env var overrides: `PITCREW_CONFIG`, `PITCREW_ROOT`, `PITCREW_FE_MAX`,
`PITCREW_BE_MAX`, `PITCREW_WAIT`.

## Scripting it

The dashboard is for looking at. For everything else:

```bash
pitcrew status --json     # the whole state, for a status line or a CI gate
pitcrew json --watch      # the same object once per interval, as NDJSON
pitcrew config --json     # the CONFIG as the editable model, not the state
pitcrew wait sales --timeout 90   # block until it is up
pitcrew ps                # everything running, across every registered project
pitcrew projects --json   # the registry as data: running counts, ports, clashes
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

`pitcrew diagnose --watch` is the same idea for the verdict, on its own slower
interval (default 30s) — and unlike the state stream it runs the slow checks,
so it is what a desktop notifier should sit on:

```bash
pitcrew diagnose --watch --interval 60 | while read -r frame; do
  jq -r 'select(.health.verdict == "crit") | .health.headline' <<<"$frame"
done
```

### The JSON contract

`status --json` has consumers now — the desktop app, status lines, CI gates — so
it is versioned and its whole key set is pinned by `test/output_test.sh`. A
renamed or dropped field fails there rather than in your dashboard.

| | |
|---|---|
| top level | `schema` `project` `root` `collector` `at` `logDir` `errorPattern` `shells` `machine` `components` `deps` `health` `summary` |
| `projects --json` | per project: `name` `root` `exists` `current` `running` `ports[]` `clashes[]` |
| component | `name` `app` `role` `state` `port` `pid` `rss` `cpu` `errors` `exit` `limit` `limitSource` `url` `health` `since` `restarts` `idle` `protected` `processes` |
| machine | `memTotal` `memUsed` `cpuPercent` `swapTotal` `swapUsed` |
| dep | `name` `state` |
| health | `verdict` `headline` `deep` `counts` `findings` `recoverable` |
| finding | `severity` `id` `title` `detail` `fix` `scope` |
| process | `pid` `cmd` `rss` `cpu` (per component, biggest first, capped at `PITCREW_JSON_PROCS`) |
| summary | `up` `starting` `crashed` `external` `down` |

`schema` is **1**. Adding a field is backwards compatible and does not bump it;
removing one or changing what it means does. Bytes are bytes, `cpu` is an
integer percent, and anything unknown is `null` — never `0`.

`health.deep` says whether the **slow** checks ran — the NDJSON stream carries
only the cheap tier, so a consumer that sees `false` knows it can offer to ask
for the rest (`pitcrew diagnose --json`).

`health` carries the **verdict**, not just the facts: `verdict` is `ok`, `warn`
or `crit`, `headline` is the one sentence worth reading, and `findings` is what
led to it. That is there so a consumer never has to re-derive "is anything
wrong" from the component list — that judgement lives in one place
(`lib/19-diag.sh`), and a second implementation in another language would drift
from it the first time either side gained a check.

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
| per app | `max: 2G` under that role in the config | everyone on the project |
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

## Diagnostics

Every other view in pitcrew reports **facts**. `pitcrew diagnose` reports an
**answer**.

```bash
pitcrew diagnose          # what is wrong, why, and what to do about it
pitcrew diagnose --json   # the same as data; exits 1 on a critical finding
```

```
  ● be-worker crashed

  machine
    RAM  ██████████████████░░░░░░ 23.9G / 31.0G  77%
    CPU  ████░░░░░░░░░░░░░░░░░░░░ 18%
    SWP  ███░░░░░░░░░░░░░░░░░░░░░ 1.1G / 7.9G
    this project holds 11.4G

  ✗ be-worker crashed
    exited 3, 2m ago
    → pitcrew logs be-worker

  ⚠ memory pressure — 1.1G of swap in use
    this project holds 11.4G of it — largest: be-sales 4.1G, be-api 3.2G
    → pitcrew diagnose

  ∙ 2 idle services are holding 5.3G
    no CPU since pitcrew started watching, and up long enough to be forgotten
    → pitcrew stop be-analytics be-ceo

  recoverable — idle, and what stopping them returns

    be-analytics             3.1G   quiet 41m · up 3h20m
    be-ceo                   2.2G   quiet 52m · up 3h20m

    total 5.3G
    → pitcrew stop be-analytics be-ceo
```

The same verdict is the **first line of the live dashboard**, `d` opens this
panel inside it, and it is the top of the desktop app's Overview. One
implementation, three surfaces.

### What it checks

| | |
|---|---|
| `crashed` | a component that died, with its exit code and how long ago |
| `stuck` | "starting" for longer than the boot timeout — alive, and still nothing listening |
| `unhealthy` | serving its port, and its own health endpoint disagrees — with the status it answered |
| `external` | a port served by something pitcrew did not start (looks like success) |
| `memory` | machine RAM or **swap** under pressure, naming who is holding it |
| `caps-overcommit` | caps that add up to more than the machine — the OOM killer picks instead |
| `cap-near` | a component approaching the cap that will kill it |
| `dep-down` | a declared container that is not running |
| `log-errors` | a service that is up and quietly logging exceptions |
| `recoverable` | quiet, long-running services, and what stopping them returns |
| `stale` | running code that no longer matches what is on disk (slow tier) |
| `jvm-heap` / `jvm-cap` | from the bundled example plugin — see below |

### How "idle" is measured, and why it survives a restart

A candidate has to be *both* **quiet** and **old**, and both are measurements
rather than guesses.

Quietness is tracked per component and **persisted across pitcrew processes**,
which sounds like it cannot be honest — between two runs nobody was watching,
so how would pitcrew know a service was not hammered in the gap? Because it does
not have to infer it. `/proc` (and `ps -o time`) expose a *monotonic cumulative
CPU counter* per process. pitcrew writes that counter down next to the
timestamp, and on the next run compares: if the counter has not moved beyond
the idle threshold over the elapsed wall clock, the service **provably** did no
meaningful work in the gap, watched or not. Only then is the old timestamp
carried forward. The counter belongs to a PID and its units to a collector, so a
record is discarded outright when either changed — a restarted service starts
its idle clock at zero, which is correct.

That is what makes a one-shot `pitcrew diagnose` useful: it samples for a
second, and inherits the rest.

Oldness is uptime past `PITCREW_IDLE_MIN` (default 10 minutes). A service you
started thirty seconds ago is not a candidate however quiet it is.

### It proposes, you decide

The recovery flow is **diagnose → candidates → review → apply**, and there is no
step where pitcrew picks its own victims. Neither signal is proof that nothing
needs a service, which is exactly why the evidence is printed next to every name
(`quiet 41m · up 3h20m`) and the last thing you get is a command rather than an
action.

A role marked **`protected: true`** in the config is never proposed at all —
for the backend everything else talks to, or the one thing you are actually
working on. It is not a lock: `pitcrew stop` still stops it. Protected
components are still *listed*, under their own heading with a 🔒, because a
candidate list that silently omits your biggest idle service reads as a bug in
the tool rather than as a decision you made.

In the dashboard's `d` panel and the desktop app the apply step is a button,
but it is a button under a list of every component it will stop, with what each
is holding. Nothing is ever stopped that was not on screen when you decided.

Thresholds are all tunable: `PITCREW_MEM_WARN_PCT` (85), `PITCREW_MEM_CRIT_PCT`
(93), `PITCREW_CAP_NEAR_PCT` (90), `PITCREW_IDLE_MIN` (600s), `PITCREW_IDLE_CPU`
(2%).

## Plugins

A **plugin is a shell file that registers a diagnostic check.** That is the
whole of it — there is no manifest, no lifecycle, no API version. It is
deliberately the only extension point in the codebase.

```bash
mkdir -p ~/.config/pitcrew/plugins
cp examples/plugins/jvm.sh ~/.config/pitcrew/plugins/
pitcrew plugins        # what is loaded, and what each file registered
```

```bash
# ~/.config/pitcrew/plugins/disk.sh
check_disk() {
  [ "${SYS_MEM_TOTAL_KB:-0}" -gt 0 ] || return 0
  diag_add warn disk-full "the checkout's disk is nearly full" \
    "builds will fail in confusing ways" "df -h $ROOT" ""
}
diag_register check_disk          # runs every dashboard frame
```

A check reads the same `SNAP_*` arrays the built-ins read and calls the same
`diag_add`. It then appears in the dashboard verdict, in `pitcrew diagnose`, in
the JSON and in the desktop app's Overview, without touching any of them. The
built-in checks register through exactly this call; there is no privileged path.

### Two tiers, and why

```bash
diag_register my_check          # cheap: runs on every frame
diag_register my_check slow     # may fork: only on `pitcrew diagnose`
```

`diag_run` is called once per dashboard frame, where the whole product promise
is **zero forks**. A check that has to ask another program a question — `jcmd`,
`docker`, `curl` — cannot run there. Marking it `slow` keeps it out
structurally, rather than by trusting every plugin author to have read a rule.

The JSON says which tier a state object came from (`health.deep`), so the
desktop app can show a **Full diagnostics** button that asks for the rest
instead of silently showing you half the checks.

### Plugins load from your machine only

`~/.config/pitcrew/plugins/`, never from anything inside a checkout. That is a
deliberate refusal. A repository that ships a `pitcrew.config.sh` already asks
you to run its code, but that is one visible, well-known file — and YAML configs
exist precisely so a project can be described by **data**. A `.pitcrew/plugins/`
directory that got sourced automatically would silently undo that: `pitcrew
status` in a freshly cloned repo would execute whatever the repo felt like.
Nothing about "look at the dashboard" should mean "run this stranger's shell".

### The bundled example

`examples/plugins/jvm.sh` is a worked plugin, and it earns its place by catching
something neither half of the system can see alone:

> pitcrew knows the RAM cap it launched a JVM under. The JVM knows the `-Xmx` it
> settled on. When `-Xmx` plus native exceeds the cap, the kernel kills the
> process long before the heap ever fills — which presents as *"my service just
> disappears under load, with nothing in the log"*, because there was no
> exception, the process was shot.

It also warns when a heap is above 90% of its own ceiling. It is registered
`slow` (it forks a `jcmd` per JVM), and its parsers are pure functions taking
captured `jcmd` output on stdin, so `test/plugin_test.sh` verifies them on a
machine with no JVM on it.

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
pager or the action menu — the two places a resize can happen behind the
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
| `z` | **zen** — hide everything that is fine (see below) |
| `⏎` | expand/collapse that service's process tree |
| `e` | the error radar's actual matched log lines, not just the count |
| `l` `r` `s` `m` `q` | logs · restart · stop · menu · quit |
| `m` → 🌈 / 📈 | change theme · change graph & gauge style, both with live swatches |

#### Zen mode

`z` answers one question — *is there anything I need to do?* — so it hides
everything that says no, and it changes the **layout**, not just the contents.

The table is gone. Its two header rows, its backend/frontend column pair and
its graph column cost more rows than the content does once the content is one
crashed service, and an empty `· n/a` frontend cell beside a dead backend
spends half the width saying nothing. In its place is a list — one line per
component, each a sentence rather than a row of columns you need the header to
decode — in a narrow block centred in the window:

```
── salespro zen ──────────────────────────────────────────── 18:49 ──
                    ● be-orders crashed 12 seconds ago    d  for details


                    ○  redis          down       dependency
                    ✗  be-orders      crashed    exit 1 · 18:47  ⚡12
                    ⠙  be-billing     starting   8s so far
                  ✓ ●  be-sales       up         1h6m  900M  4%


  q  quit   z  leave zen   ␣  mark   s  stop   r  restart   l  logs
```

Dependencies that are down are rows in that list rather than a rule above it —
a dead postgres is usually the reason for the six services under it, so it
sorts to the top where the cause belongs. Everything else sorts worst-first,
stably, so `o` still decides the order inside each band. Gauges, legend and
graphs are gone: history is what you look at when you are watching something,
not when you are deciding whether anything needs you.

It is also the **focus** mode, and deliberately the same key. Anything you
`space`-marked stays visible in zen even when it is perfectly healthy — that
is *"I am working on this one"*, which is the other half of the same question.
So `space` on the app you are working on, then `z`, gives you that app plus
anything that breaks, and nothing else. An active `/` filter does the same.

When there is genuinely nothing, the screen says **nothing needs you** — with
the count of what is fine under it, the one place in the mode where that number
earns its line, and with the verdict row suppressed because it would be the
same sentence twice:

```
                              nothing needs you
                               6 up · 2 deps up
```

The title rule reads `── project zen ──` instead of `live`, and `q quit` and
`z leave zen` stay in the hint row: a mode that hides the way out of itself is
a trap rather than a mode.

Start there with `PITCREW_ZEN=1 pitcrew watch`.

| Variable | Default | Purpose |
|---|---|---|
| `PITCREW_ZEN` | `0` | start the dashboard in zen mode |
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
| `PITCREW_PICKER` | auto | `fzf` or `plain` — force one menu picker instead of using fzf when it is installed |
| `PITCREW_ERROR_PATTERN` | `ERROR\|FATAL\|Exception\|UnhandledRejection` | what the error radar counts |
| `PITCREW_HEALTH_INTERVAL` | `5` | seconds between health probes (×3 once a service reports UP) |
| `PITCREW_HEALTH_TIMEOUT` | `5` | seconds a health probe may take before it counts as unanswered |
| `PITCREW_DEP_INTERVAL` | `10` | seconds between docker dep checks |

`NO_COLOR` (or `PITCREW_NO_COLOR`) drops every colour.

```bash
pitcrew theme              # every theme, drawn in its own colours
pitcrew theme tokyonight   # switch, and remember it for next time
pitcrew theme --reset      # forget the saved choice
```

Or press `m` in the dashboard and pick **change theme…** — with fzf the
preview draws each palette as you move through the list; choosing one applies
it immediately and remembers it either way.

Four settings decide the theme, most specific first: `PITCREW_THEME` in the
environment (a one-off for this run), `PITCREW_THEME` in the project's
`pitcrew.yaml` (so a repo can look the same for everyone who opens it),
the saved preference from `pitcrew theme <name>` (how you like your terminal),
and finally the built-in palette.

Colours are addressed by **role**, not by hue — `C_CRIT`, `C_MUTED`,
`C_SURFACE` rather than `RED`, `GREY`. A theme is still a plain bash file, and
it sets nothing but hex values; pitcrew converts them to 24-bit, to the 16
ANSI colours, or to nothing at all depending on what the terminal reports. One
theme file therefore works everywhere, including an old ssh target. See
[`themes/default.sh`](themes/default.sh) — five lines.

A palette has two kinds of colour in it, and they answer different questions:

* **`T_OK` / `T_WARN` / `T_CRIT`** are a verdict you *read*. Green, amber and
  red are words here — a state, a badge, a RAM figure beside its cap.
* **`T_G1`…`T_G4`** are the graph ramp, cool at the bottom to hot at the top,
  for anything *drawn*: a bar's fill, a gauge, a sparkline cell.

Bars come from the ramp, and that is the part of a palette that is genuinely
its own — teal → pine → gold → rose in Rosé Pine, aqua → lime → yellow → red in
Gruvbox, four flat greys in `mono`. Drawn from ok/warn/crit instead they looked
near enough identical in every theme, because every theme's ok/warn/crit is
some green, some amber and some red. Both scales still agree about *level*, so
a graph and the figure beside it never disagree about how full something is.

Graphs are coloured by each cell's **height**, so a climb is legible before you
read a number. Height auto-scales to the series; how close a service is to its
configured RAM cap moves to the colour of the number, which is where you look
for it anyway.

The picker `m` opens is drawn in the theme too — the prompt, the pointer, the
selected row. If you have set `--color` yourself in `FZF_DEFAULT_OPTS`, that
wins and pitcrew leaves it alone.

## Desktop app

`gui/` is a GTK4 / libadwaita front-end: an **Overview** that opens on the
verdict — what is wrong, what is holding the memory, and what is safe to stop —
then a component list, a Resources view of live CPU and memory graphs, and a
Projects view that manages the registry.

Every number and every judgement on screen arrives through `pitcrew json
--watch`. The GUI never reads `/proc`, never runs `ps`, and never decides for
itself whether the stack is healthy — it is a renderer for the state object,
which is why it and the terminal dashboard cannot disagree.

```bash
make install-gui     # symlink, plus whatever this OS uses to list apps
pitcrew-gui          # or launch "pitcrew" from the app grid / Launchpad
```

### What is reachable from the app

Everything the CLI does, apart from the things a window genuinely cannot host:

| | |
|---|---|
| Start / stop / restart | per component, per app group, whole stack, or a profile |
| Dependencies | start and restart from the row that shows they are down |
| Process tree | in a component's detail dialog, live, biggest first |
| Diagnostics | the Overview verdict, plus **Full diagnostics** for the slow checks |
| Recovery | idle candidates with a stop button, and what is 🔒 protected |
| Stale code | a finding with a **Restart stale** button |
| Doctor | rendered as rows, not pasted terminal output |
| RAM caps | per component, machine-local |
| Profiles | on the Overview with live counts, **Alt+1…9**, save what is running, delete |
| Projects | add, switch, edit config, forget |
| Ports · plugins · shells | one **Tools** dialog |
| Logs | live tail, filter, errors-only, and any of them in its own window |

Terminal-only by nature: `pitcrew render` (it styles the terminal dashboard's
graphs), the `menu`, and actually *running* a `shell` — a GTK window cannot
host an interactive `psql`, so Tools hands you the exact command to paste
instead of pretending.

The **project selection is shared**, the same way. The app opens on whatever
`~/.config/pitcrew/current` names, and switching project in its header writes
that file through `pitcrew use` — so the window reopens where you left it, and
a terminal in the same session is looking at the same project.

The **theme is shared**. The app draws its meters, graph series, state dots,
verdict tint and log palette from whichever theme `pitcrew theme` last saved,
and Preferences (`Ctrl+,`) has a picker that writes the same
`~/.config/pitcrew/theme`. Change it on either side and the other follows
without a restart — an open window repaints when the file changes under it.

Light and dark still belong to your desktop. Every theme pitcrew ships is a
dark one, because a terminal is dark, so on a light desktop the palette is
darkened to stay legible rather than being replaced by something you did not
pick. Window chrome — buttons, rows, headers, your accent colour — stays
Adwaita's throughout.

A finding's suggested command becomes a **button** where pitcrew is willing to
run it. The `fix` string is never handed to a shell: it is split, checked
against a small list of verbs (`logs`, `start`, `stop`, `restart`,
`stale --restart`) over component names, and run as argv or shown as plain
selectable text. A plugin can put anything in that field, so anything else —
`pitcrew limit`, a path, an option — stays text.

| | |
|---|---|
| **Linux** | a `.desktop` entry and a hicolor icon, per XDG |
| **macOS** | a `.app` bundle in `~/Applications`, for Launchpad and Spotlight |
| **Windows** | a **Start Menu entry and a Desktop icon**, launched with `pythonw` so no console sits behind the app. Needs MSYS2's GTK stack (below) |

### Windows, as an app rather than a script

Install [MSYS2](https://www.msys2.org), open the **UCRT64** shell (not the
plain MSYS one — the GTK stack lives in a per-environment prefix), and:

```bash
git clone https://github.com/zorigtbaatarAst/pitcrew.git ~/pitcrew
cd ~/pitcrew && ./setup.sh --yes
```

That is the whole thing: it installs PyGObject, pycairo, GTK 4 and libadwaita
through `pacman`, puts `pitcrew` on your `PATH`, and writes **two shortcuts** —
one in the Start Menu and one on the Desktop, both pointing at `pythonw.exe`,
which is the difference between an app with a taskbar icon and someone's script
with a black console window parked behind it.

To do it by hand instead:

```bash
pacman -S mingw-w64-ucrt-x86_64-python-gobject \
          mingw-w64-ucrt-x86_64-python-cairo \
          mingw-w64-ucrt-x86_64-gtk4 \
          mingw-w64-ucrt-x86_64-libadwaita
./install.sh              # the pitcrew command
./gui/install.sh          # the shortcuts
```

> The prefix is `mingw-w64-ucrt-x86_64-`, not `mingw-w64-ucrt64-x86_64-`. This
> README said the latter for a while; no such package exists, so the documented
> install failed on the first line.

Two things are worth knowing before you decide this is what you want.

**It will not look like a Windows program.** libadwaita is GNOME's design
language and does not try to blend in; you get GNOME-shaped controls in a
Windows window manager. That is a taste question, not a bug.

**The engine is still bash.** pitcrew's 7,000 lines of shell are the product;
the GUI is a renderer for `pitcrew json --watch`. So there is no version of
this that does not need Git Bash or MSYS2 underneath — a "pure native" app
would mean rewriting the engine, not repackaging the front end. What the
platform layer does is name the interpreter explicitly, because Windows has no
shebang: handing `CreateProcess` a file starting with `#!` fails with "not a
valid application", which from a GUI with no console attached is a button that
does nothing at all.

If you want to hand this to someone who has no MSYS2 at all, that is a
different job — bundling GTK4, Python and a portable Git into one installer
(~250 MB, and re-bundled on every release). Worth doing only if Windows becomes
a first-class target rather than a supported one.

Windows is now built and installed **in CI on a real MSYS2**: the dependency
installer runs, `setup.sh` runs, and the job fails unless both `pitcrew.lnk`
files are actually on disk afterwards. What is still unverified is what the app
looks like once it opens, and how it behaves against a real running stack.

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
  to answer "is sales up" — and groups with **nothing running fold themselves**,
  keeping their summary and their buttons. Clicking a fold pins it for the
  session, so a group you just opened does not shut on the next frame.
  `--collapse never` turns the automatic part off
- a **share-of-memory ring** ranks what is actually eating the stack, with the
  project total in the middle. The line graphs answer "is this climbing"; they
  are bad at "which of these twelve is the problem", because a 3 GiB frontend
  and a 300 MiB worker are both just lines
- **click a legend entry to mute its line.** It drops out of both graphs and
  the ring, and stays listed (dimmed) so you can bring it back — hiding a
  toggle's own off-switch is how a toggle becomes a trap
- the Resources graphs have a **hover readout**: a crosshair, a dot on every
  series, and a panel naming each one and its value at that sample. It reads
  the *nearest* sample rather than nothing, because early on the line only
  occupies the right edge of the plot
- the port on a running row is a **button**: it opens the real URL, including
  the `--url-path` every backend sits behind, and backends with a configured
  health path say `health ✓`
- **`n` errors** is a button too — it jumps to that component's log with
  errors-only on
- group headings **start / restart / stop a whole app**, and the menu has
  **Start everything**, **Stop everything**, and your saved **Profiles**
- the log view has a **filter box** and an **errors-only** toggle, both of
  which work on a live tail
- **any log can be pulled out into its own window** — the ⧉ button on a
  component row, or the one in the Logs toolbar for whatever is selected. It is
  the same view, fed the same frames, so it keeps following live; a log is
  something you read *while* restarting the thing that writes it or editing the
  config that starts it, and in one tab of one window it is the only thing you
  can be looking at. One window per component (asking twice raises the one you
  have), and they close when you switch project, because a detached log belongs
  to the project it came from
- **zen mode** (`Ctrl+Z`, or the menu) — the same idea as the terminal's `z`,
  and the same layout change. Healthy components, dependencies that are up, the
  machine meters and the consumer ranking all go; the verdict, the findings and
  anything broken stay. Components becomes **one flat list** — no group
  headings, no column header, deps at the top, worst first — because a heading
  over a group of one is the same noise as a column header over a single row.
  The content column narrows to something you read in one go and the Overview
  centres in the window. The view switcher does *not* go: navigation is not
  chrome, and a focus mode you cannot leave is a trap. An accent `zen` pill in
  the header says you are in it, and clicking it gets you out
- **keyboard**: `Ctrl+1…4` for views, `Alt+1…9` to start a saved profile,
  `Ctrl+Z` for zen, `/` to filter the log, `Ctrl+M` for RAM caps,
  `Ctrl+Enter` to start everything, `?` for the list
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
  a repo's own config only records the root and points at it, so the editor
  opens the file in the repo, not the stub that points at it.
- **Watch** makes a project current; **Forget** drops it from the registry after
  a confirmation, leaving the checkout alone.

#### Editing the config

A YAML config opens on a **form**: one group per app, one expander per
component, with its command, its checkout, its directory, port, health path and
RAM cap — plus a switch for `enabled:` on the row itself, because that is the
one field you flip without wanting to read anything else. **+** on a group adds
a role. A **YAML** tab sits next to it for anything the form does not cover;
it is highlighted as what it is — YAML for a `pitcrew.yaml`, shell for a
`pitcrew.config.sh` — wherever GtkSourceView is installed, and Tab inserts
spaces there, because pitcrew's loader rejects a tab used for indentation.

**Add an app** asks pitcrew what is in the checkout. It runs `pitcrew detect
--json` and offers what came back — every app the config does not already have,
each with the command, port and health path `init` would have written — with a
switch per app and an **Empty app…** way out for a project no detector could
guess. It used to ask for a name and write `cmd: "true"` under it, which left
the actual work (the gradle task, the port, the health path) to be typed by
hand for a project pitcrew can read perfectly well.

The editor and the output panel below it share the height through a handle you
can drag: `doctor` reports every port this machine argues with itself about,
and a dialog cannot be resized, so a fixed strip meant reading that six lines
at a time.

Two things it deliberately does not do.

**It does not regenerate the file.** Every field you change becomes the
smallest possible edit to the text — one line replaced, or one pair inside a
`{ … }` — so comments, blank lines, key order and the block-vs-flow style each
component happens to be written in all survive untouched. A config is something
people write and annotate, and an editor that rewrites it wholesale hands back
a version with every comment gone. That is not a save, it is a replacement.

**It does not parse YAML.** `lib/18-yaml.sh` is the one definition of the
subset pitcrew accepts, and a second parser here would sooner or later accept a
file the tool rejects — or, worse, silently misread one and save it back. Every
value on the form arrives over `pitcrew config --json`, which is pitcrew
reading its own config; the GUI only ever finds the *line* a field lives on.

A **bash** config gets the text editor and no form: a `pitcrew.config.sh` is a
sourced shell script that may branch, loop or source something else — the
autoland one builds its apps from a `for` loop over a `declare -A` of ports —
and a structured editor that could not round-trip that would quietly drop it.

Either way nothing is written that the tool cannot load: `pitcrew check` for a
`.yaml`, `bash -n` for a `.sh` (a config that will not parse breaks every
pitcrew command for that project, including the one that would tell you why).
**Check** runs `pitcrew doctor` against it.

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

**GtkSourceView is the one optional entry.** It is what highlights a config in
the editor. It is installed for a new install and reported (not demanded) for
an existing one: without it the config opens in a plain text view, which is a
worse editor and a working app.

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

Fedora, Homebrew and MSYS2 are run in CI. The remaining tables are written
from the documented package names and are unverified — which is the other
reason the command is printed before anything happens.

Which python it asks is one file, `gui/pyfind.sh`, shared by `setup.sh`,
`gui/install.sh`, `gui/install-deps.sh` and the test suite. It had been copied
into all four, every copy looking only in Unix places, and on MSYS2 — where
the GTK stack lives in a `$MINGW_PREFIX` and `/usr/bin/python3` is a different
interpreter that will never have `gi` — all four agreed the bindings were
missing on a machine that had just installed them.

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
  health endpoint reports `"UP"`, **or the boot window has passed**. A health
  path answers "the port is open, but is it *ready*", which is a question about
  a boot: past `wait` × `PITCREW_SLOW_START_MULT` the port is the verdict, and
  an endpoint that still disagrees becomes an `unhealthy` finding naming the
  status it answered with (`503`, or `404` for a path that points at nothing).
  Letting it gate "up" indefinitely meant a service that had been serving
  traffic for an hour still read "starting", with a spinner. Anything else is
  "starting" while the pidfile's process is alive, or "crashed" if it died on
  its own (a leftover pidfile pointing at a dead pid). A component with no
  start command configured for that role is "n/a", not "down".
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
