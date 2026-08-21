# pitcrew — briefing for an AI agent working in this repo

Read this before touching anything. It is the set of facts that are expensive
to rediscover and the constraints that will bite you if you don't know them.

## What this is

A config-driven local dev-stack launcher for multi-service monorepos. You
describe N named apps, each with up to two roles — `be` (backend) and `fe`
(frontend) — plus some docker containers. `pitcrew` starts them as plain
background processes, RAM-capped via `systemd-run --user --scope` where
systemd exists, and draws a live terminal dashboard with per-service RAM/CPU
meters, an error radar over the logs, and fzf menus.

**No terminal multiplexer, no daemon, no session to attach to.** Each component
is a backgrounded `bash -c` with a log file and a pidfile under
`<root>/.pitcrew/logs/`. State is inferred from those files plus the OS, every
frame. There is nothing to keep in sync because nothing is kept.

Written in bash 5. ~7,000 lines of shell in `lib/` (26 files), ~3,000 lines of Python in
`gui/` (an optional GTK4 desktop front-end). Zero runtime dependencies beyond
bash — `docker`, `fzf`, `lsof`, `systemd` are each optional and degrade with a
message rather than an error.

## The hard constraints

These are not style preferences. Violating them produces bugs that are hard to
attribute, and most are pinned by a test.

1. **`bin/pitcrew` must stay parseable by bash 3.2.** macOS ships 3.2, and bash
   parses a whole script before running a line of it — so one `declare -A`,
   `mapfile` or `${x^^}` in that file and the "you need bash 5" guard never
   gets to print. `lib/*.sh` is sourced after the guard and is unrestricted.
   CI runs `/bin/bash ./bin/pitcrew help` on a real macOS 3.2 to check this.

2. **A `.sh` config must be `source`d at the caller's top level, never inside a
   function.** bash scopes a bare `declare -A` in a sourced file to the running
   *function*, so a project's `declare -A PITCREW_BE_CMD=(...)` would be
   silently created and discarded. `bin/pitcrew` sources it at script top level;
   `lib/15-registry.sh` does it inside `( )` subshells. Switching project in a
   running dashboard therefore `exec`s instead of re-sourcing. The YAML loader
   has no such hazard (it only assigns into arrays `config_defaults` already
   created with `declare -gA`), which is why it can be a plain function.

3. **`lib/*.sh` load order must not depend on locale.** `for f in lib/*.sh`
   sorts by collation, and UTF-8 collation ignores punctuation — so `05-x.sh`
   sorts *after* `05a-y.sh` on a desktop and *before* it under `LC_ALL=C`. Rule:
   never add a bare `NN-name.sh` that shares its number with an `NNx-name.sh`.
   `test/liborder_test.sh` enforces it. Files in the `03`–`05` group have
   top-level code that reads what the previous file set.

4. **No forks in the frame loop.** On Linux a dashboard frame forks *nothing*
   (everything comes out of `/proc` with bash builtins). On macOS it costs
   exactly two forks per frame regardless of service count (one `ps` sweep, one
   port listing). If you add a `$(...)`, a pipe or an external command to
   anything reachable from `snapshot`/frame rendering, you have regressed the
   product's main claim. Pre-resolve into caches at config-load time instead —
   see `COMP_MAX_B`, `PITCREW_COMPS`, `APP_ICON`.

5. **All OS knowledge lives in `lib/00-platform.sh`.** Nothing else may branch
   on `uname`. `PITCREW_FORCE_COLLECTOR=ps` runs the macOS collector on Linux,
   and CI runs the entire suite that way, so the portable path can't rot.

6. **No GNU coreutils assumptions.** No `readlink -f`, no `timeout`, no
   GNU-only `sed`/`grep` flags. BSD `sed` does not understand `\+`. A stock
   macOS must work after only `brew install bash`.

7. **The JSON contract is versioned separately.** `schema` in
   `pitcrew status --json` / `pitcrew json`. Bump it only when a field is
   removed or changes meaning; adding fields is free. `test/output_test.sh`
   pins the exact key set, so add new fields there in the same change.

8. **The GUI is a renderer, not a second monitor.** Everything it shows arrives
   through `pitcrew json --watch`. It must never read `/proc`, run `ps`, or
   decide for itself whether the stack is healthy — the verdict travels in the
   stream's `health` object for exactly that reason. If the GUI needs something
   it does not have, extend the state object; do not re-derive it in Python.
   `model.py` is pure presentation (no GTK, no OS calls) and is where testable
   logic goes.

## Layout

```
bin/pitcrew        arg parsing, the bash-5 guard, self-symlink resolution,
                   config load sequence, command dispatch. Nothing else.
lib/00-platform.sh the only file that knows which OS it is running on
lib/01-core.sh     styling, printing helpers (say/ok/warn/bad/die), themes
lib/02-config.sh   find + load a config, defaults, the app/role helpers
lib/18-yaml.sh     the YAML front end (parser + schema) and `pitcrew check`
lib/03a-snapshot.sh one cheap pass per frame answering every state question
lib/03b-state.sh   up / starting / crashed / down / n-a for one component
lib/04-meters.sh   raw numbers -> sparklines, gauges, RAM cells
lib/05a..05d       dashboard viewport, service cells, one frame, the live loop
lib/06-targets.sh  CLI words ("all", "backends", "sales", "@profile") -> comps
lib/07a-start.sh   launching, and the wait-dashboard shown while booting
lib/07b-supervise.sh optional auto-restart with backoff (dashboard-only)
lib/08-stop.sh     stopping tool-managed AND externally-started processes
lib/09-stale.sh    components whose source changed since they started
lib/10-profiles.sh named saved sets of targets
lib/11-logs.sh     in-place log viewer, and `pitcrew shell <name>`
lib/12-doctor.sh   environment checks, then the project's own
lib/13-menu.sh     the fzf action picker
lib/14-detect.sh   look at a repo and work out what it is
lib/14-init.sh     `pitcrew init` — write a config that actually runs
lib/15-registry.sh ~/.config/pitcrew/projects/, the project registry
lib/16-output.sh   `status --json`, `json --watch`, `wait`, `ps`, `urls`
lib/17-limits.sh   per-component RAM caps (machine-local overrides)
lib/19-diag.sh     diagnostics: the check registry, the core checks, `diagnose`
gui/pitcrewgui/    GTK4 + libadwaita desktop app, consumes `json --watch`
themes/            colour palettes
test/              a ~70-line assert harness and 20 test files
```

## Diagnostics vs doctor

Two commands, two questions, and confusing them is the easy mistake:

- `pitcrew doctor` — is this **environment** able to run pitcrew? bash version,
  fzf, systemd, docker daemon, whether the caps fit the machine. Static.
- `pitcrew diagnose` — is this **stack** healthy right now? crashes, memory
  pressure, stuck boots, what is safe to stop. Derived from a live snapshot.

A project's own checks hang off `doctor` (`pitcrew_doctor_extra`, or `doctor:`
in YAML). Runtime judgements go in `lib/19-diag.sh`.

## The config model

**One model, two formats.** The model is a set of `PITCREW_*` bash variables:
`PITCREW_APPS` (ordered) plus associative arrays keyed by app name
(`PITCREW_BE_CMD`, `PITCREW_FE_PORT`, `PITCREW_BE_HEALTH_PATH`, …). A role
exists for an app **if and only if** it has a start command — that is the whole
of the asymmetric-role design. A missing role renders as `n/a`, is never
started, and is never counted as down.

- `pitcrew.yaml` — the default, parsed by `lib/18-yaml.sh` into those same
  variables. Schema: `examples/pitcrew.yaml`.
- `pitcrew.config.sh` — bash that sets them directly. Still supported, not
  deprecated: a config that must branch on the machine, or define a real
  `pitcrew_doctor_extra()`, *is* a shell script. Schema:
  `examples/pitcrew.config.example.sh`.

Everything below `lib/02-config.sh` is format-blind. If you add a config
feature, add it to the model and both front ends, and assert the two agree
(`test_the_two_formats_describe_the_same_project` in `test/project_test.sh`).

Resolution order, first hit wins: `-C <dir>` · `-p <name>` · `$PITCREW_CONFIG`
· a config walked up from `$PWD` · a registered project containing `$PWD` ·
whatever `pitcrew use` last selected. An in-project config outranks the
registry. Where a directory holds both formats, YAML is read and pitcrew says
so rather than choosing silently.

`ROOT` must be known **before** the config is read (paths resolve against it,
and `.sh` start commands expand `$ROOT` at source time), so
`config_declared_root` reads the root out textually without loading the file.

### The YAML parser

Hand-written, ~200 lines, in `lib/18-yaml.sh`. Deliberately not python/yq: a
config format that needs a package installed is a config format that fails on
the box you actually have to work on.

Supported subset: block mappings nested by space indentation, block and flow
sequences of *scalars*, quoted scalars, `|`/`>` block scalars, comments,
`include:`. **Rejected with a file and line number**: tabs for indentation,
anchors/aliases/merge keys, flow mappings, tags, sequences of mappings, a
missing space after `:`. Refusing loudly is the design — a parser that
half-reads a start command is worse than one that reads none.

Two stages: `yaml_parse` flattens the document into `YAML_KEYS`/`YAML_VALS` as
dotted paths in document order (app ordering comes from that order), then
`yaml_config_load` maps those paths onto the model and **warns on any key not
in the schema, quoting its exact path**. That typo-catching is the main reason
YAML exists here, not the syntax.

Only `$ROOT` and `$HOME` are expanded at load time; every other `$VAR` is left
literal and reaches the shell that runs the command. `dir:` is relative to the
root and becomes a correctly-quoted `cd` in front of the command; it is also
what `watch:` defaults to.

## The one extension point

`lib/19-diag.sh` is the only plugin seam in the codebase, and it is deliberately
small. A check is a function that reads the snapshot and calls `diag_add`:

```bash
diag_add <crit|warn|info> <id> <title> <detail> [fix-command] [scope]
diag_register my_check
```

`diag_run` executes every registered check in order and leaves findings in the
`DIAG_*` arrays, a verdict in `DIAG_VERDICT` and a headline in `DIAG_HEADLINE`.
Four surfaces read those and nothing else — the dashboard's verdict line and `d`
panel, `pitcrew diagnose`, the `health` object in `pitcrew json`, and the
desktop app's Overview. A check added anywhere appears in all four without
touching any of them. The built-in checks use the same call a plugin would;
there is no privileged path.

Rules if you work here:

- **`diag_run` is called once per dashboard frame**, so checks obey the frame
  loop's no-fork rule: array reads and arithmetic only. `human`, `dur_human`,
  `pct_color` and `bar` set a global instead of printing precisely so they can
  be used from here.
- **Never claim more than was measured.** `SNAP_IDLE` is "seconds observed
  quiet by *this* pitcrew process" — minutes in a dashboard, seconds in a
  one-shot `diagnose` — so findings print the evidence (`quiet 41m · up 3h20m`)
  rather than rounding it into an assertion. A recovery candidate must be both
  quiet and old, and even then pitcrew proposes and the person decides.
- **Do not grow this into a plugin loader** until something outside this
  repository needs to register a check. A registry of functions over a shared
  snapshot is the smallest honest version of the boundary; anything more is
  speculative architecture.

Feature-specific intelligence belongs in a check, not spread through core. If
you find yourself adding an "is this bad" judgement to the renderer, the JSON
writer or the Python, it belongs here instead.

## Conventions this codebase actually holds to

- **Comments explain WHY, not what.** Nearly every non-obvious line carries the
  bug or constraint that put it there. Match this density; a patch of
  uncommented clever code will look wrong next to it.
- **Warn, never die, on anything merely unusual.** `config_validate` prints
  warnings for typo'd app names, duplicate ports, an app with no command. Only
  a genuinely unloadable config exits.
- **Errors never pass silently.** If a value is ignored, say so and say why
  (e.g. a health path on a frontend role explains that an open port is what
  makes a frontend up).
- **Say what is not true.** `doctor` states plainly that RAM caps are budgets,
  not limits, on macOS, rather than letting identical-looking meters imply
  enforcement.
- **A cap is a property of the machine, not the project.** Per-component
  overrides live in `~/.config/pitcrew/<session>/limits`, never in the repo's
  config. Resolution: machine-local override -> per-app cap -> role default.
- **Derived values are rebuilt after the config loads.** Themes, icon tables
  and render settings are resolved from env at lib-source time, i.e. *before*
  the project config is read; `config_finalize` re-runs `icons_load`,
  `theme_load` and `render_resolve` so a project can pin how it is drawn.

## Working on it

```
make test              # 19 files, own harness, no dependencies
make test T=yaml       # only files matching 'yaml'
make lint              # bash -n everything, then shellcheck + ruff if present
make check             # lint + test — what CI runs
./bin/pitcrew check <file>   # load a config and report what is wrong with it
```

`test/perf_test.sh` asserts **zero forks** across 25 frames and is the guard on
constraint 4 — run it after touching anything in the render or snapshot path.

Tests: a function named `test_*` in a `test/*_test.sh` file. Each file runs in
its own process because loading a config mutates many globals. Assertions
record failures instead of aborting, so one test can report several problems.
`assert_ok`/`assert_fails` take a **command** and run it in a subshell — `die()`
calls `exit`, so isolation is not optional. Fixtures: `test/fixture/` (bash) and
`test/fixture-yaml/` (YAML), both deliberately covering the awkward shapes
(both roles, backend-only, frontend-only, health on one backend only).

`shellcheck --severity=warning` is the gate. At `style` it produced 58 findings,
43 cosmetic, so the check was always red and nobody read it — anything at
warning or above now fails, anything below is fixed or annotated at the line
with why.

CI (`.github/workflows/ci.yml`) runs: lint+test on Linux, the whole suite again
with `PITCREW_FORCE_COLLECTOR=ps`, lint+test on real macOS, the GUI tests on
both OSes with the real GTK bindings, `setup.sh` from a clean checkout, and the
bash-3.2 guard against real `/bin/bash` on macOS.

## Known warts

- Several `lib/` files have a stale filename in their own header comment
  (`05a-cells.sh` is really `05b-cells.sh`, `05-targets.sh` is `06-targets.sh`,
  `09-profiles.sh` is `10-profiles.sh`). Comment drift only.
- Both `README.md` and `pitcrew help` call `PITCREW_BE_MAX` / `PITCREW_FE_MAX`
  / `PITCREW_WAIT` "env overrides", which reads backwards. `config_defaults`
  seeds them from the environment, then the config file is read and its value
  wins. Both config formats behave identically; the wording is the problem.
- `pitcrew edit` opens the registry entry, not the repo's own config it points
  at. The GUI follows that indirection; the CLI does not.
