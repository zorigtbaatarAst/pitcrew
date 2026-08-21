# Changelog

Notable changes per release. Newest first. Dates are the release date, not the
commit date.

The format is loosely [Keep a Changelog](https://keepachangelog.com/); versions
follow [semver](https://semver.org/) with the caveat that **the JSON contract has
its own version** (`schema` in `pitcrew status --json`) and is bumped only when a
field is removed or changes meaning.

## [Unreleased]

### Added
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
