# Changelog

Notable changes per release. Newest first. Dates are the release date, not the
commit date.

The format is loosely [Keep a Changelog](https://keepachangelog.com/); versions
follow [semver](https://semver.org/) with the caveat that **the JSON contract has
its own version** (`schema` in `pitcrew status --json`) and is bumped only when a
field is removed or changes meaning.

## [Unreleased]

### Added
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
- `url`, `health` and `profileDir` in `status --json`.

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
