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
- Loaders and workers run a core-only runtime: `IO.pipe` + `Marshal`, no `socket`, `json` or `io/console`. Workers ship strings; formatting and diffing happen in the coordinator.
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
  5. **Next — elastic workers:** use the same `fork` command to add workers when CPU is idle and work remains, or stop adding them when memory gets tight.
  
  `-p`, `--max` and `--efficiency` still override all of this; the summary shows how the count was chosen.
- Shared-memory queue (C extension): only worth it if profiling shows IPC is a meaningful share of runtime after batching.
- **Cost of per-test stats** (done): about 1.7µs per test. Phases read only the wall clock (~30ns). The CPU clock (~200ns), GC time and allocations are read once per test. Everything is sent as integer nanoseconds, because Marshal writes floats as text: that alone took a result from 3µs to 12µs. It's cheap enough to stay on for every run.
- Eager loading the app in the loader (shared through copy-on-write) versus lazy autoloading in each worker (parallel but duplicated): measure both on real Rails apps before picking a default.
- Load once, fork many: `Process.warmup` before fork, YJIT in workers, GC tuned for short-lived workers.
- **Watch mode:**
  - **The watcher:** `listen` with FSEvents takes about 120ms per change at its default settings. With `latency: 0.01` it takes about 35ms (done). It keeps a record of the whole tree (+25MB for 50,000 files), and polling takes 1–2.6s per change.
  - **Scope:** watch only the directories that hold files the loader actually loaded (its `$LOADED_FEATURES`), plus test files and config.
  - **Warm loader:**
    - The loader stays booted between changes, and each change forks a fresh set of workers from it. Test files load in workers, so changing a test never needs a reboot.
    - For app code, the loader is pristine (it never runs tests), so it can reload with Zeitwerk before forking. That gives a Spring-like speed-up without Spring's stale state.
    - Changes to config, `Gemfile.lock` or initializers reboot the loader.
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
  - Still to do: a debugger or `binding.irb` needs `--no-capture -p 1` (see CLI); output a leaked thread or process prints after its test ends goes to the next test; C code writing through buffered libc stdio isn't flushed at test boundaries (core Ruby can't call `fflush`), so it can land with a later test.
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
- **Worker timeline:** utilisation per worker, to spot long poles and idle time.
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
- **Interactive watch mode** (done): a changed test file reruns on its own, and a changed source file reruns its counterpart's tests (everything when it has none). On a terminal, keys rerun everything, only failures, or tests filtered by path or name. Uses only core Ruby in the process tests fork from: listen runs in its own process, and keys are read with the terminal set by `stty`.
- **Subcommands** (done):
  - `init` creates config, an example test when there are none, and ignores `.quickdraw/` in git.
  - `doctor` checks Ruby, fork, cores, file descriptors, test files, how long config takes to boot, run history, listen and `.gitignore`.
  - `history` lists recent runs, the slowest tests, and flaky tests: those that passed and failed on the same code. Each run records its code as the commit plus a hash of uncommitted changes (tracked files' differences and untracked Ruby files), so a test that fails while you edit and then passes isn't flaky.
  - `counterpart PATH` prints a source file's test or a test's source file; `exe/qc` opens it in `$EDITOR`.
  - `flaky` and `bisect`: see Reliability.
- Debugging: a debugger or `binding.irb` in a test switches that test to serial with the TTY attached. For now, `--no-capture -p 1` gives it the terminal, though its timeout still applies.
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
- **Isolation between tests:** each test runs in a transaction on every database, pinned so threads it starts share it, and rolled back afterwards (done, through `config.around_test`). Still to do: fixtures, loaded once per worker database and reused across runs while the fixture files are unchanged; and Rails test helpers such as time travel.
- **Other per-worker resources:**
  - Active Storage and cache directories (`tmp/storage-3`);
  - Redis database numbers or key prefixes;
  - Capybara and Puma ports;
  - Elasticsearch/OpenSearch index prefixes;
  - each through a documented hook built on `QUICKDRAW_WORKER`.
- **System tests:** a Puma server per worker on its own port, with Playwright browsers owned by the coordinator (see Browser testing).
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

- **Built on Playwright:** Chromium, Firefox and WebKit, locators that wait automatically, and native traces.
- **The coordinator owns the browsers.** It starts Playwright browser servers before tests begin and gives each worker a connection URL. Workers never pay browser startup, and browser processes never inherit user code.
- **Isolation is a fresh browser context per test** (like incognito) rather than a new browser: milliseconds instead of seconds.
- Each worker gets its own app server port and database, from the same per-worker setup as everything else.
- **Waiting assertions** that retry until a timeout (e.g. "page has text"), plus a warning on `sleep` in browser tests, to remove the main source of flakiness.
- **Failure artifacts:** screenshot, DOM snapshot, console log, network log and a Playwright trace. Full traces or video recorded only when a test is retried.
- Run the same browser tests against several engines in one run, as groups.
- **AI output:** the accessibility tree and the relevant DOM around the failed element, not just a screenshot path.
- **Debugging:** `--headed` and pause-on-failure, which run that test serially with a visible browser.
- Visual snapshot comparison, built on snapshot testing.
- **Compatibility:** existing Capybara suites keep working with their current drivers; the Playwright driver gets the full feature set.
- Browser tests are the slowest tests, so the scheduler starts them first, using timing history.

## Fuzzing, properties and mutation testing

- **Property-based testing** (done): `check(array(integer)) { |list| … }` in any test. Generators for core types compose with `map`, `filter`, `flat_map` and `generator { |choices| … }`. Shrinking works on the sequence of choices that made a case, as Hypothesis does, so it works through composition: it deletes and zeroes spans of choices, lowers each choice by binary search, and lowers a length while deleting what it would have generated. A failing case is saved to `.quickdraw/properties/`, replayed first, and deleted once it passes. Cases come from the test's seed, so `--seed N` repeats them. 100 cases of small integer arrays take about 0.6ms. Properties run as ordinary tests, so they get parallelism and reporting for free. Still to do: a default case count in config, honouring `--no-history` for saved cases, shrink passes that move amounts between values (a sum over 9 can stop at `[5, 5]` rather than `[10]`) and sort them, reporting how cases were distributed, and stateful (model-based) properties.
- **Fuzzing:** coverage-guided input generation, using the `Coverage` module as the feedback signal, with a saved corpus of interesting inputs. Runs as a long-lived mode across all cores.
- **Mutation testing** (done, `quickdraw mutate`): mutates the lines changed since the last commit, or given files and lines, and lists survivors as a diff with `path:line`, the method and the tests that ran it, with a score, `--threshold`, and human, agent and JSON output.
  - **Mutants:** Prism finds them in a throwaway process: comparisons, arithmetic, `&&`/`||`, removing `!`, negating `if`/`unless`/ternary conditions, `true`/`false`, integers to n+1 and 0, method pairs (`select`/`reject`, `first`/`last`, `any?`/`none?`…), removing a statement, and a method's body to `nil`. Only in methods defined directly in classes, modules and `class << self`. Skipped: identities (`x * 1` to `x / 1`), string and array `+`/`*`, removing a local variable's assignment, negating an already negated condition, and duplicates.
  - **Applying them:** never on disk. A worker evaluates the mutated method's whole definition inside the same `class`/`module` nesting (so constants resolve as before, including `class Admin::User` found from an outer scope), at its file and line with the replaced lines' newlines kept, with its `frozen_string_literal`, then restores its visibility and `module_function` copy. A mutant whose method was replaced or isn't defined is reported, not run. Removals that would leave a local variable unassigned are skipped, since they only raise `NameError`.
  - **Which tests:** per-test coverage, measured on the spot. The coverage map (or counterparts, without one) picks the test files; each worker loads them, then forks to run each file once unmutated with a `TracePoint` targeted at just the mutated methods (`line` and `call` events), so the rest of the code runs at full speed. A mutant runs the tests that ran its statement's line (or, replacing a body, that called the method), fastest first, stopping at the first failure. That's exact where the per-file map would run every test in every file that touches the source for each mutant, which costs most for survivors, the mutants that matter. The traced run also drops tests that fail unmutated, and gives fresh durations for timeouts. Mutants on lines no test runs are listed but not counted.
  - **Running them:** one loader boots config; each worker only loads test files, so every fork starts from the same state (a baseline run in the worker would leave memoized values that hide mutants). Each mutant runs in a fork of a worker that has its test files loaded, which the worker kills after 3× its tests' traced duration plus 0.5s (a timeout counts as killed). Workers run mutants in parallel from a shared queue. `rand` is seeded with a fixed seed (`--seed`), so property tests kill the same mutants every run, and forks neither replay nor save properties' failing cases. A fork is watched as well as its pipe, which a process a test started can hold open. Ctrl-C reports what finished. Test files that fail to load or crash, and mutants that couldn't be applied or whose worker died, fail the run whatever the score.
  - **Speed:** 200 one-line methods (2,200 mutants): 1,900–2,100 mutants/s on 8 workers, 300–550/s on one (about 2ms per mutant, mostly the fork), on an M-series Mac with other work running. Five of Quickdraw's own files with their tests (552 mutants): 1.3–2.6s on 8 workers, mostly test time. A mutant that loops forever costs its timeout.
  - **Still to do:** a git base (`--base main`) for CI; skipping mutants whose method and covering tests haven't changed since they last ran; config groups; code outside methods (class bodies, `define_method`, `Data.define` blocks); conditions to `true`/`false`, `while` conditions, string literals, removing arguments and `super`; spotting likely equivalent mutants (`return a if a > b` to `>=`); aliases of a mutated method still call the original; per-test coverage recorded by `--coverage`, to skip the traced run. Known gaps: a method first defined while a test runs (a `require` in `setup`) isn't found, so its mutants are listed as not run; reopening a class doesn't bring back refinements a file activated with `using`, so its mutants may raise and count as killed; a mutant runs only its covering tests, so one that passes only after an earlier test in its file set something up counts as killed (running each mutant against an unmutated control in the same order would catch both, at twice the cost); threads `after_forking` starts don't survive the forks.

## Phases

1. Quick fixes: the CI `-t` flag, `--max`/`--efficiency` discarding their result, unprinted seed, the prism/refract break, the undefined `message` in `Runner#work`, dead autoloads.
2. Coordinator/loader split: core-only runtime, batched streaming events, crash recovery, SQLite run history (done). Still to do: hang timeouts.
3. Reporters (human, agent, JSON, GitHub Actions, JUnit) and selection (done). Still to do: an HTML report.
4. Groups: setup blocks (done), then Gemfiles (done).
5. Quickdraw's own syntax and failure output: `describe` blocks, skipped and pending tests, structured diffs, the failing source line (done). Still to do: a fuller assertion set.6. Flaky detection, order bisection, leak detection.
7. Coverage, impact analysis, interactive watch mode, sharding.
8. Suite profiling: always-on timings and GC/CPU counters per test phase, then profile mode with the shared-cost report.
9. Browser testing.
10. Property-based testing (done), then mutation testing (done), then fuzzing.
11. A nicer-looking CLI and reports. Done: problems open with a FAIL, ERROR or FLAKY badge and the test's name, show the failing line in a numbered code frame (for errors, the first line of the project's code in the backtrace), short values as aligned Expected and Actual lines, and diffs under a coloured legend; the summary has labelled rows and ends with a PASSED or FAILED badge; help wraps to the terminal with highlighted options. Still to do: the live display while tests run, and the other commands' output (history, flaky, bisect, doctor).
