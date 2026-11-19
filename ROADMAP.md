# Quickdraw Roadmap

Goal: the best test runner for Ruby in every dimension — speed, CLI, reports, reliability tooling — that runs its own syntax, Minitest and RSpec suites.

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
- The loader boots shared helpers once, then forks. Workers load test files lazily with `load(path, Module.new)` and report each file's test list to the coordinator. Loading runs in parallel, the first test starts straight away, and each file's top-level constants stay scoped to that file.
- The unit of work is a batch of tests from one file. Batches start at one test and double while the file's tests fit a 20ms budget, so a slow file never hands all its tests to one worker. Workers prefer files they've already loaded.
- Once every file is loaded, an idle worker steals from the file with the most estimated time left, loading it first if the remaining time is worth more than twice the load time.
- The coordinator knows each batch's order, so a worker crash names the in-flight test and requeues the rest of the batch.
- Timing history will seed the batch sizes and file order (slowest first).
- RSpec groups with `before(:context)` still need to stay in one worker.
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
- **Isolation:** `sqlite3` loads only in the coordinator after the loaders fork. `--failed` reads history in a throwaway fork before the loader starts. The one exception is the no-fork thread fallback, where tests share the coordinator's process.
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
- **Per-test output capture:** collect what each test prints and show it with that test's failure, as pytest does, instead of interleaving it on the terminal. Workers flush after every test (done), so a crash no longer loses earlier tests' output.
- **Flaky detection:** retry failures in a fresh worker; a test that passes on retry is reported as flaky, not green. Flake scores tracked across runs.
- **Order bisection:** we record each worker's exact test sequence, so a failure that only happens in a suite run can be replayed serially and delta-debugged down to the minimal polluting test(s). `quickdraw bisect <test>`.
- **Leak detection:** snapshot global state around tests — globals, new constants, `ENV`, `Time` stubs, live threads, open files, temp files — and blame the test that leaked.
- **Stress modes:** `--repeat N`, run each test many times across random workers, randomised `TZ` and locale.
- Tests with zero assertions are flagged.

## Reports

- **Humans:** failures shown as they happen, relative clickable `path:line` (OSC 8 links), source excerpt of the failing line, structured diffs for strings, hashes, arrays and objects, filtered backtraces, slowest tests and files, a rerun command for each failure, and a comparison with the last run (newly failing, fixed, flaky).
- **Assertion introspection:** on failure, rerun the test with instrumentation to show the value of each sub-expression in the failing assertion, at zero cost to passing tests.
- **CI** (done):
  - no ANSI when output isn't a TTY or `NO_COLOR` is set;
  - under GitHub Actions, an annotation on the failing line for each problem, plus a job summary;
  - `--junit PATH` writes JUnit XML.
  
  Still to do: an HTML report.
- **AI agents** (done):
  - **Detection:** the agent format is chosen from the environment (`CLAUDECODE`, `CODEX_SANDBOX` and others), or with `--format agent`.
  - **Each problem:** one compact block with the source line it failed on, a trimmed backtrace and a rerun command. The first 10 are shown in full and the rest one line each.
  - **Result:** one line, last, where truncated output keeps it.
  - **`--format json`:** one event per line. Anything tests print goes to stderr so the stream stays valid.
  
  Still to do: truncating large values with a pointer to the full detail, and possibly a `quickdraw mcp` server.
- **Worker timeline:** utilisation per worker, to spot long poles and idle time.
- **Invisible differences made visible:** when diffed lines differ only by whitespace, control or format characters (trailing tabs, U+200B), escape them in the diff (from #70).
- `assert_equivalent_html` shows a diff of the prettified documents, not just both documents (from #55).

## CLI

- `quickdraw` with no arguments discovers Quickdraw, Minitest and RSpec tests.
- **Selection** (done; #47, #13, #17, #16):
  - `path:line[:line…]` runs the test starting nearest at or above each line, as `rails test` does.
  - `--name` and `--exclude` take a string or `/regex/flags`.
  - `--failed` and `--fail-fast`.
  - All of these combine freely, and a filter that matches nothing fails the run rather than passing.
  
  Still to do: tags, and `--changed` (git diff plus the impact map).
- Directories as arguments, searched for test files (done).
- `SEED` env var as well as `--seed` (done), and `rand` seeded per test from the run seed (done) (from #72).
- **Usage errors** (done): one line, with "did you mean" for options, formats and paths (keeping `:line`), and no backtrace. Exit status 2, apart from 1 for failures and 130 for Ctrl-C.
- **Help** (done): options grouped by purpose, with examples and exit statuses. `--version`.
- **Ctrl-C** (done): the first stops starting tests, lets running tests' teardown and deferred blocks finish, and reports what finished, counting the rest as not run. A second exits at once. Interrupted runs aren't recorded, so they can't mislead worker tuning.
- **Live progress** (done): on a terminal, a bar on the bottom row, below a scroll region holding everything else, so what tests print can't collide with it. The total and time left come from the last run of the same selection. Problems are printed as they happen, with a one-line-per-problem recap at the end. Workers write output unbuffered, so a hanging test's output shows.
- Several outputs at once (`--format human --format json:out.json`).
- Shell completions for zsh, fish and bash, generated from the option definitions.
- Interactive watch mode: keys to rerun all, failed only, filter by path or name.
- Subcommands: `init`, `history`, `doctor`, `which` (the test file for a source file, from `exe/qc`), then `bisect`, `flaky` and `profile`.
- Debugging: a debugger or `binding.irb` in a test switches that test to serial with the TTY attached.
- The seed and worker sequences are always printed or recorded, so every run is reproducible.

## Compatibility (deferred)

Deferred: Quickdraw's own syntax and runner come first. When this resumes, the design is a small framework adapter interface in core (which files an adapter owns, preparing the loader, listing a file's tests, running one test), with Quickdraw's own syntax as the first adapter, and separate `quickdraw-minitest` and `quickdraw-rspec` gems hosting the real frameworks, so teams with large existing suites can adopt Quickdraw as their runner without rewriting tests.

- Run the real frameworks, with Quickdraw scheduling and reporting:
  - **Minitest:** run each `Minitest::Runnable` method the way Minitest does, suppress `autorun`, and honour plugins and Rails' `parallelize_*` hooks.
  - **RSpec:** schedule whole top-level groups via `group.run(reporter)` so `before(:context)` and `around` behave natively.
- Use the framework's native seed and filters. Record assignment and order for replay.
- An optional Prism-based rewriter to migrate RSpec or Minitest to Quickdraw syntax.

## Rails

Rails suites are the biggest and slowest Ruby suites, so this is where Quickdraw has to be best.

- **Detection:** a `config/environment.rb` and `rails` in the bundle switch on Rails support. `quickdraw init` writes the config.
- **Booting:** the loader boots the app once in the test environment, with eager loading in CI. Workers fork from that and share it through copy-on-write. Whether to eager load locally is decided by measuring, as noted under Speed.
- **A database per worker:**
  - the loader disconnects Active Record before forking (`before_forking`);
  - each worker connects to its own database, named with a suffix from `QUICKDRAW_WORKER` (`app_test-3`);
  - this works for every database in `database.yml`, including multiple databases and SQLite files.
- **Creating and keeping databases:**
  - databases are created on first use by cloning the schema;
  - they're kept between runs and only rebuilt when `schema.rb`/`structure.sql` or migrations change, tracked by checksum in run history;
  - the number of databases follows the worker count, and extras are left for reuse.
- **Rails' own parallel testing:** Rails' process-based `parallelize` is replaced, since Quickdraw already forks. Its hooks (`parallelize_setup`, `parallelize_teardown`, `parallelize_before_fork`) still run at the matching points, so apps that use them keep working. Threaded `parallelize` is left alone.
- **Isolation between tests:** transactional tests and fixtures work as normal. Fixtures load once per worker database and are reused across runs while the fixture files are unchanged.
- **Other per-worker resources:**
  - Active Storage and cache directories (`tmp/storage-3`);
  - Redis database numbers or key prefixes;
  - Capybara and Puma ports;
  - Elasticsearch/OpenSearch index prefixes;
  - each through a documented hook built on `QUICKDRAW_WORKER`.
- **System tests:** a Puma server per worker on its own port, with Playwright browsers owned by the coordinator (see Browser testing).
- **Framework-aware reporting:**
  - SQL queries and time per test, from Active Support notifications, including likely N+1 queries;
  - factories built per test;
  - log level warnings when debug logging is slowing the suite.
- **Running existing suites:** both `rails test`-style Minitest suites and `rspec-rails` suites run through the real frameworks (see Compatibility), with `bin/rails test` file and line arguments accepted as-is.

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

- Built in, using the core `Coverage` module (lines, branches, methods). It starts in the loader before app code loads and is merged across workers and groups, so parallel runs never need a separate merge step.
- Per-test coverage, recorded on demand. It drives test impact analysis and answers "which tests cover this line?"
- **Humans:** a terminal summary of the least-covered files, an annotated source view of uncovered lines and branches, and an HTML report.
- **AI:** compact uncovered ranges per file (`app/models/user.rb: 42-47, 90`) with the code at those lines and the tests nearest to them. Ranked by recent changes, so an agent knows exactly what to test next.
- Diff coverage: only the lines changed against a git base, with an optional threshold that fails CI.
- Coverage of `eval`'d and generated code mapped back to source where possible.

## Suite profiling

Slow suites are rarely one slow test. Usually it's a small cost paid by every test: password hashing at full cost, a factory that builds a whole object graph, debug-level logging, a `before` hook that resets too much. Quickdraw should find these on its own.

- **Always on, core only:** each test event carries wall time, CPU time (`CLOCK_PROCESS_CPUTIME_ID`), GC time and allocation deltas (`GC.stat`), split into setup/hooks, body and teardown. Wall time far above CPU time means waiting (IO, sleep, network). A one-line summary flags when hooks or GC dominate.
- **Profile mode (`quickdraw profile`):** signal-based stack sampling in every worker, merged in the coordinator into one profile of the whole suite. A sampler thread using `Thread#backtrace_locations` doesn't work: CPU-bound code holds the GVL, so it got 7 samples in 0.9s. Sampling needs either a profiler gem (only in profile mode) or a small Quickdraw C extension.
- **Shared-cost report:** finds frames that appear in most tests and ranks them by total suite time, e.g. "`create(:user)` → `BCrypt::Password.create`: in 92% of tests, 31ms each, 4m14s total, from spec/support/auth.rb:12". It estimates the saving if that cost were removed.
- **Framework-aware counters, when the framework is present:** SQL queries and time per test (ActiveSupport notifications), factories built per test, real outbound HTTP, `sleep` calls.
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

- **Property-based testing:** generators for core types and composable custom ones, shrinking to a minimal counterexample, and failing cases saved and replayed first on the next run. Properties run as ordinary tests, so they get parallelism and reporting for free.
- **Fuzzing:** coverage-guided input generation, using the `Coverage` module as the feedback signal, with a saved corpus of interesting inputs. Runs as a long-lived mode across all cores.
- **Mutation testing:** Prism-based mutators applied to the code under test. Uses the per-test coverage map to run only the tests that cover each mutation, fork-isolated per mutant, with surviving mutants reported as "this line isn't really tested". Incremental against a git base so it's practical in CI.

## Phases

1. Quick fixes: the CI `-t` flag, `--max`/`--efficiency` discarding their result, unprinted seed, the prism/refract break, the undefined `message` in `Runner#work`, dead autoloads.
2. Coordinator/loader split: core-only runtime, batched streaming events, crash recovery, SQLite run history (done). Still to do: hang timeouts.
3. Reporters (human, agent, JSON, GitHub Actions, JUnit) and selection (done). Still to do: an HTML report.
4. Groups (`setup:`, `gemfile:`).
5. Quickdraw's own syntax and failure output: `describe` blocks, skipped and pending tests, structured diffs, the failing source line (done). Still to do: a fuller assertion set. (Running Minitest and RSpec suites is deferred; see Compatibility.)
6. Flaky detection, order bisection, leak detection.
7. Coverage, impact analysis, interactive watch mode, sharding.
8. Suite profiling: always-on timings and GC/CPU counters per test phase, then profile mode with the shared-cost report.
9. Browser testing.
10. Property-based testing, then mutation testing (which builds on per-test coverage), then fuzzing.
