# pitcrew-jvm

Where a JVM's memory went, and what is going to kill it.

A standalone tool. It needs bash and a JDK, and it does not know pitcrew
exists — it is useful on its own over ssh on a box that has never heard of it.
pitcrew consumes it through a forty-line adapter in `plugin/jvm.sh`.

## Why

Heap monitors are everywhere. The question they cannot answer is the one that
actually gets asked:

> Why is this service's RSS 2.6 GB when `-Xmx` is 1 GB, and what will the
> kernel do about it?

So this is a **memory accountant**. It reconciles what the OS sees against
everything the JVM will admit to, and puts both against the ceiling that will
actually kill the process.

```
$ pitcrew-jvm be-sales

be-sales  pid 24193 · up 3h20m

                    committed       used        max
  heap                   900M       780M       1.0G
  metaspace              184M       175M          -
  code cache             240M       238M          -   filled 3× — JIT stopped
  GC structures           74M          -          -
  thread stacks           96M          -          -   192 threads
  ────────────────────────────────────────────────
  accounted              1.4G   measured by NMT
  resident (RSS)         2.6G   resident pages; committed is normally higher
  unaccounted            1.1G   not accounted for by the JVM
  cap                    2.0G   from pitcrew

  ✗ be-sales has filled its JIT code cache
    the cache filled 3 times — the JIT has stopped compiling and new code paths
    now run interpreted, with nothing in the log
  ✗ be-sales can outgrow its memory cap before its heap fills
    -Xmx 1.0G plus 1.4G of measured non-heap needs 2.4G, the cap is 2.0G — the
    kernel kills it first, with no stack trace
```

## Install

```bash
ext/jvm/install.sh              # ~/.local/bin + ~/.config/pitcrew/plugins
ext/jvm/install.sh /usr/local/bin
```

Both halves are optional and independent. Nothing here is required to use
pitcrew, and pitcrew is not required to use this.

## Use

```
pitcrew-jvm                    every JVM this user is running, one line each
pitcrew-jvm <pid|name>         the full breakdown for one
pitcrew-jvm --check            findings only; exits 1 if any are critical
pitcrew-jvm --json             the same numbers as one JSON object
pitcrew-jvm --watch -i 60      one JSON object a minute
```

`--check` exits non-zero on a critical finding, so it drops into a cron job, a
CI step or a health probe without any parsing.

## What it checks

| id | what it catches |
|---|---|
| `jvm-cap` | `-Xmx` plus measured non-heap exceeds the cgroup or supervisor cap — the kernel kills it before the heap ever fills, so there is no stack trace |
| `jvm-codecache` | the JIT code cache filled; compilation has **stopped permanently** and new code paths run interpreted, with nothing in any log |
| `jvm-metaspace` | metaspace approaching a `MaxMetaspaceSize` someone set — usually a classloader leak |
| `jvm-heap` | heap at 90% of `-Xmx`, where it spends more time collecting than running |
| `jvm-container` | running under a cgroup limit with `UseContainerSupport` off, so the heap was sized from the whole machine |
| `jvm-unaccounted` | RSS well above everything the JVM admits to — a JNI library, a leaking direct buffer, malloc arenas |
| `jvm-threads` | thread stacks reserving a material share of the cap before a single object is allocated |
| `jvm-nmt` | native memory tracking is off *and* the JVM is close enough to its cap that the unmeasured part could decide the outcome |

## Two things it is careful about

**Committed is not resident.** NMT reports committed address space; `/proc`
reports resident pages. A healthy JVM routinely commits more than it has
touched — 110 MB committed against 41 MB resident is normal — so
`accounted - RSS` is often negative. That direction is never reported as a
finding. Only RSS *exceeding* the accounting means anything.

**A floor is not an estimate.** With NMT off, GC structures, thread stacks and
direct buffers cannot be read at all. What is added for them is a deliberate
under-estimate, so the "needs" figure is a **lower bound** — and when a lower
bound already exceeds the cap, the conclusion is certain. The wording says
which it is: *"needs 2.4G"* when measured, *"needs 2.4G or more"* when not.

Start a JVM with `-XX:NativeMemoryTracking=summary` and everything becomes a
measurement.

## The report

Alongside the findings, the tool emits the breakdown as a **table** that pitcrew
renders as a panel — so the arithmetic behind a finding is visible, rather than
being eight more `info` lines competing with the one that matters.

```
$ pitcrew-jvm --check --format report-tsv --targets -
finding  crit  jvm-cap  be-orders can outgrow its memory cap ...
report   jvm   be-orders  JVM memory
row      heap           1.1G / 2.0G   used 343M
row      code cache     69M / 240M
row      accounted      1.2G          a floor — GC structures cannot be read
row      resident       1.5G          what the OOM killer counts
row      cap            2.0G          from pitcrew
```

One invocation answers both questions. Asking twice would cost ten `jcmd` forks
per JVM instead of five, and this runs once per component. Plain `--format tsv`
is unchanged — six bare columns, findings only.

A row whose value could not be measured is **omitted**, not printed as a dash: a
table of dashes is not a report.

## Layout

```
bin/pitcrew-jvm    args and dispatch; bash 3.2-parseable so its version guard can print
lib/probe.sh       the only file that forks, and the only one that knows the OS
lib/parse.sh       pure: captured tool output on stdin, numbers on stdout
lib/rules.sh       pure: facts in, findings out
lib/render.sh      table, breakdown, JSON, TSV
lib/util.sh        formatting; sets globals rather than printing, so it never forks
plugin/jvm.sh      the pitcrew adapter
test/fixtures/     captured jcmd output: JDK 8, 17 and 26; G1, Parallel, Serial, ZGC, Shenandoah
```

`parse.sh` and `rules.sh` are pure so the whole thing is testable with no JVM
on the machine — the same split `lib/00-platform.sh` uses for `vm_stat`, and
for the same reason.

```bash
make test T=jvm
```

## Why the parsers are pinned to fixtures

The plugin this replaces read metaspace out of `jcmd GC.heap_info`. That line
was **removed from the command after JDK 11**. Nothing errored — metaspace
simply read as `0`, the OOM prediction that depends on it got quietly smaller,
and the check went on looking like it worked for two JDK releases.

So every shape is captured from a real JDK and pinned by a test, every parser
returns `-1` for "could not read" rather than `0`, and every rule refuses to
run on one. `MaxMetaspaceSize` gets the same treatment from the other end: its
"unlimited" value is `18446744073709551615`, which the shell does not reject
but silently **truncates**, so it is clamped in awk before a digit reaches
bash arithmetic.

## Limits

- **`jps` only sees this user's JVMs.** That is the right default for a
  developer tool. Another user's services will not appear.
- **`jcmd` needs the JDK**, not just a JRE. Without it the tool still reports
  RSS, threads and the cgroup cap, and says the rest is unknown.
- **A busy JVM may not answer.** `jcmd` attaches and waits for a safepoint;
  every call here is bounded (`--timeout`, default 5s) so one sick JVM cannot
  hang `pitcrew diagnose`. A JVM that does not answer produces no findings
  rather than wrong ones.
- **Windows is unverified.** The parsers are OS-independent and tested; the
  probe layer is not exercised on a real Windows box.
