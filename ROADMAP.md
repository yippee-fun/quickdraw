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

## Speed

- Batched scheduling (done). On 20k trivial tests the old runner took 0.55s; the new one takes 0.27s.
- Slowest files first, using recorded timings.
- Shared-memory queue (C extension): only worth it if profiling shows IPC is a meaningful share of runtime after batching.
- Eager loading the app in the loader (shared through copy-on-write) versus lazy autoloading in each worker (parallel but duplicated): measure both on real Rails apps before picking a default.
- Load once, fork many: `Process.warmup` before fork, YJIT in workers, GC tuned for short-lived workers.
- Warm loaders in watch mode: fork a fresh worker set per change instead of rebooting.
- Test impact analysis: per-test coverage map, so `--changed` and watch mode run only affected tests.
- CI sharding balanced by timings (`--shard 2/8`), and an optional dynamic cross-machine queue.
- Load profiling: time spent in helpers and each test file's `require`s.

## Reliability

- **Crash isolation:** a dead worker reports the in-flight test (segfault, OOM, `exit!`) and is replaced.
- **Hang detection:** per-test timeouts that dump every thread's backtrace before killing the worker.
- **Flaky detection:** retry failures in a fresh worker; a test that passes on retry is reported as flaky, not green. Flake scores tracked across runs.
- **Order bisection:** we record each worker's exact test sequence, so a failure that only happens in a suite run can be replayed serially and delta-debugged down to the minimal polluting test(s). `quickdraw bisect <test>`.
- **Leak detection:** snapshot global state around tests — globals, new constants, `ENV`, `Time` stubs, live threads, open files, temp files — and blame the test that leaked.
- **Stress modes:** `--repeat N`, run each test many times across random workers, randomised `TZ` and locale.
- Tests with zero assertions are flagged.

## Reports

- **Humans:** failures shown as they happen, relative clickable `path:line` (OSC 8 links), source excerpt of the failing line, structured diffs for strings, hashes, arrays and objects, filtered backtraces, slowest tests and files, a rerun command for each failure, and a comparison with the last run (newly failing, fixed, flaky).
- **Assertion introspection:** on failure, rerun the test with instrumentation to show the value of each sub-expression in the failing assertion, at zero cost to passing tests.
- **CI:** no ANSI when not a TTY or when `NO_COLOR` is set, GitHub Actions annotations and job summary, JUnit XML, an HTML report.
- **AI agents:** detected automatically. Summary first, one compact block per failure (test, assertion, trimmed backtrace, relevant source), one rerun command, large values truncated with a pointer to the full detail. `--format json` emits the raw event stream. Possibly a `quickdraw mcp` server.
- **Worker timeline:** utilisation per worker, to spot long poles and idle time.

## CLI

- `quickdraw` with no arguments discovers Quickdraw, Minitest and RSpec tests.
- Selection: `path:line`, `--name`, tags, `--failed` (last run's failures), `--changed` (git diff + impact map), `--fail-fast`.
- Interactive watch mode: keys to rerun all, failed only, filter by path or name.
- Subcommands: `bisect`, `flaky`, `profile`, `doctor`, `init`.
- Debugging: a debugger or `binding.irb` in a test switches that test to serial with the TTY attached.
- The seed and worker sequences are always printed or recorded, so every run is reproducible.

## Compatibility

- Run the real frameworks, with Quickdraw scheduling and reporting:
  - **Minitest:** run each `Minitest::Runnable` method the way Minitest does, suppress `autorun`, and honour plugins and Rails' `parallelize_*` hooks.
  - **RSpec:** schedule whole top-level groups via `group.run(reporter)` so `before(:context)` and `around` behave natively.
- Rails: a database per worker, a Capybara port per worker, fixtures.
- Use the framework's native seed and filters. Record assignment and order for replay.
- An optional Prism-based rewriter to migrate RSpec or Minitest to Quickdraw syntax.

## Native syntax

- A rich assertion set, plus pattern matching via `===`.
- Snapshot testing with an update mode.
- Table-driven tests.
- Allocation and performance assertions.
- Stubs and mocks that are always reset.

## Coverage

- Built in, using the core `Coverage` module (lines, branches, methods). It starts in the loader before app code loads and is merged across workers and groups, so parallel runs never need a separate merge step.
- Per-test coverage, recorded on demand. It drives test impact analysis and answers "which tests cover this line?"
- **Humans:** a terminal summary of the least-covered files, an annotated source view of uncovered lines and branches, and an HTML report.
- **AI:** compact uncovered ranges per file (`app/models/user.rb: 42-47, 90`) with the code at those lines and the tests nearest to them. Ranked by recent changes, so an agent knows exactly what to test next.
- Diff coverage: only the lines changed against a git base, with an optional threshold that fails CI.
- Coverage of `eval`'d and generated code mapped back to source where possible.

## Fuzzing, properties and mutation testing

- **Property-based testing:** generators for core types and composable custom ones, shrinking to a minimal counterexample, and failing cases saved and replayed first on the next run. Properties run as ordinary tests, so they get parallelism and reporting for free.
- **Fuzzing:** coverage-guided input generation, using the `Coverage` module as the feedback signal, with a saved corpus of interesting inputs. Runs as a long-lived mode across all cores.
- **Mutation testing:** Prism-based mutators applied to the code under test. Uses the per-test coverage map to run only the tests that cover each mutation, fork-isolated per mutant, with surviving mutants reported as "this line isn't really tested". Incremental against a git base so it's practical in CI.

## Phases

1. Quick fixes: the CI `-t` flag, `--max`/`--efficiency` discarding their result, unprinted seed, the prism/refract break, the undefined `message` in `Runner#work`, dead autoloads.
2. Coordinator/loader split: core-only runtime, batched streaming events, crash and hang recovery, run history.
3. Reporters (human, CI, AI, JSON) and selection.
4. Groups (`setup:`, `gemfile:`).
5. Real Minitest, then real RSpec, verified against real Rails apps.
6. Flaky detection, order bisection, leak detection.
7. Coverage, impact analysis, interactive watch mode, sharding.
8. Property-based testing, then mutation testing (which builds on per-test coverage), then fuzzing.
