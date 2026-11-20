# Quickdraw Roadmap

Goal: the best test runner for Ruby in every dimension — speed, CLI, reports, reliability tooling, for tests written in its own syntax.

Everything in this repo is a prototype and open to redesign.

## Principles

- **Zero leakage.** Quickdraw never loads a gem or stdlib into the process under test. Code that forgot `require "json"` must fail under Quickdraw like it does in production.
- **Every test is an event.** Workers stream one event per test (id, result, timing, worker, sequence). Reporters, history, flake detection and bisection are all consumers of that stream.
- **Remember everything.** Each run is recorded locally, so the next run is faster and smarter: scheduling, flake scores, regressions, bisection.
- **Never lose a result.** Crashes, hangs and `exit!` are reported against the test that caused them.
- **Output is a product.** Equal care for humans, CI and AI agents.

## Architecture

```
quickdraw  (coordinator — never loads user code)
  CLI · scheduler · run history · reporters · diffing · watch
   ├─ loader[group]  core-only runtime + helpers + tests ── fork → workers
   └─ loader[group]  different requires / Gemfile       ── fork → workers
```

- The coordinator owns all of Quickdraw's dependencies.
- Loaders and workers run a core-only runtime: `IO.pipe` (and named pipes in watch mode) + `Marshal`, no `socket`, `json` or `io/console`. Workers ship strings; formatting and diffing happen in the coordinator.
- Ruby::Box is an optional extra layer (e.g. for assertions that need prism in a worker), switched on by the coordinator setting `RUBY_BOX=1` for loaders.
- Groups isolate tests that need different requires or a different Gemfile. Each group has its own loader; the coordinator keeps at most N workers busy across all groups.
  - **Done, for requires:** `config.group :browser, "test/browser/**/*.test.rb" { require "playwright" }`. The first loader boots config and reports which groups it defines. The coordinator then forks a loader for each group with selected files, which boots config, runs the group's block after the before_forking callbacks, and forks its own workers. Workers start in proportion to each group's files. A worker whose group runs out of work stops and another starts in its slot in the group with the most work left per worker, so slots (and per-worker databases) stay within N. A group whose setup raises reports its files as not loaded, with the error, and its slots go to the other groups. `bisect` replays a group's tests in a loader for that group.
  - **Done, for Gemfiles:** `config.group :rails7, "test/rails7/**/*.test.rb", gemfile: "gemfiles/rails7.gemfile"`. Since Bundler can't be unloaded, the group's loader is a new Ruby process with `BUNDLE_GEMFILE` set, given its pipes as inherited file descriptors and its settings over another pipe (`Loader.start`, `bundled_loader.rb`). Run and `bisect` both use it.
  - **Still to do:** running the same files in several groups, one per Gemfile, as Appraisal does, which needs a test's identity to include its group. Also, when config fails to boot, every file reports the same error; one problem would be clearer for a large suite.
- The loader boots shared helpers once, then forks. Workers load test files lazily with `load(path, Module.new)` and report each file's test list to the coordinator. Loading runs in parallel, the first test starts straight away, and each file's top-level constants stay scoped to that file.
- The unit of work is a batch of tests from one file. Batches start at one test and double while the file's tests fit a 20ms budget, so a slow file never hands all its tests to one worker. Workers prefer files they've already loaded.
- Once every file is loaded, an idle worker steals from the file with the most estimated time left, loading it first if the remaining time is worth more than twice the load time.
- The coordinator knows each batch's order, so a worker crash names the in-flight test and requeues the rest of the batch.
- Timing history will seed the batch sizes and file order (slowest first).
- Every test has a stable id (`path:line` + name) used for filtering, history, retries and bisection.
- Worker control channel: assign batch, cancel, dump thread backtraces, replay an exact sequence.

## Run history

Stored in SQLite at `.quickdraw/history.sqlite3` (built; `lib/quickdraw/history.rb` documents the schema). It powers scheduling and `--failed` today. Later it will power flaky detection, bisection, branch comparison and the per-test coverage index for impact analysis.

- **Built:**
  - files run slowest first, using each test's rolling average duration;
  - each file's first batch is sized from history;
  - every result is recorded with its phase timings, worker and position in that worker's order;
  - `--failed` runs every test whose most recent result wasn't a pass, plus files that last failed to load;
  - `--no-history` turns it off.
- **Why SQLite:** measured on 50 runs of a 20,000-test suite. Appending a run is cheap, and indexed queries take 1–31ms. A Marshal history file takes 0.5–0.8s to read or rewrite, and grows with every run.
- **Write cost** for 20,000 tests: 220ms → about 140ms, written after the report is printed. Most of the gain came from three changes:
  - **Batched inserts:** 500 rows per statement.
  - **Preloaded ids:** known test ids are read once at startup, so only new or moved tests are upserted.
  - **No secondary index on results:** per-test queries use a skip-scan of the `(run_id, test_id)` primary key instead (0.15ms), and inserting got 2× faster.
  
  Pragmas made little difference because a run is one transaction. Packing rows into JSON for `json_each` was slower.
- **Pragmas:**
  - WAL with `synchronous = NORMAL`, which is safe against corruption; OFF isn't, and was no faster;
  - `wal_autocheckpoint = 0`, with a checkpoint when the database opens, which overlaps the loader's boot;
  - `analysis_limit = 400`, then `PRAGMA optimize = 0x10002` after writing, so the skip-scan has statistics.
- **Off the critical path** (done): `require "sqlite3"` alone takes ~35ms, and recording a run waited on three `git` calls (~12ms each), which cost a small project's run ~80ms (0.07s → 0.15s). Now:
  - A run reads what it needs from history before it starts (previous timings, file durations and the tuner's inputs, for its selection) from a small Marshal file, `.quickdraw/plans`, written by the run before. No `sqlite3` is needed for that.
  - Recording happens in a process of its own (`HistoryProcess`), started first. It loads `sqlite3` and runs the `git` calls in parallel while the tests run. When the run ends, it takes a file lock and acknowledges at once, then writes after the run has exited. Whatever opens the history next (`--failed`, `history`, `flaky`, the next run's plan) waits for that lock.
  - It leaves the run's process group, so a terminal, CI or a test stopping the group doesn't cut a write short.
  
  A small run with history now takes ~0.09s, against ~0.07s without.
- **Isolation:** `sqlite3` never loads in the coordinator, so it can't reach loaders or workers. `--failed` and the commands read history in a throwaway fork. The one exception is the no-fork thread fallback, where tests share the coordinator's process.
- **Treated as a cache:**
  - a schema change or a corrupt file rebuilds it;
  - runs and tests not seen for 100 runs are pruned;
  - concurrent runs upsert tests rather than conflict;
  - the schema check runs in an immediate transaction.
- **Known limit:** tests without a description are keyed by line, and repeated descriptions by their order in the file. Editing the file can attach those tests' history to the wrong test.
- **To do:**
  - CI shards each write their own database, and `quickdraw history merge` combines them with `ATTACH`;
  - `quickdraw history` answers common questions, e.g. when a test started failing;
  - optionally, write the history from a detached process so an interactive run returns immediately.

## Speed

- Batched scheduling (done). On 20k trivial tests the old runner took 0.55s; the new one takes 0.27s.
- Slowest files first, using recorded timings (done).
- **Self-tuning worker count.** The best count depends on the suite (seconds; 8 performance cores, 4 efficiency):

  | Workers | 1 | 2 | 4 | 8 | 12 | 16 | 24 |
  |---|---|---|---|---|---|---|---|
  | CPU-bound | 0.62 | 0.40 | 0.28 | **0.22** | 0.22 | 0.22 | 0.24 |
  | IO-bound | 2.50 | 1.33 | 0.78 | 0.47 | 0.37 | 0.32 | **0.28** |
  | Slow file + fast files | 5.16 | 2.69 | 1.58 | 1.00 | 0.95 | **0.68** | 0.72 |
  | Small suite (0.3s of tests) | 0.28 | **0.23** | 0.27 | 0.28 | 0.25 | 0.29 | 0.32 |

  1. **Model** (done, `WorkerTuner`): for a selection with no runs yet, it estimates from history.
     - CPU-bound work saturates at the core count.
     - Waiting work scales it up: about `cores / (1 - waiting share)`, up to 3× the CPU count.
     - Small suites are capped at 50ms of work per worker. Work includes ~10µs of Quickdraw overhead per test, so 20,000 fast tests still get 8 workers.
     - No count helps past the longest test.
  2. **Explore** (done):
     - It uses the fastest count over the last 20 runs of the same selection (the paths asked for), comparing the median of each count's last 3 runs.
     - Within 3% counts as a tie, and the fewer workers win.
     - Every 4 runs it tries a neighbour: ±25%, then ±10%. Each losing try doubles the wait, up to 32 runs. A winning try leads straight to another in the same direction.
     - An untried estimate 1.5× away from the best is tried on the next run.
     - Runs that ran far fewer tests (e.g. files failed to load) and `--failed` runs are left out.
     - Measured: IO-bound suites jump from 8 to 36 workers on their second run (0.30s → 0.10s). The slow-file suite goes from 0.66s to 0.32s. CPU-bound and 20,000-trivial-test suites stay at 8.
  3. **How it's wired:** the coordinator creates channels for the maximum count, raising the open-file limit or capping the count to fit. It chooses while the loader boots, then sends the count down a control pipe. Choosing never delays the loader, and sqlite3 never reaches it.
  4. **Replacement workers** (done):
     - The loader stays alive for the whole run, taking commands from the coordinator over the control pipe: `start N`, then `fork CHANNEL SLOT`.
     - When a worker crashes and work remains, a replacement starts on one of 4 spare channels, in the same slot. It inherits `QUICKDRAW_WORKER`, so it reuses that slot's database and other resources.
     - A crashing test is reported once and never rerun. A file whose loading crashed a worker isn't handed to other workers. Spares are limited, so crashes can't loop.
     - Workers report their pid before `after_forking` runs, and the coordinator also watches the loader's pid. Processes that config or callbacks fork, and that keep pipes open, can no longer hang a run.
  5. **Elastic workers** (done, opt-in with `--elastic`): the coordinator adds workers in new slots with the same `fork` command while tests leave CPU idle (`Elastic`).
     - **When:** every worker is busy and none is starting; the run's tests spend more than half their time off the CPU (so contention can't pass for waiting) and use less than the core count; the machine has idle CPU beyond one CPU kept free, read since the last change (`/proc/stat` every 0.25s on Linux, a long-running `iostat -w 1` on macOS, nothing elsewhere); more than 20% of memory is available; and there's at least 0.25s of queued tests for each worker. It adds as many as the idle CPU covers, counting each worker as using at least 5% of a CPU, up to 3× the CPU count, keeping channels for retries and crash replacements.
     - **History** records the most workers the run had, so the tuner starts the next run there.
     - **Measured** on a shared 12-CPU M-series Mac with a load average of 12–35 from other work (medians; synthetic suites are 1,000 tests of 20ms each):

       | Suite | Off | Elastic | Workers added |
       |---|---|---|---|
       | Sleeping tests, first run (no history) | 2.68s | **1.45s** | 28 |
       | CPU-bound, first run | 4.45s | 4.23s (noise) | 0 |
       | Half sleeping, half CPU, first run | 3.26s | 3.04s (noise) | 0 |
       | Sleeping tests, with history (tuner at 42) | 0.59s | 0.58s | 0 |
       | CPU-bound, with history | 3.76s | 4.36s (noise: tuner state, 0 added) | 0 |
       | Phlex (1,964 tests), with history | 0.34s | 0.35s | 0 |
       | Quickdraw's own suite (419 tests), with history | 21.68s | 21.75s | 0 |
       | 25 trivial tests (cost of starting `iostat`) | 0.29s wall | 0.30s wall | 0 |

       Once history exists, the tuner already picks the count, so elastic only helps a waiting-heavy suite's first run, a new selection (which starts at the core count), or one whose tests have started waiting more. On macOS it can't act until a second into the run.
     - **Before making it the default:** measure on Linux, where it can act four times as often, and on a Rails app, where each new slot creates its databases; retire workers when the CPU is oversubscribed (suites that change from waiting to computing partway through); show added workers in the summary line (it's only in `--timeline` now).
  
  `-p`, `--max` and `--efficiency` still override all of this; the summary shows how the count was chosen.
- Shared-memory queue (C extension): only worth it if profiling shows IPC is a meaningful share of runtime after batching.
- **Cost of per-test stats** (done): about 1.7µs per test. Phases read only the wall clock (~30ns). The CPU clock (~200ns), GC time and allocations are read once per test. Everything is sent as integer nanoseconds, because Marshal writes floats as text: that alone took a result from 3µs to 12µs. It's cheap enough to stay on for every run.
- Eager loading the app in the loader (shared through copy-on-write) versus lazy autoloading in each worker (parallel but duplicated): measure both on real Rails apps before picking a default.
- Load once, fork many: `Process.warmup` before fork, YJIT in workers, GC tuned for short-lived workers.
- **Watch mode:**
  - **The watcher:** `listen` with FSEvents takes about 120ms per change at its default settings. With `latency: 0.01` it takes about 35ms (done). It keeps a record of the whole tree (+25MB for 50,000 files), and polling takes 1–2.6s per change.
  - **Scope:** watch only the directories that hold files the loader actually loaded (its `$LOADED_FEATURES`), plus test files and config.
  - **Warm loaders** (done): a Rails app's rerun takes about 100ms rather than 600ms, and a small project's 34ms rather than 40ms.
    - Each loader forks from the watch process and stays booted between runs; each run forks a fresh set of workers from it (`WarmLoaders`). Test files load in workers, so changing a test never needs a reboot.
    - A run is a fork of the watch process, so it can't hand an existing loader new pipes without a UNIX socket, which loaders mustn't load. Instead, each run makes named pipes (`mkfifo`) for its control, report and channels, in a private temporary directory, and tells the loader where they are over a pipe it inherited from the watch process. Workers' pipes behave as before: closing means the worker is gone. The run knows the loader has finished with it when the loader writes to and closes a `finished` pipe, or exits.
    - Before a run, the watch process asks each loader what the changes mean: nothing if it didn't load the files; a reload if config's reloader (`config.reloader`, which `config.rails` sets to Rails' reloader when the test environment enables reloading) reloads them; otherwise a reboot. A file it loaded is one in its `$LOADED_FEATURES`, or one added to or deleted from a Zeitwerk directory, which the autoloader would otherwise miss. Changes under `config/`, to a Gemfile or lockfile or to `.ruby-version` reboot every loader, and a group's own Gemfile or lockfile reboots its loader. A config that failed to boot boots again on any change. A loader that is rebooted exits (running its `at_exit` hooks, within 3s) before its replacement boots, so they never compete for a port, say.
    - The loader never runs tests, so reloading leaves no stale state: a Spring-like speed-up without Spring's problems.
    - A loader that exits is started again before the next run; quitting or Ctrl-C asks every loader to stop, waits 3s for them to exit (running their `at_exit` hooks), then kills what's left.
    - A group's loader starts warm after the group's first run, which uses a loader of its own as before.
    - **Still to do:** a run makes named pipes for every channel it could use (as many as 3× the cores), though it starts far fewer workers; reboots happen when a run needs them, rather than in the background as soon as a file is saved; files config evaluates with `load` (rather than `require`) outside `config/` aren't tracked, so changing one doesn't reboot.
  - **Only affected tests:** a changed test file reruns that file. A changed app file reruns the tests that cover it, using the impact map, then everything that failed.
  - **Dependencies:** `rb-fsevent` 0.11.2's `--file-events` mode refuses to run on macOS 27 (a version-check bug). Its default directory mode works. Dropping `listen` for a small native watcher would remove the dependency and the tree record.
- Test impact analysis: per-test coverage map, so `--changed` and watch mode run only affected tests.
- CI sharding balanced by timings (`--shard 2/8`), and an optional dynamic cross-machine queue.
- Load profiling: time spent in helpers and each test file's `require`s.

## Reliability

- **Crash isolation** (done): a dead worker reports the in-flight test (segfault, OOM, `exit!`). The rest of its batch is requeued, and a replacement takes over its slot (see Speed).
- **Hang detection** (done):
  - `test("…", timeout: 5)`, with a default of `Quickdraw::Config.timeout` (300s).
  - A watchdog thread in each worker sends every thread's backtrace and exits; the hung test's thread comes first and the others are listed as details. A replacement worker continues the run.
  - A test that finishes after its timeout, before the watchdog could run, is still reported.
  - If the watchdog can't run (C code holding the GVL), the coordinator kills the worker 5s after the timeout.
  - **Still to do:**
    - A timed-out test's `defer` blocks (and so its `tmpdir`) don't run, because the worker exits mid-test.
    - A message half-written by a dead worker, whose pipe a child process holds open, blocks the coordinator. Reading needs non-blocking framing.
- **Per-test output capture** (done): each worker points file descriptors 1 and 2 at one file while it runs tests, so stdout and stderr stay in order and include subprocesses and C extensions. After each test the worker takes what's there (an `fstat` when nothing was printed) and sends it with failures and errors only; the last 64KB is kept. Shown in the human, agent (last 20 lines), JSON and JUnit (`system-out`) outputs. The file has a path the worker sends the coordinator, which reads it when a test crashes or hangs its worker. Loading files and the time between batches aren't captured, so what config and test files print shows as usual, and Ctrl-C shows what the interrupted test printed. `--no-capture` streams output live.
  - Still to do: output a leaked thread or process prints after its test ends goes to the next test; C code writing through buffered libc stdio isn't flushed at test boundaries (core Ruby can't call `fflush`), so it can land with a later test.
- **Flaky detection:**
  - `quickdraw flaky [--runs N]` (done) runs the selection N times with new seeds and lists tests that passed in some runs and failed in others, with the failing seeds.
  - `quickdraw history` (done) lists tests that passed and failed on the same code across recent runs.
  - Retries (done): a failure is retried up to `--retry N` times (default 1) in a fresh worker, started in the slot of an idle one, that has loaded only the failing test's file. Its first result is held until a retry passes, and then reported as flaky, with a `bisect` command. Flaky tests fail the run unless `--allow-flaky`. History keeps where the first run happened, so `bisect` and `qt history` work on flaky tests. Up to 10 tests a run are retried, with channels reserved for their workers. Off with `--fail-fast`, in `qt flaky` runs, and without fork.
  - Still to do: retrying crashes and timeouts, which may be flaky too; JUnit's `rerunFailure` elements for each failed retry.
- **Order bisection** (done): `quickdraw bisect PATH:LINE` takes the last run where the test failed and the tests its worker ran before it, from history. It checks the test passes alone and fails after them, then replays halves until the fewest that still make it fail are left. Replays run in a worker forked from a loader that boots config once, as in a run, with the run's seed. Still to do: failures that need tests from both halves are reported as the whole remaining set, not narrowed further (ddmin).
- **Leak detection:** snapshot global state around tests — globals, new constants, `ENV`, `Time` stubs, live threads, open files, temp files — and blame the test that leaked.
  - Done, after every test, as warnings (`--leaks fail` makes them errors, `--leaks off` skips them), for about 0.6μs per test:
    - threads still running that started in the project (outside `vendor/`), from comparing `Thread.list`, so the threads gems start lazily (Timeout's, connection pool reapers) aren't blamed;
    - child processes not waited for. `waitpid(-1, WNOHANG)` costs about 2μs in a worker, so it only runs after `spawn`, `fork` or `IO.popen` set a flag (prepended to those methods before `after_forking` runs). It's skipped in a worker where config or a test file started a process, since waiting could reap one that code waits for later; after a leak, checking pauses until the leaked processes exit. `ps` names running ones, by program only, since arguments can be secrets;
    - `ENV` changes, by name only (values can be secrets). `ENV.to_h` takes about 7μs, so ENV's writers set a flag (prepended to `ENV`'s singleton class).
  - Still to do: open file descriptors (listing `/dev/fd` takes about 20μs and `dup` about 4μs, and Files waiting for GC would be noisy, so an opt-in mode), globals and constants, `Time` stubs, temp files; processes started by `PTY.spawn` or C code, and checking processes again once config's have exited (tracking pids from the hooks); ignoring known leaks in config; rerun commands and `bisect` that keep `--leaks fail`.
- **Stress modes:** `--repeat N`, run each test many times across random workers, randomised `TZ` and locale.
- Tests with zero assertions are flagged.

## Reports

- **Humans:** failures shown as they happen, relative clickable `path:line` (OSC 8 links), source excerpt of the failing line, structured diffs for strings, hashes, arrays and objects, filtered backtraces, slowest tests and files, a rerun command for each failure, and a comparison with the last run (newly failing, fixed, flaky).
- **Assertion introspection:** on failure, rerun the test with instrumentation to show the value of each sub-expression in the failing assertion, at zero cost to passing tests.
- **CI** (done):
  - no ANSI when output isn't a TTY or `NO_COLOR` is set;
  - under GitHub Actions, an annotation on the failing line for each problem, plus a job summary;
  - `--format junit:PATH` writes JUnit XML. Any format can go to a file, and `--format` repeats, so one run can write several (done).
  
  Still to do: an HTML report.
- **AI agents** (done):
  - **Detection:** the agent format is chosen from the environment (`CLAUDECODE`, `CODEX_SANDBOX` and others), or with `--format agent`.
  - **Each problem:** one compact block with the source line it failed on, a trimmed backtrace and a rerun command. The first 10 are shown in full and the rest one line each.
  - **Result:** one line, last, where truncated output keeps it.
  - **`--format json`:** one event per line, with a failing test's output and any leaks. Anything printed outside tests (or with `--no-capture`) goes to stderr so the stream stays valid.
  
  Still to do: truncating large values with a pointer to the full detail, and possibly a `quickdraw mcp` server.
- **Worker timeline** (done): `--timeline` records, in the coordinator only, when each worker starts, loads a file, is given a batch, sends a result and stops (an array per event; nothing without the flag). Each worker slot's time splits into phases: running tests, between tests in a batch, loading files, starting (fork and `after_forking`), waiting for work, replacing workers (group moves, retries, crashes) and idle at the end. A test that crashed its worker counts as running until it exited. The summary gives booting, running and stopping times, the phase shares, and the tests still running once the first worker ran out of work (the long poles). `.quickdraw/timeline.html` is a Phlex-rendered Gantt chart per slot, with narrow neighbouring batches drawn as one block, the slow tests by name, and markers where workers were added.
  - Cost, on 20,000 trivial tests with 8 workers: the run itself 0.25s → 0.26s (noise-level), and writing the chart (loading Phlex, rendering) about 0.1s after it.
  - Measured with it on Phlex (8 workers, 1,964 tests): ~0.2s booting config, ~0.35s running; 78–82% of worker time running tests, 3–7% between tests, 3–4% loading files, 3–4% starting and 7–9% idle at the end, which is the slowest few tests (~0.3s each) finishing.
  - Still to do: worker-side timestamps, so the coordinator's own delays (reading results under load) aren't counted against workers; the timeline in JSON for other tools.
- **Invisible differences made visible:** when diffed lines differ only by whitespace, control or format characters (trailing tabs, U+200B), escape them in the diff (from #70).
- `assert_equivalent_html` shows a diff of the prettified documents, not just both documents (from #55).

## CLI

- `quickdraw` with no arguments runs every `*.test.rb` file.
- **Selection** (done; #47, #13, #17, #16):
  - `path:line[:line…]` runs the test starting nearest at or above each line, as `rails test` does.
  - `--name` and `--exclude` take a string or `/regex/flags`.
  - `--failed` and `--fail-fast`.
  - All of these combine freely, and a filter that matches nothing fails the run rather than passing.
  
  - `--changed` (done) runs test files changed since the last commit, and those whose tests ran a changed source file in their last `--coverage` run. Config, Gemfile and test helper changes run everything, and non-Ruby changes are named as not mapped. Without a map, it runs changed files' counterparts and says so.
  
  Still to do: tags, and `--changed` against any git base.
- Directories as arguments, searched for test files (done).
- `SEED` env var as well as `--seed` (done), and `rand` seeded per test from the run seed (done) (from #72).
- **Usage errors** (done): one line, with "did you mean" for options, formats and paths (keeping `:line`), and no backtrace. Exit status 2, apart from 1 for failures and 130 for Ctrl-C.
- **Help** (done): options grouped by purpose, with examples and exit statuses. `--version`.
- **Ctrl-C** (done): the first stops starting tests, lets running tests' teardown and deferred blocks finish, and reports what finished, counting the rest as not run. A second exits at once. Interrupted runs aren't recorded, so they can't mislead worker tuning.
- **Live progress** (done): on a terminal, a bar on the bottom row, below a scroll region holding everything else, so what tests print can't collide with it. The total and time left come from the last run of the same selection. Problems are printed as they happen, with a one-line-per-problem recap at the end. What tests print is captured and shown with their failures; with `--no-capture`, workers write it unbuffered, so a hanging test's output shows.
- **Shell completions** (done): `quickdraw completions bash|zsh|fish`, generated from the option definitions and commands, for both `quickdraw` and `qt`.
- **Interactive watch mode** (done): a changed test file reruns on its own, and a changed source file reruns its counterpart's tests (everything when it has none). Config stays booted between runs (see Speed). On a terminal, keys rerun everything, only failures, or tests filtered by path or name. Uses only core Ruby in the process tests fork from: listen runs in its own process, and keys are read with the terminal set by `stty`.
- **Subcommands** (done):
  - `init` creates config, an example test when there are none, and ignores `.quickdraw/` in git.
  - `doctor` checks Ruby, fork, cores, file descriptors, test files, how long config takes to boot, run history, listen and `.gitignore`.
  - `history` lists recent runs, the slowest tests, and flaky tests: those that passed and failed on the same code. Each run records its code as the commit plus a hash of uncommitted changes (tracked files' differences and untracked Ruby files), so a test that fails while you edit and then passes isn't flaky.
  - `counterpart PATH` prints a source file's test or a test's source file; `exe/qc` opens it in `$EDITOR`.
  - `flaky` and `bisect`: see Reliability.
- Debugging (done): `binding.irb`, `binding.pry`, and the debug gem's `debugger` and `binding.break` work in parallel runs, watch mode included. The worker asks the coordinator for the terminal, which goes to one worker at a time; the reporter holds its output until the debugger is done. The worker stops capturing output and pauses the test's timeout, including while it waits its turn, and a flag file makes every other process leave Ctrl-C to the debugger. irb and pry hold the terminal for the call; the debug gem's session, hooked once a file has loaded it, holds it while stopped.
  - Still to do: the debug gem's first stop isn't coordinated when it's loaded inside a test, or stops while the file that loads it is still loading.
- The seed and worker sequences are always printed or recorded, so every run is reproducible.

## Not planned

- Running Minitest and RSpec suites. Quickdraw runs tests written in its own syntax.

## Rails

Rails suites are the biggest and slowest Ruby suites, so this is where Quickdraw has to be best.

- **Detection:** a `config/environment.rb` and `rails` in the bundle switch on Rails support. `quickdraw init` writes the config.
- **Booting:** the loader boots the app once in the test environment, with eager loading in CI. Workers fork from that and share it through copy-on-write. Whether to eager load locally is decided by measuring, as noted under Speed.
- **`config.rails`** (done) boots the app in the loader and sets up the rest of this list that's marked done.
- **A database per worker** (done):
  - the loader disconnects Active Record before forking;
  - each worker slot connects to its own databases, named as Rails' parallel tests name them (`app_test_3`), for every database in `database.yml`;
  - when a worker starts, its databases are created and loaded from the schema, or emptied if the schema is unchanged, as Rails' `reconstruct_from_schema` does.
- **Creating and keeping databases:**
  - skip emptying when the database is already empty, to save time on worker start;
  - two runs at once (watch mode and a manual run, say) share slot databases, as Rails' parallel tests do; a run should reserve its slots' databases, or use others;
  - the number of databases follows the worker count, and extras are left for reuse.
- **Rails' own parallel testing:** Rails' process-based `parallelize` is replaced, since Quickdraw already forks. Its hooks (`parallelize_setup`, `parallelize_teardown`, `parallelize_before_fork`) still run at the matching points, so apps that use them keep working. Threaded `parallelize` is left alone.
- **Isolation between tests:** each test runs in a transaction on every database, pinned so threads it starts share it, and rolled back afterwards (done, through `config.around_test`).
- **Fixtures** (done): `config.rails(fixtures: :all)` or `fixtures :users` in a test class, with accessors, through `ActiveRecord::FixtureSet` rather than `ActiveSupport::TestCase`. Each set loads once per worker database, committed, when a worker starts or a test file declares it. A `quickdraw_fixtures` table in each database records the sets it holds, with a digest of their files (ERB rendered), row counts and the timestamps Rails filled in, so the next run keeps unchanged sets, moving those timestamps to now. A set loads again with any set sharing a table with it or with foreign keys to its tables, so deletes can't cascade to sets that are kept. With 30 tables of 50 rows on SQLite, a worker starts in about 17ms without fixtures, 90ms loading them and 37ms keeping them (9ms of that rendering ERB for digests, 5ms moving timestamps). Still to do:
  - measure on PostgreSQL and MySQL, where loading costs more round trips;
  - `fixture_file_upload` and `file_fixture`;
  - rows changed in place by another process, or by a test whose worker died before it could load them again, are kept by the next run, since only row counts are checked;
  - a set's model moving to another database doesn't load it again until its files change.
- **Rails test helpers** (done): `Quickdraw::Rails::TimeHelpers`, `JobHelpers` and `MailerHelpers` include Rails' own, run by `MinitestBridge`, which turns their Minitest assertions into the test's. Each cleans up after the test, even a failing one, and costs nothing in tests that don't include it. `assert_difference` and `assert_changes` are Quickdraw assertions taking callables. Still to do: Action Dispatch integration test helpers (`get`, `assert_response`) and Action Cable's.
- **Other per-worker resources:**
  - Active Storage and cache directories (`tmp/storage-3`);
  - Redis database numbers or key prefixes;
  - Capybara ports (Puma's are done, by `config.browser`);
  - Elasticsearch/OpenSearch index prefixes;
  - each through a documented hook built on `QUICKDRAW_WORKER`.
- **System tests** (done, by `config.browser { Rails.application }`; see Browser testing): a Puma server in each worker's threads, sharing the test's pinned transaction, so the page sees its records. Still to do: Rails' `ActionDispatch::SystemTestCase` suites.
- **Framework-aware reporting:**
  - SQL queries and time per test, from Active Support notifications (done), and likely N+1 queries;
  - factory_bot factories run per test (done);
  - log level warnings when debug logging is slowing the suite.

## Native syntax

- A rich assertion set, plus pattern matching via `===`. `assert_match(actual, pattern)` (done) uses `===`, so regexes, ranges and classes all work.
- **`defer { … }`** (done): cleanup registered inside a test, run after teardown in reverse order, even when the test fails.
- **`tmpdir`** (done): a fresh directory removed after the test. Core Ruby only, never follows symlinks, and handles read-only entries.
- Top-level methods and constants in a test file are visible only to that file's tests (done; the README promised this but it didn't work for methods).
- **Testing CLIs and processes:** the integration tests' helper (`test/support/integration.rb`) runs a command against a throwaway project, with a deadline that kills the whole process group, and waits for the process rather than for its output to close. Worth turning into a public tool for testing any CLI.
- Snapshot testing with an update mode.
- Table-driven tests.
- Allocation and performance assertions.
- Stubs and mocks that are always reset.
- `describe` blocks for grouping, with names that nest into the test name (done). Each block is a subclass, so `setup`, helpers and `super` work as with any class.
- `test "name"` without a block is reported as pending, and `skip "reason"` skips a test (done). Both are listed in the human output, counted everywhere, and ignored by `--failed`. Still to do: a test with a block must make at least one assertion (#58).
- **Structured diffs** (done): `assert_equal` on multi-line values diffs `Quickdraw::Inspector.pretty` output, which expands hashes, arrays, sets, Data, Structs and plain objects one element per line.
- `assert_in_delta` and `refute_in_delta` (done), reporting how far apart the values are.
- Suite-level and per-file `before`/`after`/`around` hooks (#5).
- Per-test isolation markers: "run alone in its worker" and "run in its own fork" (#56).
- A per-test `seed` reader for property and fuzz tests (from #72).
- If `skip` returns, a skipped test that starts passing fails with "remove skip" (from #71).

## Coverage

- **Built in** (done, `--coverage`), using the core `Coverage` module (lines, branches, methods). Each loader starts it before config loads, then takes and clears what booting covered before forking workers, so workers report only what they run and boot code isn't counted once per worker. Workers send theirs when they stop, and the coordinator merges everything, across groups too. Only the project's own files count: not tests, `vendor`, `tmp` or Quickdraw. Lines in methods no test called count as uncovered, since Ruby counts a `def` line as run when its file loads. Test processes only load `Coverage` with `--coverage`.
- **Humans** (done): a terminal summary with totals, changed lines that no test ran, the least covered files with their uncovered ranges, and files no test loaded.
- **HTML report** (done): `.quickdraw/coverage/index.html` with totals, changed lines that didn't run, files no test loaded and every file least covered first, and a page per file with its source, hit counts, uncovered lines, branches never taken and methods never called. Built with Phlex in the coordinator, so Phlex never reaches test processes. Works from disk, in light and dark.
- **AI** (done): the same, as compact `path:ranges` lines. Still to do: the code at those lines and the tests nearest to them.
- **Files** (done): `.quickdraw/coverage/lcov.info` for editors and coverage services, and `coverage.json` with everything, and coverage totals in the JSON stream's finish event.
- **Changed lines** (done): coverage of the lines changed since the last commit, staged or not, and of untracked Ruby files. Still to do: any git base (`--coverage-base main`), and a threshold that fails CI.
- **Which source files each test file runs** (done), for `--changed`. Measured on 105,000 loaded lines, taking coverage costs 8.6ms in lines, branches and methods mode but 0.3ms for lines alone, so taking it after every test would add ~9ms per test. Workers take it per batch instead, and after loading a file, and keep their own totals. A file counts as run if any of its lines, methods or branches ran, since calling a one-line method doesn't count its line again. Each `--coverage` run replaces its test files' entries in history. Still to do: per-test granularity, for "which tests cover this line?". `mutate` measures that for the methods it mutates with targeted `TracePoint`s, which cost nothing in other code, rather than with `Coverage`, whose cost grows with all loaded code.
- Coverage of `eval`'d and generated code mapped back to source where possible.

## Suite profiling

Slow suites are rarely one slow test. Usually it's a small cost paid by every test: password hashing at full cost, a factory that builds a whole object graph, debug-level logging, a `before` hook that resets too much. Quickdraw should find these on its own.

- **Always on, core only:** each test event carries wall time, CPU time (`CLOCK_PROCESS_CPUTIME_ID`), GC time and allocation deltas (`GC.stat`), split into setup/hooks, body and teardown. Wall time far above CPU time means waiting (IO, sleep, network). A one-line summary flags when hooks or GC dominate.
- **Profile mode** (done, `--profile`): a sampler thread in each worker records the main thread's stack while tests run, using `Thread#backtrace_locations`, so it's core Ruby only. A waiting thread only gets the GVL every timeslice (100ms by default, so about 8 samples a second of CPU-bound code), so `--profile` restarts Ruby with `RUBY_THREAD_TIMESLICE=1`, which gives about 90 a second for CPU-bound code and far more for code that waits. Ruby 3.3 ignores the setting. Since samples come at uneven rates, each is weighted by the time since the previous one. Same-named methods are told apart by the line of their `def`, since labels don't name classes in a test file's anonymous scope. Samples are merged in the coordinator into one profile of the suite.
- **Shared-cost report** (done): methods ranked by their share of all samples, with their share as the innermost frame and how many tests they ran in, so a cost in most tests stands out. Still to do: the estimated saving in seconds, and grouping by call path ("`create(:user)` → `BCrypt::Password.create`").
- **Counters:** `Quickdraw::Counters.add(name, seconds)` counts anything per test (done). Results carry each test's counts, and the summary shows them per test. `config.rails` counts SQL queries and factories (done). Still to do: real outbound HTTP and `sleep` calls.
- **Boot profile:** `require` time by file and gem, and time to load each test file.
- **GC advice:** GC's share of the run and suggested heap settings.
- **Branch comparison:** "this branch made the suite 12% slower; most of it is `Foo#bar`", using run history.
- **Output:** an interactive flame graph for humans; for AI, a ranked text list of costs with call sites and estimated savings.

## Browser testing

- **Built on Playwright's JavaScript API** (done): `config.browser("test/system/**/*.test.rb") { app }` runs the matching files in a `browser` group, which loads Puma, and tests `include Quickdraw::Browser` for `page`, `visit` and the assertions below (`lib/quickdraw/browser.rb`). Chromium, Firefox and WebKit. Each worker starts Node with `bridge.mjs`, which `require`s Playwright's package (the project's `playwright-core` or `playwright`, or the one `qt browser install` installed) and answers one line of JSON with one line of JSON on stdio (`Bridge`). It launches the browser as soon as it starts, so that overlaps with the worker loading test files, and keeps the next pages open. Objects that aren't JSON stay in Node as handles, freed when their test's page closes; arguments can name a handle, a chain of calls on one, or a RegExp. In Ruby, `Remote` is any of them, with Playwright's methods in snake case: methods that return locators without waiting are sent with the next call that needs an answer, so `page.get_by_role("button", name: "Go").click` is one round trip, as it was through playwright-ruby-client. A function string given to `evaluate` and its kin is made a function, as Playwright's other language clients do. This replaced playwright-ruby-client, its Ruby threads, its encoding workaround and its pinned driver version. Still to do: native traces; `page.on` events and routes, which need callbacks from Node; Firefox here fails to launch with Playwright 1.64's build ("Could not find profile folder", directly from Node too), so its tests skip.
- **Speed against playwright-ruby-client**, both on Playwright 1.64.0 and its Chromium on an M-series Mac, medians of 40 (the machine was busy, load average 10–60, so suites are noisy):

  | | playwright-ruby-client | Bridge |
  |---|---|---|
  | Loading it, once in the loader | 117–144ms | 0 |
  | A worker's driver or Node, blocking it | 142ms | 2.5ms (spawning) |
  | Then the browser and first page, in the background | 81–87ms + 27ms | 257–264ms for Node, Playwright, the browser and the first page |
  | Taking the next page | ~1ms (a Ruby thread) | 0.05ms |
  | `visit`, `evaluate` | 6.4–6.6, 2.3ms | 7.3, 2.3ms |
  | Click by role | 31ms | 30–31ms |
  | `assert_text`, `assert_selector` (passing) | 1.1, 0.6ms | 1.1, 0.7ms |
  | `fill` by label, closing a page | 1.7, 1.2ms | 1.8, 1.2ms |

  Per command they're the same: either way it's one round trip to a Node process, and the time is Playwright's (a click is its actionability checks, which wait on animation frames: a trial click alone is 18ms, `force: true` 1.6ms). The bridge is quicker to start, since nothing waits for Node, and opens two pages ahead, since tests that take a few milliseconds wait on ~30ms renderers. 200 `visit` + `assert_text` tests: 6.3s against 6.2s with one page ahead and 4.7s with two on one worker; 3.2s against 3.0s on four; 3.3s against 3.1–3.3s on eight (a third page, or two with four or more workers, made no difference). Another run, busier: 8.7s against 8.1s on one worker, 6.5s against 5.6s on four, 4.2s against 3.5s on eight; WebKit, whose pages are slower, 29.7s against 15.9s on one worker, 10.0s against 7.3s on four, 8.4s against 8.9s on eight. A run of one test: 0.52–0.74s against 0.39–0.40s with Chromium, 1.19s against 0.78s with WebKit.
- **Setup** (done): `qt browser install [BROWSER …]` installs Playwright's `playwright-core` (the version pinned in `Executables::PLAYWRIGHT_VERSION`) from npm, unless the project has its own: checked against npm's sha512, extracted in Ruby, into a staging directory renamed into place in the user's cache (`~/Library/Caches/quickdraw`, `$XDG_CACHE_HOME/quickdraw`, or `QUICKDRAW_BROWSERS_PATH` for CI caches). Then Playwright's own `install` puts the browsers, config's by default, where it keeps them (`--only-shell` for headless Chromium alone). It checks Node is new enough for the package's `engines`. A failed download says it may be offline; nothing downloads during a run. `qt doctor`'s Browser row: Puma (unless the group has its own Gemfile), the package, Node, and that `install --dry-run`'s directories exist. A missing Puma raises `MissingGem` when the group boots, saying to add it to the Gemfile's test group. Still to do: `--with-deps` for Linux.
- **A CDP prototype** (measured, then dropped for Playwright's three browsers): driving Chromium over `--remote-debugging-pipe` from Ruby, with locators and actionability in an injected script, a worker's browser was ready in ~110–145ms, a click took 0.3ms in a document already used (3.4ms in a new one) against Playwright's 31ms, and 200 visit-click-assert tests took 4.4s against 10.7s on one worker and 3.8s against 5.5s on eight. Its speed came from skipping Playwright's frame-by-frame actionability checks, not the Node hop. Ruby pipes are non-blocking, which Chromium takes for the pipe closing, so a child's ends must be made blocking.
- **A browser per worker** (done), rather than the coordinator owning browser servers as first planned. Measured with Chromium's headless shell on an M-series Mac, a worker starts the driver in ~140ms and launches the browser in ~100–130ms, in the background while it loads test files; connecting to a shared `launch-server` takes ~50ms, but every worker's pages then share one browser process. Per test (a context, a page, a click and two waits), the shared browser was as fast or faster with 1–4 workers (83ms against 86ms, 99ms against 112ms) and slower with 8 (200ms against 153ms), so a browser per worker scales better with cores. It also keeps the coordinator free of browser code. (Measured with playwright-ruby-client on a busy machine; worth repeating.)
- **Isolation is a fresh browser context per test** (done), like incognito: a context takes ~1ms but its page ~30ms (a renderer process), the bulk of a browser test's overhead. Each worker's Node process keeps the next two tests' pages open, opened at once (measured 200 `visit` + `assert_text` tests with 1 worker through playwright-ruby-client: 9.5s without a spare page, 6.7s with one, 5.1s with two; through the bridge, 6.2s with one and 4.7s with two; two made no difference with 4 or more workers, which compete for the CPU, but cost nothing either). Closing a context takes ~1.5ms. The summary counts `pages` per test with the time spent waiting for them.
- Each worker gets its own app server (done): Puma in the worker's threads on any free port (or `port:` plus the worker's number), sharing the test's pinned transaction under `config.rails`. A test waits for the app to finish serving its page's requests (through `rack.response_finished`, so after the body and completion callbacks) before its transaction rolls back, and raises what the app raised while serving them, from Puma's `lowlevel_error_handler`. A request still running after the timeout stops the worker's later browser tests, since it may write outside any transaction. Still to do: without fork, every group's setup runs, so a run with no browser tests still boots the app for them; and concurrent runs in one checkout share `.quickdraw/browser/`, as they share history.
- **Waiting assertions** (done): `assert_text`, `refute_text`, `assert_selector` and `refute_selector` are one request each, waiting in Node with Playwright's locators (`filter({ hasText })` and `waitFor`, a case-sensitive RegExp for text as `toContainText` matches, and polling `count()` for `count:`), so Playwright retries in the browser rather than Ruby polling. A failure says what the element's text was, or how many matched. `sleep` in a browser test warns (in the test's output) and is counted (`sleeps` in the summary). Still to do: URL and title assertions, Playwright's call log and accessibility snapshot in failures, and showing the sleep warning for passing tests too.
- **Failure artifacts** (done): a screenshot, the HTML and the console log (with uncaught errors) in `.quickdraw/browser/`, saved when the test first fails or errors, while its page is open, and shown with the failure message or error details. The directory is emptied when the group boots. Still to do: network log and a Playwright trace; full traces or video recorded only when a test is retried; artifacts for a test that times out, since the watchdog exits the worker.
- Run the same browser tests against several engines in one run, as groups.
- **AI output:** the accessibility tree and the relevant DOM around the failed element, not just a screenshot path. A waiting assertion's failure already includes Playwright's accessibility snapshot of what it waited on.
- **Testing this:** `test/integration/browser.test.rb` runs the same tests with Chromium, Firefox and WebKit, more on the Ruby API with Chromium, and `qt doctor`'s Browser row, the missing-Puma error and `qt browser install` (offline, through a proxy that refuses, so a test never downloads). They need Puma installed (outside Quickdraw's bundle), Node and Playwright with the browser; a browser's tests skip with the reason otherwise. `QUICKDRAW_PLAYWRIGHT`, `PLAYWRIGHT_BROWSERS_PATH` and `QUICKDRAW_NODE` point them at a package, its browsers and Node. CI doesn't run them yet.
- **Debugging:** `--headed` and pause-on-failure, which run that test serially with a visible browser.
- Visual snapshot comparison, built on snapshot testing.
- **Compatibility:** existing Capybara suites keep working with their current drivers; the Playwright driver gets the full feature set.
- Browser tests are the slowest tests, so the scheduler starts them first, using timing history.

## Fuzzing, properties and mutation testing

- **Property-based testing** (done): `check(array(integer)) { |list| … }` in any test. Generators for core types compose with `map`, `filter`, `flat_map` and `generator { |choices| … }`. Shrinking works on the sequence of choices that made a case, as Hypothesis does, so it works through composition: it deletes and zeroes spans of choices, lowers each choice by binary search, lowers a length while deleting what it would have generated, and deletes runs of up to four adjacent spans (a key, colon and value that only parse together). A failing case is saved to `.quickdraw/properties/`, replayed first, and deleted once it passes; a property can have several saved, as fuzzing saves what it finds there. Cases come from the test's seed, so `--seed N` repeats them. 100 cases of small integer arrays take about 0.6ms. Properties run as ordinary tests, so they get parallelism and reporting for free. Still to do: a default case count in config, honouring `--no-history` for saved cases, shrink passes that move amounts between values (a sum over 9 can stop at `[5, 5]` rather than `[10]`) and sort them, reporting how cases were distributed, and stateful (model-based) properties.
- **Fuzzing** (done, `quickdraw fuzz`): `fuzz "name", generators do |values| … end` defines a test that's an ordinary property in test runs; `qt fuzz` runs it, or any test's first `check` given by line, for `--seconds` on every worker, guided by the code its cases reach.
  - **Feedback:** edges between lines of the project's own methods (not tests', gems' or Quickdraw's), with hit counts bucketed by powers of two, as AFL does. Each method gets a `TracePoint` targeted at it (`enable(target:)`, which covers its blocks), found by walking `ObjectSpace` once, then again whenever `$LOADED_FEATURES` grows, for autoloaded code. Measured against `Coverage` read after each case (it has no way to read one file): lines cost 3µs a case on a small parser, but 55µs with a few standard libraries loaded, and lines, branches and methods 1.6ms, since reading costs in proportion to everything loaded since it started; `oneshot_lines` 12µs, but without counts. Targeted tracing costs about 9µs a case on that parser's corpus (1.8×), whatever else is loaded.
  - **Cases:** kept when they reach a new edge or count, as choices, in `.quickdraw/fuzz/<property>/`, a file each, shared by every worker (each reads the others' every 0.2s) and every later run. New cases change a kept case's choices: replace one within its recorded limit (often 0 or the limit) or nudge it, delete, duplicate or zero a span, splice or insert a span from another kept case, or drop the end for fresh choices; one to four changes at once. Newer cases are picked more often. A tenth are fresh. `string` and `bytes` take a `dictionary:` of words, a quarter of their pieces.
  - **Findings:** an assertion or error is reported as found, then shrunk in place with the property's shrinker and reported again, then fuzzing carries on, skipping failures with the same signature. Edges are numbered from a hash of their file's path, so workers' agree. A property whose filters discard every case is reported, as `check` reports it. Each worker fuzzes in a fork, writing each case's choices (and how many cases it's run) to a file with one `pwrite` before running it, about 4µs on macOS; if the fork dies, or reports no progress for `--timeout` plus 0.2s, the worker reads the case, shrinks it with a fork per attempt, and fuzzes on in a new fork that skips it. Findings are saved with the property's failing cases, so test runs replay them first.
  - **Speed:** on a JSON-like parser of about 80 lines, 29,000–37,000 cases a second on one worker and 70,000–113,000 on four (an M-series Mac with other work running, load average 9–20). A planted bug behind the words `let x = 42` in order, with those words as a dictionary, took 190–2,200 cases (median about 1,400) guided and 330–21,000 (median about 4,200) with tracing turned off, over eight seeds each.
  - **Still to do:** fuzzing a test's other properties; culling the corpus to the smallest case for each feature; weighting cases by how rare their edges are; comparison operands as dictionary words (Ruby can't see them without instrumenting `==`); merging corpora from CI; a progress display that shows edges over time as a chart; groups. Known gaps: code that only runs in a block defined outside a method (a lambda in a constant) isn't traced; a case that crashes or hangs only after earlier cases left state behind doesn't again in a fresh fork, so it's reported unshrunk; minimising a crash or hang can take 10s past `--seconds`; a generator (rather than the property) that crashes or hangs is blamed on the case before; crashes count as one failure whatever the signal, so only the first is reported; a saved case with no choices (from a property of constants) isn't replayed; two `fuzz` tests given the same block object share the last one's generators.
- **Mutation testing** (done, `quickdraw mutate`): mutates the lines changed since the last commit, or given files and lines, and lists survivors as a diff with `path:line`, the method and the tests that ran it, with a score, `--threshold`, and human, agent and JSON output.
  - **Mutants:** Prism finds them in a throwaway process, only in methods defined directly in classes, modules and `class << self`.
    - Conditions: negating, and to `true` and `false`, in `if`/`unless`/ternaries/`case … in … if` guards; `while` and `until` to stop at once; `a && b` to `||`, `a` and `b` (and `and`/`or`); removing `!`.
    - Operators and literals: comparisons, arithmetic and compound assignment (`+=` to `-=`, `*=` to `/=`), `||=` to `=`, `..`/`...`, `true`/`false`, integers to n+1 and 0, floats to x+1 and 0.0, strings (and interpolated ones) to `""`, arrays and hashes to empty and without each element or pair, regexps to `/(?!)/`.
    - Calls: method pairs (`select`/`reject`, `first`/`last`, `any?` to `none?` and `all?`, `min_by`/`max_by`, `take`/`drop`, `start_with?`/`end_with?`, `map` to `each`, `flat_map` to `map`, `reverse_each` to `each`, `public_send` to `send`, `is_a?` to `instance_of?`…); dropping calls that return their receiver changed (`dup`, `to_s`, `strip`, `uniq`, `sort`, `sort_by`, `reverse`, `abs`…); removing a block, `&.` to `.`, `fetch(k)` to `[k]` (not after `&.`); removing each argument, keyword argument and block argument; `super(…)` and `super` to `super()`; `yield(…)` to `yield`.
    - Control flow: removing a statement, each `when`/`in` branch, `return`/`next`/`break` values and a modifier `rescue` (and its value to `nil`); `rescue` and `ensure` bodies to `nil`, which only the tests that reach them run; and a method's body to `nil`. Mutants are keyed to a line that runs: the first statement inside a `begin` or parentheses, and the first `when` of a `case` without a subject, whose own lines have no line event.
    - Skipped as equivalent: identities (`x * 1` to `x / 1`, `x += 0`), string and array `+`/`*`/`+=`, negating an already negated condition, a condition to `false` (or a loop to stop at once, but `begin … end while`) where removing the statement does the same, method swaps and dropped calls whose value isn't used (non-last statements, and the last in a loop or `ensure`; but `reverse_each` and `public_send`), `to_s` in interpolation and conversions of literals of that type, endless ranges, empty strings, `super` to `super()` without parameters, `||=` on a local not assigned before it, an argument equal to the literal default it fills, and duplicates.
    - Skipped as only raising: removing a local variable's assignment, a positional argument to a method the file doesn't define (but the optional ones of `join`, `split`, `round`, `sum`, `flatten`, `rjust`, `ljust`, `center` and `fetch`) or that any of its definitions there requires, a required keyword argument, the block (or `&block`) of a method that needs one (`tap`, `lambda`, `synchronize`…), and any change that cuts a heredoc's opening from its body. Across Quickdraw's `lib`, that's 3,841 argument removals: in the four files measured below, removing arguments went from 50 mutants (1 surviving, most raising ArgumentError) to 8.
    - Measured on `diff.rb`, `filter.rb`, `inspector.rb` and `worker_tuner.rb` with their tests: 283 mutants run (364 with uncovered lines), 65.7% killed, in 0.8s, before; 567 run (720), 70.2%, in 1.3s, after. 71 of the new mutants survive; reading them, 8 are equivalent (bounds checks before an index that gives nil anyway, sorting what's already sorted, a ternary whose condition makes no difference), and the rest are real gaps, such as `nil` inputs, the median of an even count, the `ensure` that cleans up the cycle check, and an untested division-by-zero guard. Integers to -n were tried and dropped: 22 of their 23 survivors duplicated another survivor of the same literal. Assigning `nil` to locals was dropped too: 84 mutants, 2 survivors, both equivalent, the rest killed by NoMethodError.
  - **Applying them:** never on disk. A worker evaluates the mutated method's whole definition inside the same `class`/`module` nesting (so constants resolve as before, including `class Admin::User` found from an outer scope), at its file and line with the replaced lines' newlines kept, with its `frozen_string_literal`, then restores its visibility and `module_function` copy. A mutant whose method was replaced or isn't defined is reported, not run. Removals that would leave a local variable unassigned are skipped, since they only raise `NameError`.
  - **Which tests:** per-test coverage, measured on the spot. The coverage map (or counterparts, without one) picks the test files; each worker loads them, then forks to run each file once unmutated with a `TracePoint` targeted at just the mutated methods (`line` and `call` events), so the rest of the code runs at full speed. A mutant runs the tests that ran its statement's line (or, replacing a body, that called the method), fastest first, stopping at the first failure. That's exact where the per-file map would run every test in every file that touches the source for each mutant, which costs most for survivors, the mutants that matter. The traced run also drops tests that fail unmutated, and gives fresh durations for timeouts. Mutants on lines no test runs are listed but not counted.
  - **Running them:** one loader boots config; each worker only loads test files, so every fork starts from the same state (a baseline run in the worker would leave memoized values that hide mutants). Each mutant runs in a fork of a worker that has its test files loaded, which the worker kills after 3× its tests' traced duration plus 0.5s (a timeout counts as killed). Workers run mutants in parallel from a shared queue. `rand` is seeded with a fixed seed (`--seed`), so property tests kill the same mutants every run, and forks neither replay nor save properties' failing cases. A fork is watched as well as its pipe, which a process a test started can hold open. Ctrl-C reports what finished. Test files that fail to load or crash, and mutants that couldn't be applied or whose worker died, fail the run whatever the score.
  - **Kill matrix** (done, `--matrix`, after Mutineer's): each mutant's fork runs all its covering tests, sending each test's outcome as it's known, so a test that crashes or hangs the fork leaves the row incomplete rather than lost, and a kill before it still counts. Blind tests ran in complete rows and killed nothing; redundant tests made only kills another test made too, in complete rows, judged one at a time. Rows are per test, from the traced coverage, rather than Mutineer's per file. Scores are the same with or without it.
  - **Speed:** 200 one-line methods (2,200 mutants): 1,900–2,100 mutants/s on 8 workers, 300–550/s on one (about 2ms per mutant, mostly the fork), on an M-series Mac with other work running. Five of Quickdraw's own files with their tests (552 mutants): 1.3–2.6s on 8 workers, mostly test time. A mutant that loops forever costs its timeout.
  - **Still to do:** a git base (`--base main`) for CI; skipping mutants whose method and covering tests haven't changed since they last ran; config groups; code outside methods (class bodies, `define_method`, `Data.define` blocks); more operators: symbols (skipped, since a placeholder symbol mostly raises NoMethodError or KeyError), `nil` to a value, default arguments (tried, and dropped until coverage can tell whether a default ran: keyed to the method's call, they'd survive when every test passes the argument), removing a whole `rescue` clause or a `case`'s `else`, `freeze`, `&&=`, and positional arguments to more core methods, from a table of their arities; spotting likely equivalent mutants (`return a if a > b` to `>=`, a bounds check before an index that gives nil anyway); aliases of a mutated method still call the original; per-test coverage recorded by `--coverage`, to skip the traced run. Known gaps: a method first defined while a test runs (a `require` in `setup`) isn't found, so its mutants are listed as not run; reopening a class doesn't bring back refinements a file activated with `using`, so its mutants may raise and count as killed; a mutant runs only its covering tests, so one that passes only after an earlier test in its file set something up counts as killed (running each mutant against an unmutated control in the same order would catch both, at twice the cost); threads `after_forking` starts don't survive the forks.

## Phases

1. Quick fixes: the CI `-t` flag, `--max`/`--efficiency` discarding their result, unprinted seed, the prism/refract break, the undefined `message` in `Runner#work`, dead autoloads.
2. Coordinator/loader split: core-only runtime, batched streaming events, crash recovery, SQLite run history (done). Still to do: hang timeouts.
3. Reporters (human, agent, JSON, GitHub Actions, JUnit) and selection (done). Still to do: an HTML report.
4. Groups: setup blocks (done), then Gemfiles (done).
5. Quickdraw's own syntax and failure output: `describe` blocks, skipped and pending tests, structured diffs, the failing source line (done). Still to do: a fuller assertion set.6. Flaky detection, order bisection, leak detection.
7. Coverage, impact analysis, interactive watch mode, sharding.
8. Suite profiling: always-on timings and GC/CPU counters per test phase, then profile mode with the shared-cost report.
9. Browser testing: Playwright pages through Quickdraw's own Node bridge, per-worker browsers and app servers, waiting assertions and failure artifacts, `qt browser install` and the doctor's check (done). Still to do: events and routes from Ruby, traces, `--headed`, several engines in one run, Capybara compatibility.
10. Property-based testing (done), then mutation testing (done), then fuzzing (done).
11. A nicer-looking CLI and reports. Done: problems open with a FAIL, ERROR or FLAKY badge and the test's name, show the failing line in a numbered code frame (for errors, the first line of the project's code in the backtrace), short values as aligned Expected and Actual lines, and diffs under a coloured legend; help wraps to the terminal with highlighted options; history, flaky, bisect, doctor and mutate share the style. Output scrolls rather than being redrawn: a line for each test file as it finishes, its problems beneath it, and what loading files prints captured and printed whole between lines. The summary leads with a PASSED or FAILED badge and the counts, then a line per problem, the rerun commands, and one-line notes (skips grouped by reason, pending tests, a test that bounds the run, Ctrl-C, --fail-fast); run stats, timing shares and hints are behind --timings.
