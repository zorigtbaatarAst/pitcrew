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

   Three targets: linux (`/proc`, zero forks), macos/bsd (`ps`+`lsof`, two
   forks), windows (Git Bash or MSYS2 — `wmic`/PowerShell + `netstat`). Windows
   works by making `PITCREW_PS` point at a shell FUNCTION that emits the exact
   columns the portable collector already parses, so there is no third
   collector. Any native output that has to be interpreted goes through a pure
   filter (`_wmic_ps_parse`, `_netstat_*_parse`, `_vm_stat_avail_kb`) so it can
   be tested on a machine that has never seen that OS — that pattern is the
   only reason the macOS and Windows paths are verifiable at all. The Windows
   integration is **untested on real Windows**; the parsers are not.

6. **No GNU coreutils assumptions.** No `readlink -f`, no `timeout`, no
   GNU-only `sed`/`grep` flags. BSD `sed` does not understand `\+`. A stock
   macOS must work after only `brew install bash`.

7. **`lib/16-output.sh` is a frame loop too.** `json --watch` is the desktop
   app's whole data path and a status line's polling loop, so the no-forks rule
   applies there exactly as it does to the dashboard. The encoders
   (`_json_str`, `_json_num`, `_json_cpu`, and `comp_max_source`) SET A GLOBAL
   and print nothing — calling any of them as `$(...)` puts back the 295 forks
   and 176ms an object this cost before, invisibly, because the output is
   identical either way. `test/perf_test.sh` fails if you do.

8. **The JSON contract is versioned separately.** `schema` in
   `pitcrew status --json` / `pitcrew json`. Bump it only when a field is
   removed or changes meaning; adding fields is free. `test/output_test.sh`
   pins the exact key set, so add new fields there in the same change.

9. **The GUI is a renderer, not a second monitor.** Everything it shows arrives
   through `pitcrew json --watch`. It must never read `/proc`, run `ps`, or
   decide for itself whether the stack is healthy — the verdict travels in the
   stream's `health` object and the process tree in `components[].processes`
   for exactly that reason. If the GUI needs something it does not have, extend
   the state object; do not re-derive it in Python. `model.py` is pure
   presentation (no GTK, no OS calls) and is where testable logic goes.

   **libadwaita 1.5 is the floor** (`platform.ADW_MINIMUM`) — what Ubuntu 24.04
   LTS ships. A widget from a newer version does not raise, GTK *aborts the
   process*, so this is checked before any window is built. Check what the LTS
   has before reaching for something new; `AdwToggleGroup` (1.7) cost the app
   the ability to start on the most common Linux desktop.

   **Do not put a view inside `AdwPreferencesPage` if it has columns or
   figures.** That widget carries its own ~600px clamp which cannot be widened,
   and it is what left half of every window empty. Use a Box in an `Adw.Clamp`
   with `Adw.Breakpoint` for the narrow case; `AdwPreferencesGroup` works fine
   standalone. `style.py` holds the small amount of CSS Adwaita has no opinion
   about — everything else should be an Adwaita style class so the app follows
   the user's theme and accent.

   Colour means **one** thing: `model.RAMP` plus `meter_level()` for resources,
   and `STATE_STYLE` / `VERDICT_STYLE` draw from the same ramp. Do not
   introduce a second palette; the last one (stock LevelBar orange) made a
   32%-full meter and a warning badge the same hue.

   Log text arrives with **ANSI escapes in it** — pitcrew captures stdout
   verbatim. `ansi.py` turns SGR into span tags and drops everything else; it
   is pure (no GTK) and tested. Do not "simplify" it into a strip, and do not
   render raw lines into a TextView.

   **Never use `Gio.DataInputStream.read_line_async` on a pipe.** It reports
   EOF as `(b"", 0)` and a blank line as `(b"", 0)`, so any code built on it has
   to choose between stopping at the first empty line and spinning the main
   loop at EOF. `runner.LineReader` reads raw bytes and splits lines itself;
   use it. Three separate "the log view is frozen" bugs came out of that one
   ambiguity.

   **Never build a pitcrew argv by hand** — use `platform.cli_argv`. On Windows
   the CLI is a bash script and the path alone is not executable, so a literal
   `[self._pitcrew, ...]` is a button that silently does nothing there. A test
   greps for it.

   For one-shot answers the GUI may shell out through `Runner.run_json`
   (`doctor --json`, `diagnose --json`) — that is rendering the CLI's answer,
   not computing its own. A finding's `fix` string is checked by
   `model.fix_action` against a whitelist of verbs and run as **argv**, never
   through a shell: plugins write that field.


## The Rust port

There is a Rust rewrite in progress under `crates/`. **Both implementations are
live**: `bin/pitcrew` + `lib/` is still the working tool, and the Rust tree is
built up phase by phase behind it. Do not delete bash files as their Rust
counterpart lands — the parity check depends on being able to run both.

```
crates/pitcrew-model/     the JSON contract, as serde types            done
crates/pitcrew-platform/  processes, ports, memory, RAM caps           done
crates/pitcrew-core/      config, targets, profiles, limits, registry,    done
                          state, snapshot, lifecycle, health, diag,
                          idle, errscan, deps
crates/pitcrew-cli/       start · stop · restart · status[--json] ·       partial
                          json[--watch] · diagnose · doctor · check ·
                          urls · ports · projects · limits · profile
```

**The Rust CLI satisfies the JSON contract.** `pitcrew status --json` and
`pitcrew json --watch` produce the same schema-1 object the bash tree does —
key sets and values verified identical on `test/fixture-yaml` — and the
**unmodified Python GUI and all 108 of its tests pass against the Rust
binary**:

```
ln -sf $PWD/target/debug/pitcrew /tmp/bin/pitcrew
PATH=/tmp/bin:$PATH bash test/run.sh gui     # 108 run, 0 failed
```

Keep that working. It is the only end-to-end check that both implementations
still mean the same thing, and it costs one symlink.

Phases still to come: config detection and `init` (the rest of 2), diagnostics
and JSON
output (4), TUI (5), GTK GUI (6), distribution (7). The plan lives outside the
repo; the phase numbering in the code comments refers to it.

Three things to know before touching any of it:

1. **`crates/pitcrew-model/tests/contract.rs` is the parity gate.**
   `tests/golden/*.status.json` is real captured output from the bash tree. The
   test round-trips it through the Rust types and deep-compares, so a field bash
   emits that Rust does not model fails by name and JSON path. Refresh the
   golden files by re-running `./bin/pitcrew -C <fixture> status --json`.

2. **The no-forks-per-frame rule (constraint 4) does not apply to the Rust
   tree** — but the behaviour it forced still does. Batched dependency checks,
   throttled health probes, incremental log reads and slow-clock swap sampling
   were all good decisions that a fast language no longer forces. Re-derive them
   deliberately; the naive "poll everything every frame" version is fast enough
   to ship and measurably worse for the machine being monitored.

3. **The YAML parser is hand-written on purpose, and its refusals are the
   feature.** `crates/pitcrew-core/src/yaml.rs` implements the same narrow
   subset `lib/18-yaml.sh` does, for the same reason: a general YAML parser
   reads `port:8080` as the plain scalar `"port:8080"`, which is a typo that
   then renders as a component with no port and no complaint. Both parsers are
   verified byte-identical on `test/fixture-yaml/pitcrew.yaml` and
   `examples/pitcrew.yaml` — `cargo run -p pitcrew-core --example dump -- <file>`
   emits the same flattened `path=value` lines as `yaml_parse`, so a divergence
   is one `diff` away. Keep it that way while both exist.

4. **A start command reaches a shell as ONE string, always.** Configs contain
   `cd web && { [ -d node_modules ] || npm install; } && npm run dev`, and the
   role `env:` prefix is folded in front by concatenation — it is only an
   assignment because a shell parses it there. `lifecycle` also runs that
   command in a NESTED shell rather than inlining it into the wrapper: the
   wrapper is a background subshell, so an inlined `exit 3` would exit the
   wrapper and skip the exit record, which is the one thing the wrapper exists
   to write.

5. **`crates/pitcrew-platform` inherits constraint 5 verbatim.** A
   `cfg(target_os)` anywhere outside that crate is a bug, for the same reason a
   `Darwin` case outside `lib/00-platform.sh` is.

New in the port, and not available from bash: **RAM caps are enforced on
Windows** via a named Job Object (`caps::apply_job_object`), which is the direct
analogue of the systemd scope — `stop` re-opens it by name and terminates the
whole job. That code is compile-verified in CI on `windows-latest` and has not
been run against a real capped runaway process. macOS still cannot enforce a cap
and `Enforcement::explain()` says so.

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
lib/20-plugins.sh  finding and attributing plugins (they are SOURCED by bin/)
examples/plugins/  worked plugins; jvm.sh is the reference one
gui/pitcrewgui/    GTK4 + libadwaita desktop app, consumes `json --watch`
                   model.py pure logic · ansi.py log colour · style.py the CSS
themes/            colour palettes
test/              a ~70-line assert harness and 22 test files
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

Two tiers:

```bash
diag_register my_check          # cheap: runs on every dashboard frame
diag_register my_check slow     # may fork: only on `pitcrew diagnose`
```

`diag_run` runs the cheap tier, `diag_run --full` runs everything, and the JSON
reports which it was as `health.deep`. The tier is what makes constraint 4
structural instead of a rule a plugin author has to have read — anything that
shells out MUST be `slow`.

Plugins are shell files in `~/.config/pitcrew/plugins/`, **sourced by
bin/pitcrew at its top level** (constraint 2 again — a plugin holding a
`declare -A` is an obvious thing to write). They are deliberately never loaded
from inside a checkout; `lib/20-plugins.sh` explains why at length, and that
refusal should not be softened.

Rules if you work here:

- **`diag_run` is called once per dashboard frame**, so cheap checks obey the
  frame loop's no-fork rule: array reads and arithmetic only. `human`,
  `dur_human`, `pct_color` and `bar` set a global instead of printing precisely
  so they can be used from here.
- **Never claim more than was measured.** Findings print the evidence
  (`quiet 41m · up 3h20m`) rather than rounding it into an assertion. A recovery
  candidate must be both quiet and old, `protected` components are excluded but
  still *listed*, and even then pitcrew proposes and the person decides.
- **Idleness is persisted, and the mechanism is the interesting part.**
  `$LOG_DIR/.idle` holds `comp=collector pid cpu_counter last_work_at
  last_seen_at`. On the next run the CPU counter is compared against the current
  one over the elapsed wall clock: if it has not moved past the idle threshold,
  the service *provably* did no work while nobody was watching, so the old
  timestamp is carried forward. Otherwise the clock restarts. A changed pid or
  collector discards the record. Do not "simplify" this into trusting the
  timestamp — that turns a measurement into a guess, and the guess puts busy
  services on a list of things it is safe to stop.
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
- **A mode is a layout, not a filter over one.** Zen does not draw the table
  with rows removed — it draws a list, because the table's two header rows,
  column pair and graph column cost more rows than the content does once the
  content is one crashed service. Filtering a layout built for twelve rows is
  how you get a wide, mostly-blank screen and call it focus.
- **A mode never hides the way out of itself.** Zen strips gauges, legends,
  meters, healthy rows — but keeps `q quit` and `z leave zen` in the terminal
  hint row and keeps the view switcher in the desktop app. The hint row is
  truncated from the END, so `q quit` is listed FIRST; adding one hint to the
  tail of the old order silently pushed it off a 160-column terminal.
- **A filter's summary describes the whole, not the slice.** A group heading
  reading `0/1 up` because a filter hid the healthy half is a wrong number
  stated confidently, and a "Stop all" under it that stops half the group is
  worse. Headings count the group and say how many rows are not shown.
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

The harness pins `LC_ALL` to a UTF-8 locale and `PITCREW_COLOR=truecolor`,
because a lot of assertions are about box-drawing characters and 24-bit escape
sequences — properties of the terminal, not of pitcrew. Do not remove that: CI
has neither, and without it the suite fails there while passing everywhere
else. Two portability rules the tests themselves must follow: **no GNU-only
tools** (`date -d`, and `wc -l` pads on BSD — use `grep -c`), and **no
multibyte ranges in a regex** (`C.UTF-8` rejects them; spell the set out).

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

- `human()` renders 0 bytes as `0M`, so a machine with no swap in use reads
  `SWP 0M / 7.9G`. Harmless, but it is not what anyone would write by hand.
- The desktop app's process view is still a flat expandable tree. The JVM
  plugin can see a heap/metaspace/native breakdown but has nowhere to render
  it — findings are the only channel a plugin has today.
- `diag_check_errors` fires on any log line matching `PITCREW_ERROR_PATTERN`,
  which for a chatty framework is noisy. There is no per-component pattern.
- `components[].processes` ships on every frame, capped at 12 per component.
  For a large stack that is real bandwidth spent on a view most frames nobody
  has open. If it ever matters, the fix is a request channel on the stream, not
  a `ps` in the GUI.
