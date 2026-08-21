# Changelog

Notable changes per release. Newest first. Dates are the release date, not the
commit date.

The format is loosely [Keep a Changelog](https://keepachangelog.com/); versions
follow [semver](https://semver.org/) with the caveat that **the JSON contract has
its own version** (`schema` in `pitcrew status --json`) and is bumped only when a
field is removed or changes meaning.

## [Unreleased]

### Added
- **The desktop app can now reach everything the CLI can**, apart from what a
  window genuinely cannot host. New: a live **process tree** in a component's
  detail dialog (a `gradle bootRun` is a wrapper that forks a daemon that forks
  the app, so the PID shown above it is almost never the one holding the
  memory), **start/restart for dependencies** from the row that shows they are
  down, a rendered **Doctor**, **profile save and delete** (the set you want is
  the set already running — naming it is the only step), and one **Tools**
  dialog for ports across every project, loaded plugins, and the configured
  shells. `pitcrew theme`/`render`, the fzf menu, and actually running a shell
  stay terminal-only, and the app says so rather than pretending.
- **Findings became buttons.** Where pitcrew is willing to run a suggested
  command it offers it as an action — including **Restart stale**. The `fix`
  string is never handed to a shell: it is split, checked against a small list
  of verbs over component names, and run as argv or shown as selectable text.
  A plugin can put anything in that field, which is exactly why.
- **Staleness is a diagnostic check** (slow tier), so "what is running is not
  what is on disk" reaches `diagnose`, the JSON and the desktop app instead of
  only `pitcrew stale`.
- **`components[].processes`** and **`shells`** in the state object — what the
  GUI needed in order to show a process tree without running its own `ps`.
  Capped at `PITCREW_JSON_PROCS` (12) and sorted by memory.
- **Plugins.** A plugin is a shell file in `~/.config/pitcrew/plugins/` that
  calls `diag_register`. No manifest, no lifecycle, no API version. `pitcrew
  plugins` lists what loaded and attributes every check to the file that
  registered it, and `doctor` says how many are active. Deliberately **not**
  loaded from inside a checkout: a repo whose plugins were sourced
  automatically would mean `pitcrew status` on a fresh clone runs its code,
  which is exactly what a data-only YAML config exists to avoid.
- **A slow tier for checks.** `diag_register <fn> slow` marks a check that may
  fork; those are skipped by the dashboard's per-frame run and only executed by
  `pitcrew diagnose`. This makes "no forks in the frame loop" structural rather
  than a rule every plugin author has to have read. The JSON says which tier a
  state object came from (`health.deep`), and the desktop app grew a **Full
  diagnostics** button that asks for the rest.
- **A bundled example plugin** (`examples/plugins/jvm.sh`) that catches
  something neither half of the system can see alone: pitcrew knows the RAM cap
  it launched a JVM under, the JVM knows its `-Xmx`, and when `-Xmx` plus native
  exceeds the cap the kernel kills the process long before the heap fills — the
  "my service just disappears under load with nothing in the log" failure. Its
  parsers are pure functions over captured `jcmd` output, so they are tested on
  a machine with no JVM.
- **`protected: true`** per role (`--be-protected` / `--fe-protected` in the
  bash format). `diagnose` will never propose stopping a protected component,
  however idle it looks — but still lists it, under a 🔒, because a candidate
  list that silently omits your biggest idle service reads as a bug rather than
  as a decision you made. Not a lock: `pitcrew stop` still stops it.
- **`pitcrew diagnose --watch`** — NDJSON, one health object per interval
  (default 30s), running the slow checks. What a desktop notifier should sit on.
- **`pitcrew diagnose`** — the tool now answers rather than only reporting.
  Crashed components with their exit code and age, services stuck in `starting`
  past the boot timeout, ports served by something else, **memory pressure that
  names who is holding the memory**, caps that add up to more than the machine,
  components approaching the cap that will kill them, dead dependencies, and
  services that are up and quietly logging exceptions. `--json` for the same as
  data; exit 1 on a critical finding, so CI can gate on it.
- **A verdict, everywhere.** The first line of the live dashboard is now
  `● all 6 components healthy` or `● be-worker crashed`, `d` opens the full
  diagnostics panel without leaving it, `pitcrew status` ends with the same
  line, and the desktop app leads with it. One implementation
  (`lib/19-diag.sh`), four surfaces — they cannot disagree.
- **Recovery candidates.** Quiet, long-running services are listed with what
  stopping them returns and the evidence for calling them idle (`quiet 41m ·
  up 3h20m`). The flow is diagnose → candidates → review → apply, and pitcrew
  never picks its own victims: the last thing you get is a command, or a button
  under a list of every component it will stop.
- **Swap is measured** (`/proc/meminfo` on Linux, `vm.swapusage` on macOS), on
  its own slow interval so the frame loop keeps its fork budget. RAM at 60%
  with a gigabyte swapped is a worse place to be than RAM at 90% with none, and
  nothing else in the tool could see the difference.
- **A check registry** — `diag_register <fn>` — which is pitcrew's first
  extension point. The built-in checks use exactly the call a plugin would, and
  a check added anywhere shows up in the dashboard, `diagnose`, the JSON and the
  desktop app without touching any of them.
- **An Overview view in the desktop app**, opening on the verdict: machine
  meters including swap, the findings worst-first with a one-click jump to the
  relevant log, the recovery candidates behind a confirm dialog that names every
  one of them, and a ranked "largest consumers" list. The header status light is
  now driven by the verdict rather than the worst component state — every
  component can be up while the machine is swapping, and a green dot over that
  is a lie.
- **A loading state.** The desktop app said nothing at all between launch and
  the first sample, which at a 10-second interval is ten seconds of a window
  that looks broken.

### Changed
- **Idleness now survives the process that measured it.** It used to be
  observable only for as long as one pitcrew process happened to be watching, so
  a one-shot `diagnose` could report a couple of seconds and a reopened
  dashboard forgot everything. Writing down "last did work at T" and trusting it
  later would be a guess — nobody was watching in the gap. So pitcrew persists
  the process's *monotonic cumulative CPU counter* alongside the timestamp and
  compares on the next run: if the counter has not moved beyond the idle
  threshold over the elapsed wall clock, the service **provably** did no work in
  the gap. The record is discarded outright if the pid or the collector changed.
  `diagnose` samples for one second and inherits the rest.

### Fixed
- **Every YAML registry pointer pitcrew wrote was unloadable.** `pitcrew init`
  on a repo shipping its own `pitcrew.yaml` emitted `root:` before `include:`,
  and the loader requires `include` to be the first key — so the entry it had
  just written failed on the next command. The existing test checked the file's
  *content* and never loaded it; it now loads it, which is the only way this
  class of bug shows up.
- **The process tree was invisible below 110 columns.** It was drawn only in
  the wide layout, so under `PITCREW_NARROW_AT` pressing Enter toggled a tree
  that was never painted — a key that silently did nothing on the terminal
  width most people use.
- **`pitcrew edit` opened the wrong file.** For a repo that ships its own
  config, the registry entry is a two-line pointer at it — so `edit` let you
  change a file the tool does not read. It now follows the indirection (through
  `source` for the bash format, `include:` for YAML), which is what the desktop
  app has always done.
- **"Env overrides" was documented backwards.** `PITCREW_ROOT`, `PITCREW_BE_MAX`,
  `PITCREW_FE_MAX` and `PITCREW_WAIT` are *defaults* that a config file's own
  value beats, not overrides that beat it. `README` and `pitcrew help` now say
  what the code does.
- Six `lib/` modules named the wrong file in their own header comment.
- **YAML configs.** A project can now be described by a `pitcrew.yaml` instead
  of a `pitcrew.config.sh`: `apps: → <name>: → be:/fe: → cmd/port/health`, with
  `dir:` folding the repeated `cd $ROOT/... &&` out of every start command, and
  `dir:`/`watch:` resolved against the project root. `deps`, `env`, `max`,
  `wait`, `shells`, `doctor` and `dashboard` cover the rest of the old
  `PITCREW_*` surface, and `include:` does what `source` did for registry
  entries. `pitcrew init` writes YAML by default; `--sh` still writes bash.
  The bash format is not deprecated and loads unchanged — YAML is a front end
  onto the same model, not a second one. Where a directory holds both, the
  YAML is read and pitcrew says so instead of choosing silently.
- **An unknown config key is now a message, not silence.** Every YAML key is
  checked against the schema and reported with its exact path
  (`unknown key 'apps.api.be.prot'`) — the failure mode a bash config could
  never catch. The parser refuses tabs, anchors, flow mappings, tags and
  sequences of mappings with a file and line number rather than half-parsing
  them.
- **`pitcrew check [<file>]`** — load a config and report what is wrong with
  it, without starting anything. `bash -n` for a `.sh`, a full parse-and-
  validate for a `.yaml`. The desktop app's config editor uses it as its
  save-guard, so it can never accept a file the CLI would reject.
- **Per-component RAM caps.** `pitcrew limit [<component> <size|default>]`, plus
  `pitcrew_app <app> --be-max/--fe-max` in a config. Resolution is
  machine-local override → per-app cap → role default.
- **`render ram cap`** — the dashboard RAM cell names the cap it is measured
  against (`1.0G/8G`) instead of only colouring by it.
- **🧠 RAM caps…** in the interactive menu.
- **`pitcrew json --watch`** — an NDJSON stream, one state object per line. The
  only mode that can report real cpu%, which is a delta between two samples.
- **Staggered start.** `PITCREW_START_CONCURRENCY` (default 3) caps how many
  components boot at once; `PITCREW_START_SLOT_SECS` stops a stuck one holding
  the queue. `=0` restores the old all-at-once behaviour.
- **A desktop app** (`gui/`, GTK4 + libadwaita): components grouped by app,
  live CPU/memory graphs, a log tailer, project management, and preferences.
  Linux `.desktop` and macOS `.app`.
- **`setup.sh`** — fresh clone to working tool on any OS.
- **`gui/install-deps.sh`** — detects the package manager and installs what the
  GUI needs. Prints the command and stops unless given `--yes`.
- `schema`, `logDir`, `errorPattern`, `machine`, `limit` and `limitSource` in
  `status --json`.
- `pitcrew --version`, and the version in `doctor`.

- Desktop **crash notifications**, clickable **URLs** and **health** hints,
  an **errors → logs** jump, log **filtering**, **group and stack-wide**
  start/stop/restart, **profiles**, **keyboard shortcuts**, and remembered
  window geometry in the desktop app.
- A **share-of-memory ring** and **click-to-mute legend entries** on the
  Resources view.
- A **hover readout** on the Resources graphs and **self-folding groups** in
  the Components view.
- Per-row **sparklines**, **uptime**, **restart counts**, a **starting**
  spinner, a **filter box** and a **click-for-detail** dialog in the desktop
  app's Components view.
- `url`, `health`, `profileDir`, `since` and `restarts` in `status --json`.
  Uptime costs no extra fork on either platform: `/proc/<pid>/stat` field 22
  against `btime` on Linux, one more field on the `ps` the fallback collector
  already runs elsewhere.

### Fixed
- `bundle exec …` apps drew the **node** icon: `*bun*` matched "bundle" and sat
  above the ruby line. `*pnpm*` was dead for the mirror-image reason.
- `rail_color` read the **caller's** `$app` — two assignments on one `local`.
- Two GUI icons were **invisible**: `utilities-system-monitor-symbolic` (the
  Resources tab) and `external-link-symbolic` are not in the icon theme, and a
  missing icon name draws nothing rather than erroring. A test now checks every
  name the GUI asks for.
- A `NameError` in the "add project" folder picker — `plain` was used but never
  imported. Found by ruff's first run; no test could reach that callback.
- `status --json` reported `cpu: 0` for everything. A one-shot process has no
  previous sample to delta against; it now reports `null`.

### Changed
- `make lint` gates at shellcheck **warning** and runs **ruff** over the GUI. It
  previously ran at `style`, where 58 findings (43 cosmetic) meant it always
  failed — and had been hiding the two bugs above.
- `status --json` pins its **entire** key set in `test/output_test.sh`.
