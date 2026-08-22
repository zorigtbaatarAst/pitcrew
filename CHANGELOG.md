# Changelog

Notable changes per release. Newest first. Dates are the release date, not the
commit date.

The format is loosely [Keep a Changelog](https://keepachangelog.com/); versions
follow [semver](https://semver.org/) with the caveat that **the JSON contract has
its own version** (`schema` in `pitcrew status --json`) and is bumped only when a
field is removed or changes meaning.

## [Unreleased]

### Added
- **An app is a GROUP of components, and the group is open.** `be` and `fe` are
  two ordinary role names now, not the only two there can be — add a `worker:`,
  a `scheduler:`, a second `admin_web:`, whatever your team calls them. It used
  to be two fixed slots all the way down (`PITCREW_BE_CMD[app]`, `${c:0:2}` to
  read a role, `${c#??-}` to read an app, right through to the JSON writer), so
  a monorepo with a worker had nowhere to put it. Every role is a target of its
  own: `pitcrew restart worker` restarts every app's worker,
  `pitcrew restart worker-shop` restarts one. `env:` and `max:` are keyed by
  role, so a new one gets its own budget and environment the same way `be`
  does. The two-role shorthand a hand-written `pitcrew.config.sh` uses is now
  an INPUT that is folded into the component model at load; nothing reads it
  afterwards, and every existing config keeps working unchanged.
- **A backend and a frontend can live in two different checkouts.** `root:` is
  a component's own repository and `dir:` is relative to it — under the app for
  a whole group, under a component to override it. Absolute paths, `~/…` and
  `../…` all work, and `watch:` resolves against the same root as the command
  it belongs to. This was possible before only by repeating one absolute path
  in front of every command and every watch dir.
- **`enabled: false`** on a component, or on a whole app: excluded from
  `start all`, from `backends`/`frontends` and from its group, but still listed
  on the dashboard and in the JSON, marked `off` and keeping its port and cap.
  An excluded service that *vanished* is one you spend an afternoon looking
  for. Naming it outright still starts it — a switch you cannot override is a
  trap, the same call pitcrew already made for `protected:`.
- **One-line components.** The YAML parser accepts flow mappings of scalars now
  (`fe: { dir: admin, cmd: npm run dev, port: 3001 }`). A group with four roles
  reads far better as four lines than as twenty. Commas separate the pairs, so
  a comma inside a value has to be quoted — which is what YAML requires there
  anyway, and the split honours quotes rather than truncating a command.
- **The desktop app edits the config as a form.** One group per app, one
  expander per component — command, checkout, directory, port, health path, RAM
  cap, and the `enabled` switch on the row itself. **+** adds a role, **Add an
  app** adds a group, and a **YAML** tab sits next to it for anything the form
  does not cover. Two deliberate limits: it never regenerates the file (each
  field becomes the smallest possible edit to the text, so comments, key order
  and block-vs-flow style survive), and it never parses YAML (every value comes
  from the new `pitcrew config --json`, because `lib/18-yaml.sh` is the one
  definition of what pitcrew accepts and a second parser would eventually
  disagree with it). A bash config still gets the text editor and no form.
- **`pitcrew migrate`** — a `pitcrew.config.sh` rewritten as the YAML that means
  the same thing, which is possible because pitcrew has already RUN it: a file
  that builds six apps from a `for` loop over a `declare -A` of ports is six
  concrete apps in the model by then, and that is what gets written out. It
  also undoes what the shell format made you open-code — `cd $ROOT/x && …`
  becomes `dir: x`, absolute paths become relative or `$ROOT`/`$HOME`, and
  values are quoted only where leaving them bare would change them.

  The result is **checked before anything is written**: loaded in a subshell
  and compared field by field against the config in memory — every command,
  port, health path, cap, env prefix, protection flag and exclusion. A
  mismatch writes nothing and prints the diff. One difference is expected and
  reported instead of refused: a component with a `dir:` and no `watch:` of its
  own watches where it runs, which a `.sh` config had no way to say, so
  `migrate` names every component whose `stale` coverage grows. A
  `pitcrew_doctor_extra()` function is named as something to port by hand.

  The desktop app offers the same thing as **Convert to YAML** whenever it
  opens a `.sh` config — the one config it cannot show you as a form.
- **`pitcrew config --json`** — the config as the editable model: every app,
  its components, and what the FILE says for each (`cmd`, `dir`, `root`,
  `watch`) alongside what it resolved to (`runCmd`). Added so an editor never
  has to parse the YAML itself.
- `"enabled"` on every component in `pitcrew json`.
- **Windows in CI, twice.** One job runs the lint, the whole suite and the CLI
  smoke commands on `windows-latest` under Git Bash — the environment a user
  actually has. A second installs the desktop app end to end on a real MSYS2
  UCRT64: our own dependency installer, our own `setup.sh`, and then a check
  that both `pitcrew.lnk` files are on disk, which fails the job if they are
  not. Both are `continue-on-error` until they have been green once. Every
  Windows bug fixed in this release was invisible to reading and would have
  been caught by these in one run.
- **Zen mode** (`z` in the dashboard, `Ctrl+Z` or the menu in the desktop app,
  `PITCREW_ZEN=1` to start in it). Answers one question — is there anything I
  need to do? — by hiding everything that says no: healthy components, deps
  that are up, the gauges, the legend, the machine meters, the consumer
  ranking. Anything you marked with `space` stays visible even when healthy,
  so it doubles as a focus mode. With nothing wrong it says *nothing needs
  you*, with the count of what is fine under it, rather than going blank — and
  the way out of the mode is never among the things it hides.

  It is a different LAYOUT, not the same one with rows removed. The terminal
  draws a centred list — one line per component, dependencies that are down at
  the top because they are usually the cause, worst first, no table header, no
  column pair, no graphs. The desktop app narrows its content column, centres
  the Overview, and turns Components into one flat list with no group headings
  and no column header. Filtering the old layout instead just left a wide,
  mostly-blank table: three group headings over four rows, and two header rows
  above a single service.
- **Native Windows**, under Git Bash (2.35+) or MSYS2. The shell was never the
  problem — that is real bash 5 — the POSIX userland underneath it was. So the
  process table comes from `wmic` (or PowerShell where wmic has been removed),
  listening ports from `netstat -ano`, and pidfiles keep holding MSYS pids so
  `kill` and `kill_tree` work unchanged, translated to Windows pids only where
  a native tool is on the other end.

- **Windows installs and produces a desktop app.** Every piece of the Windows
  path existed and none of it could complete: the python search in `setup.sh`,
  `gui/install.sh` and `gui/install-deps.sh` looked only in Unix places, so all
  three concluded the GTK bindings were missing on a machine that had them —
  the installer reported MISSING right after a successful `pacman`, and the
  shortcut was skipped on the grounds that it "would not run". `gui/install.sh`
  is now a real Windows install:
  - one interpreter search, `gui/pyfind.sh`, shared by every script that needs
    one (it had been copied into four, all wrong the same way) and aware of
    MSYS2's `$MINGW_PREFIX` and its `/ucrt64`, `/mingw64`, `/clang64` prefixes
  - **a Start Menu entry and a Desktop icon**, with Windows resolving both
    folders itself through `WScript.Shell.SpecialFolders` — the old code built
    them out of `$APPDATA`, a path with backslashes in it that bash could never
    stat, so the Start Menu was never found, and it broke outright under
    OneDrive, which relocates the Desktop
  - a shim rather than `ln -s` for `pitcrew-gui`, which under MSYS is a *copy*
    that cannot find the `pitcrewgui/` package beside it
  - `mingw-w64-ucrt-x86_64-python-cairo` added to the MSYS2 package list; MSYS2
    does not pull pycairo in with PyGObject, so `import gi, cairo` failed on
    the half nobody installed
- **The Windows app can say what went wrong.** The shortcut runs `pythonw.exe`,
  whose `sys.stderr` is `None` — and CPython's `print()` returns *silently*
  when there is nowhere to write. "No bindings", "no bash 5", "pitcrew not
  found" were all a double-click that did nothing at all. They go through
  `report_fatal` now, which falls back to a message box.
- **The GUI could not find the CLI on Windows.** MSYS2's bash has
  `$HOME=C:\msys64\home\you` and writes the shim under it; the native python a
  shortcut runs reports `Path.home()` as `C:\Users\you` and found nothing, so
  every button in the app was dead. It now looks in the checkout it was
  installed from first — `bin/` and `gui/` are siblings, which is a fact rather
  than a guess.
- **`bash` on Windows could be the WSL launcher.** `C:\Windows\System32\bash.exe`
  is on the PATH of every machine with WSL enabled and is what
  `shutil.which("bash")` finds first from a shortcut — so the GUI would have
  run pitcrew inside a Linux VM, against a filesystem with none of the user's
  project in it.
- Windows console flashes: every helper the GUI shells out to is a console
  program, and started from `pythonw` each one got a fresh black window.
  `CREATE_NO_WINDOW` on the calls the GUI makes directly. (`Gio.Subprocess`
  takes no creation flags, so the long-lived `json --watch` child is not
  covered by this — untested either way, and honestly unknown.)
- MSYS2's *msys* python reports `MSYS_NT-10.0-…` from `platform.system()`, not
  `Windows`, and under it every Windows special case in the GUI silently
  switched off.
- **A directory holding both `pitcrew.yaml` and `pitcrew.config.sh` broke every
  command.** The "reading one, ignoring the other" warning went to STDOUT — and
  that function's stdout *is* the config path, captured by the caller in a
  `$( )`. So the warning became part of the filename and pitcrew died on a path
  with a `⚠` in it. Which is exactly the state `pitcrew migrate` leaves a
  project in until the old file is deleted.
- **`~` did not expand in a config path.** `$HOME` did and `~` did not, so
  `dir: ~/work/api` resolved to `$ROOT/~/work/api` — a directory that cannot
  exist. `pitcrew check` called it clean and it failed at start time with a
  path nobody could parse.
- **A value aligned with extra spaces was read as text.** `deps:   [a, b]` kept
  the padding on the front of the value, so it did not look like a flow
  sequence and quietly did nothing. Aligning your values is not a syntax error
  in any other YAML.
- A health path was refused on anything but `be`, on the grounds that an open
  port is what makes a frontend up. True of a frontend, false of everything
  else a group can now contain — a worker with an actuator asks exactly the
  same question. Health is per component now.
- **The machine gauges were dead on any current Windows.** `wmic` is deprecated
  and gone from Windows 11; the process table already had a PowerShell
  fallback and the MEMORY numbers did not, so the gauge read *"RAM unavailable
  on this OS"*, Resources had nothing to draw, and `ram_preflight` could not
  tell you the stack would not fit. Both totals and free memory now come from
  either source. Free memory is sampled on its own slow interval and held in
  between — where wmic is gone it costs a whole PowerShell start, more than the
  process table the frame already pays for — and the total is resolved on first
  use rather than at startup, so `pitcrew stop` does not pay a third of a
  second for a number it never reads.
- **`pitcrew init` ignored the wrapper a Windows repo ships.** `[ -x gradlew ]`
  is false on Windows: NTFS has no execute permission and MSYS synthesises one
  from the file extension, so a shebang script bash runs perfectly reads as not
  executable. Every Windows repo got `cd $ROOT/x && gradle bootRun`, pointing
  at a system gradle the machine may not have, instead of `./gradlew
  :x:bootRun`. There is a `pf_runnable` in the platform layer now, and the
  detector asks it.
- `setup.sh` and `gui/*.sh` are now parse-checked and shellchecked. They were
  not, which is where the Windows install quietly rotted: three installer
  scripts nobody linted, on a platform nobody ran.
- `pitcrew doctor` on Windows now reports that **`stop` cannot reach a whole
  process tree without `pgrep`** — Git Bash ships none and MSYS2 only has one
  with `procps-ng`, so a stop looked successful right up until the port was
  still taken. Reported rather than silently worked around: the fix needs
  `taskkill` and a pid-space translation that nobody has been able to run yet.

### Fixed
- **The menus were unopenable on a stock macOS.** Every picker shelled out to
  `fzf` directly, and nothing ships fzf on a Mac: `pitcrew menu` died on the
  spot, and the dashboard's `m` — which its own key row advertises — hit a bare
  `command -v fzf || return` and did nothing at all, silently. The same went for
  the theme, render, RAM-cap, profile, shell and project pickers. All of them
  now go through one `pick()` (`lib/01-core.sh`) that is fzf where fzf is
  installed and a numbered prompt where it is not — type a number, or type text
  to narrow the list the way you would in fzf. `doctor` has claimed since the
  beginning that menus "fall back to plain prompts"; that is now true, and it
  names the command that installs the fuzzy one. `PITCREW_PICKER=plain` forces
  the fallback on a machine that has fzf, and CI runs the whole suite that way,
  the same bargain `PITCREW_FORCE_COLLECTOR=ps` strikes for the macOS meters.
- A component group's heading counted the rows a filter left behind rather than
  the group: `orders 0/1 up` over a group of two, and a "Stop all" that stopped
  one of them. Headings now describe the group and say `1 not shown`, and the
  heading's start/restart/stop act on every member.
- The desktop app's error banner rendered pitcrew's coloured stderr as raw
  escape bytes across the top of the window — the one message whose whole job
  is to explain a failure.
- The dashboard's key-hint row is truncated from the end, and `q quit` was last
  — adding one more hint pushed the way out off a 160-column terminal. It is
  first now, as it already was in the log viewer.

  There is no third collector: `PITCREW_PS` is an array whose first word bash
  resolves normally, so on Windows it points at a shell *function* that emits
  the exact `pid ppid rss time etime comm` columns the portable collector
  already parses. Everything downstream — tree walking, CPU deltas, idle
  tracking — is untouched.

  Two honest degradations, both reported by `doctor`: **RAM caps are not
  enforceable** (Windows has Job Objects, nothing on the command line puts a
  process in one), and a frame costs one process-table call plus one `netstat`
  — ~80ms via wmic, a few hundred via PowerShell — against zero forks on Linux.
  WSL2 remains the better experience and is unchanged.

  **Written and unit-tested, but not yet run on Windows** — there was no
  Windows machine to run it on. `test/windows_test.sh` covers every place a
  native tool's output is interpreted, against captured output, which is where
  this class of port actually breaks: a swapped column, a unit off by 1024, an
  unstripped `\r`. The integration is what remains unverified.
- **The desktop app launches from the Windows Start Menu**, with an icon and
  no console window behind it (`pythonw.exe`, not `python.exe` — that is the
  whole difference between an app and someone's script). `gui/install.sh` grew
  a Windows branch that builds the `.lnk` through PowerShell, and a `.ico` is
  shipped so the shortcut and taskbar look right without ImageMagick on the
  target. Needs MSYS2's `mingw-w64-*-{python-gobject,gtk4,libadwaita}`.
- **The GUI could not have run the CLI on Windows at all.** `pitcrew` is a bash
  script with a shebang; Linux and macOS honour that so the path alone is
  executable, but `CreateProcess` on a file starting with `#!` fails with "not
  a valid application" — which from a GUI with no console attached is a button
  that does nothing and says nothing. Every invocation now goes through
  `platform.cli_argv`, which names the interpreter only where it has to, and a
  test fails if anything builds an argv by hand again.
- `install.sh` writes a shim rather than a symlink on Windows: a symlink there
  needs Developer Mode, and a *copy* of the launcher cannot find its own `lib/`.
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

### Added
- **`pitcrew projects --json`** — the registry as data: what is running in each
  checkout, the ports it claims, whether the directory still exists, and any
  port another project also claims.

### Changed
- **The Projects view was worse than `pitcrew projects`.** It was the last view
  still inside an `AdwPreferencesPage`, so it clamped to 600px and left most of
  the window empty — and it showed a name and a path while the CLI already
  printed running counts and clashes. It now fills the window and each row
  carries a state dot, a running count, the ports, and a warning naming the
  other project when two claim the same one. For a tool whose pitch is "several
  projects on one machine", that view should be the one that sells it.
- **The Overview no longer pushes its own content below the fold.** Machine and
  Largest-consumers are one thought — what is this costing — so they share the
  left column and findings take the right at full height. Before, the left
  column ran out a third of the way down while consumers pushed itself off the
  bottom of a 740px window.
- **You can tell what is clickable now.** A finding's runnable fix is a framed
  pill; a suggested command you copy is monospace text. They were both flat
  text in the same row, so the only way to learn which was which was to click.
- **Dependencies moved to the top of the Components view.** A dead postgres is
  the likeliest reason six services are failing, and it was the last thing on
  the page, under every app.
- **A column header** over the component rows, built from the row widths
  themselves rather than guessed alongside them — the figures have been aligned
  since the last change, and without a header you infer that `:19871` is a port
  and `8s` is uptime from every row, every time.
- **`n/a` and `down` no longer render identically** in the terminal. Both drew a
  faint baseline. For `down` that is right — a component that exists and is not
  running has an empty chart. For `n/a` there is no component at all, and a
  chart there is a claim about something that does not exist. The asymmetric
  role model is the whole point; the two must not look the same.
- The log view's **Clear** control is a labelled button. It sat in a row of four
  unlabelled toggles and its glyph reads as "copy" — the one control there that
  throws something away was the one you could not identify.
- **`pitcrew json` got 12× faster and stopped forking.** Every field was
  escaped through `$(_json_str …)`, and a command substitution is a subshell —
  so one state object cost one fork per field per component. Twelve components
  came to **295 forks and 176ms**, five times the price of the entire terminal
  frame, and `json --watch` pays it on every interval forever. Measured against
  a desktop app that renders a frame in 0.4ms and parses one in 0.02ms: the
  producer was burning about 9% of a core on string escaping so the consumer
  could do nothing with the time.

  The encoders now set a global instead of printing — the same convention
  `lib/04-meters.sh` has always used for the render path (`human` → `HUMAN`,
  `bar` → `R`), and for the same reason. `comp_max_source` too.

  | components | before | after |
  |---|---|---|
  | 4 | 74 ms | 7 ms |
  | 12 | 176 ms | 14 ms |
  | 24 | 336 ms | 21 ms |

  Forks: **295 → 0**. The output is byte-for-byte what it was, which is how the
  change was verified — captured objects from before and after, including a
  project whose name contains quotes and backslashes, compare identical.
  `test/perf_test.sh` now holds `cmd_json` to the frame loop's contract, and a
  second test pins the convention itself, so a future `$( )` around an encoder
  fails rather than quietly costing 20 forks an object.
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

### Changed
- **The desktop app's layout was rebuilt around the window it is given.**
  Overview and Components sat inside `AdwPreferencesPage`, which clamps content
  to about 600px and cannot be widened — so on a 1000px window nearly half the
  screen was empty and on a monitor most of it was, while the figures on every
  component row were squeezed into a run-on subtitle. Both now use their own
  clamp at 1240px, Overview is two columns above 880px (machine and findings
  are read together) and folds to one below it, and component rows are aligned
  columns instead of a sentence: `27.4 MiB / 8.0 GiB · cpu — · :19801 · up 8s`
  became a table you scan rather than a line you read.
- **The verdict is a tinted banner, not another card.** It is the page's answer
  and the four groups under it are the evidence; rendering all five as
  identical rounded rectangles gave everything the same weight. Findings carry
  a severity rail down their left edge for the same reason.
- **One colour ramp for meters and severity.** The meters were stock
  `GtkLevelBar` orange whatever they measured, so a meter at 32% and a warning
  badge were nearly the same hue meaning entirely different things. Now colour
  always answers one question: how worried should I be. `STATE_STYLE` and
  `VERDICT_STYLE` draw from the same ramp, so a component and the stack it
  belongs to cannot disagree about what red is.
- **The charts say something.** Lines are filled underneath (a 2px line at 4%
  CPU on a dark ground is a scratch you have to hunt for), a percentage axis
  stops at 100% instead of `nice_max` rounding it up to 120%, both plots label
  the span they cover, CPU gets less height than memory because it is near zero
  most of the time, and a plot with fewer than two samples says "collecting…"
  rather than showing an empty grid with axis labels.
- **`Largest consumers` shows a bar instead of writing "25% of what this
  project is holding" on every row**, which was four copies of a sentence that
  told you nothing. `THIS` in the machine meters is now `Stack`.
- The per-row sparkline is gone. At 76×22px between six other columns it was
  illegible; the space went to a bar showing how close the component is to the
  RAM cap that will kill it, which is the more actionable of the two. Trend
  still lives on Resources, where it has room.

### Fixed
- **The desktop app could not start on Ubuntu 24.04 LTS.** It used
  `AdwToggleGroup` in two places; that widget arrived in libadwaita 1.7 and the
  current LTS ships 1.5, where constructing it *aborts the process* rather than
  raising — from a Start Menu shortcut or an app grid, an app that vanishes on
  launch and says nothing. Replaced with a linked row of `GtkToggleButton`s
  that works everywhere, and `platform.ADW_MINIMUM` now states the floor (1.5)
  and is checked before any window is built, so the next time someone reaches
  for a newer widget the failure is a sentence instead of a silence.
- **The Windows process-table parser used `mktime()`, a gawk extension.** BSD
  awk does not return zero for an unknown function, it refuses to run the
  program — so on macOS the entire parser produced nothing and every field came
  out empty. Replaced with plain arithmetic (days-from-civil), which also let
  the WMI timestamp's UTC offset be *applied* rather than assumed to cancel. A
  test now runs the parser under `awk --traditional` and fails if the output
  differs, so this cannot creep back.
- **CI had never passed.** Every run in the visible history was red, going back
  months, and all of it came down to the tests assuming the environment they
  happened to be written in:
  - **No `COLORTERM` in CI**, so every palette assertion compared 24-bit escape
    sequences against 16-colour ones.
  - **No `LANG` either**, so bash counted `█` as three characters and every
    width assertion was off by a factor of three.
  - `C.UTF-8` **refuses a multibyte range in a regex** outright ("Invalid
    collation character"), so `CPU [▁-█]` failed against a gauge that had drawn
    perfectly. Written out as an explicit set now.
  - **`wc -l` pads its output on BSD** and not on GNU, so three tests compared
    `"       4"` with `"4"` and failed only on macOS.
  - **The fork budget never counted macOS's memory gauge.** macOS has no
    /proc/meminfo, so a frame there pays a `vm_stat` on top of the `ps` and the
    port listing — three forks, against a budget that said two. It had been
    failing there since it was written.
  - **Sixteen GUI tests need a display** and did not say so: a widget with an
    icon name reaches for the icon theme, which is per-display, and GTK aborts
    the process rather than raising. They skip cleanly now, and the Linux job
    runs under Xvfb so they are actually exercised somewhere.

  The harness now pins a UTF-8 locale and a colour depth, probing for a locale
  bash can both *count* and *collate* in. A test whose result depends on the
  terminal running it is not a test.
- **The status dot in the component list was showing the wrong thing.** It was
  the colour of that component's line on the Resources graph — meaningless on
  a tab with no graph — and it never changed when a service crashed. A green
  dot beside a dead backend is worse than no dot. `be-analytics` appearing red
  was a coincidence: it was the fifth component, and the fifth series colour is
  red.
- **The desktop app printed ANSI escapes instead of obeying them.** A dev
  server's log is not plain text — Spring Boot, Vite, gradle and npm all write
  SGR colour into it, and pitcrew captures stdout verbatim (as it should; the
  file is meant to be readable with `less -R` too). The view rendered those
  bytes literally, so a Spring log came out as a wall of
  `▯▯[2m2026-08-20 11:04:19.670▯▯[0;39m ▯▯[32mINFO▯▯[0;39m` with the actual
  message pushed off the right-hand edge. The colours are now interpreted:
  timestamps dim, `INFO` green, `WARN` yellow, loggers in their own colour,
  with a light and a dark palette because colours chosen for a dark terminal
  are unreadable on a white background. 24-bit and 256-colour sequences are
  kept as written; every other escape (erase-line, cursor moves, window
  titles) is dropped rather than printed, and `\r` progress lines collapse to
  what a terminal would have left on screen instead of two hundred copies of
  themselves. pitcrew's own error pattern still colours a line the log did not
  colour itself — and leaves alone one it did, which is how its WARN stays
  distinguishable from its ERROR.
- **Long lines had nowhere to go.** A Spring line is ~200 characters before the
  message starts. A wrap toggle sits next to the filter; off by default,
  because a log is read as columns.
- **The desktop app's log view froze, for three separate reasons.** All three
  looked identical — a tail that stopped moving — and none was visible in a
  screenshot:
  - **A blank line ended the tail.** `Gio.DataInputStream.read_line_finish`
    reports end-of-stream as `(b"", 0)` and reports a BLANK LINE as `(b"", 0)`
    too; there is no third value to tell them apart. Treating the pair as EOF
    stopped the reader at the first empty line — which a starting Spring Boot
    or `npm` process emits within its first few — and it never recovered.
    Reading raw bytes and splitting lines here removes the ambiguity: on a
    pipe, zero bytes means the writer is gone. The same conflation was latent
    in the state stream, where one blank line on stdout would have ended the
    whole GUI's updates.
  - **A log that appeared later was never picked up.** Opening Logs and *then*
    starting the stack left the view showing "no log yet" for the rest of the
    session, because nothing re-checked after the selection was made.
  - **A restart lost the tail.** Restarting rotates the log; plain `tail -f`
    went on following the renamed file, so the view showed the previous run.
    Now `tail -F`, which re-opens by name (both GNU and BSD have it).
- **A burst of output made the window sluggish.** One scroll callback was
  queued per line, so `npm install` put thousands of them in front of the
  compositor. Coalesced to one per burst.
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
