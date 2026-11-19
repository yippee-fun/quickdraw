# Quickdraw

<img src="quickdraw.png" alt="Quickdraw" width="128">

> [!WARNING]
> Quickdraw is currently in development. You should almost definitely not use it in a project until `1.0` is released.

Quickdraw is a fast test framework for Ruby, built to use every core.

- Tests run in parallel worker processes, and the number of workers tunes itself from previous runs.
- It never loads gems or standard libraries into the processes that run your tests, so a test can't pass because Quickdraw required something your code forgot to.
- Failures show as they happen, with diffs, the failing line and a command to rerun them. The output adapts to people, CI and AI coding agents.
- It finds flaky tests, works out which earlier test a failure depends on, measures coverage, and profiles where test time goes.

It supports Ruby 3.3 and later.

## Writing tests

Test files end in `.test.rb`. There's no helper to require: `config/quickdraw.rb` is loaded for you, if there is one.

```ruby
class CalculatorTest < Quickdraw::Test
  def setup
    @calculator = Calculator.new
  end

  test "adds" do
    assert_equal @calculator.add(1, 2), 3
  end

  describe "#divide" do
    test "divides" do
      assert_equal @calculator.divide(6, 2), 3
    end

    test "refuses to divide by zero" do
      assert_raises(ZeroDivisionError) { @calculator.divide(1, 0) }
    end
  end

  test "rounds money" # pending, until it has a block
end
```

- **Assertions:** `assert`, `refute`, `assert_equal`, `assert_includes`, `assert_match` (uses `===`, so regexes, ranges and classes work), `assert_in_delta`, `assert_operator`, `assert_raises`, `assert_same`, `assert_equivalent_html` and `assert_equivalent_ruby`, most with a `refute_` form. `match { value => pattern }` asserts a pattern match. Failure messages are only built when a test fails, so detailed ones cost nothing.
- **Diffs:** `assert_equal` diffs strings line by line, and hashes, arrays, sets, `Data`, structs and plain objects one element per line.
- **Groups of tests:** `describe` blocks nest, and their names join the test's name (`CalculatorTest › #divide › divides`). Each block is a subclass, so `setup` and helper methods work with `super`.
- **Skipping:** `skip "needs a network"` stops a test and reports it as skipped. A `test` without a block is pending.
- **Cleanup:** `defer { … }` runs after the test, even if it fails, in reverse order. `tmpdir` gives a fresh directory that's removed afterwards.
- **Timeouts:** tests time out after 300 seconds, or set one per test with `test "…", timeout: 5 do`.
- **Scope:** methods and constants defined at the top of a test file are only visible to that file's tests.

## Properties

`check` runs a block with values from generators, 100 times by default, to test something that should hold for any input:

```ruby
class SortingTest < Quickdraw::Test
  test "sorting is idempotent" do
    check(array(integer)) { |list| assert_equal list.sort.sort, list.sort }
  end

  test "round trips through JSON" do
    check(hash_of(string, nilable(integer)), cases: 500) do |hash|
      assert_equal JSON.parse(JSON.generate(hash)), hash
    end
  end
end
```

When a case fails, Quickdraw shrinks it to the simplest case it can find that fails in the same place, and reports it with the original and how many cases ran. The case is saved in `.quickdraw/properties/` and tried first next time, until it passes. Cases come from the run's seed, so `--seed N` repeats them.

- **Generators:** `integer(-10..10)`, `float(0.0..1.0)`, `boolean`, `string` (any Unicode, or `string("a".."z", length: 1..8)`, or `string(:ascii)`), `symbol`, `array(integer, length: 0..5)`, `hash_of(symbol, integer)`, `fixed_hash(name: string, age: integer(0..))`, `tuple(integer, string)`, `one_of(:red, :green, integer)`, `constant(value)` and `nilable(string)`. Ranges can be open-ended.
- **Your own:** `map`, `filter` and `flat_map` build generators from others, and `generator { |choices| User.new(name: choices.draw(string)) }` draws from several. They shrink as well as the built-in ones. Outside a test, call generators on `Quickdraw::Generators`.
- **How many:** `cases: 1000`, or `seconds: 2` to stop sooner if time runs out. A property counts as one assertion.

## Running tests

```sh
qt                         # every **/*.test.rb file
qt test/models             # a directory
qt test/user.test.rb:12    # the test at line 12
qt -n /admin/i -x slow     # tests whose names match /admin/i, but not "slow"
qt --failed                # what failed last time
qt --changed               # tests affected by uncommitted changes
qt --watch                 # run again when files change
```

`quickdraw` and `qt` are the same command. `qt --help` lists every option.

- **Workers:** Quickdraw chooses the number of workers from previous runs, exploring until it finds the fastest. Pass `-p N` to choose, `--max` for every core, or `--efficiency` for an Apple silicon Mac's efficiency cores.
- **Order:** tests run in a random order. The seed is printed after each run, and `--seed N` repeats it.
- **Stopping:** `--fail-fast` stops starting tests after the first problem. Ctrl-C stops the run, lets running tests clean up, and reports what finished.
- **Watch mode:** a changed test file reruns on its own, and a changed source file reruns its tests. Keys rerun everything, run only failures, or filter by path or name.

## Output

The output suits whoever is running the tests: a live progress bar on a terminal, and compact, complete problem reports for AI coding agents, which are detected automatically. `--format` chooses one: `human`, `agent`, `json` or `junit`. Repeat it to write more than one, with all but one going to a file:

```sh
qt --format human --format junit:reports/junit.xml
```

Under GitHub Actions, failures are annotated and a summary is written for the job.

What a test prints, to stdout or stderr, from Ruby, a subprocess or a C extension writing to the file descriptor, is shown with its failure rather than as it's printed, so output from parallel tests can't interleave. Passing tests' output isn't shown. A test that crashes or hangs its worker still has its output shown. What config and test files print while loading shows as usual.

`--no-capture` shows output as it's printed instead. For a debugger such as `binding.irb`, which needs the terminal, run the one test with it: `qt --no-capture -p 1 test/user.test.rb:12`.

## Leaks

After each test, Quickdraw checks for state it left behind, which can make later tests fail depending on the order they run in:

- threads it started (in your project, not in a gem) that are still running;
- child processes it started and didn't wait for (unless config started some too, which can't be told apart);
- changes to `ENV` it didn't undo. Only the names are reported, since values can be secrets.

Leaks are listed as warnings after the run. `--leaks fail` makes them errors, and `--leaks off` turns the checks off. They cost about a microsecond per test.

## History, flaky tests and order bugs

Quickdraw records each run in `.quickdraw/`, which belongs in `.gitignore`. That's how it orders slow files first, tunes the worker count, and knows what failed. `--no-history` turns it off.

- A test that fails is retried once in a fresh worker, one that has loaded no other test files. If it passes there, it's reported as flaky: it failed because of a test that ran before it, or it's flaky by nature. Flaky tests still fail the run, unless you pass `--allow-flaky`. `--retry 3` retries up to three times, and `--retry 0` turns retries off. Retries stop after 10 failing tests, since that many usually means broken code.
- `qt history` lists recent runs, the slowest tests, and flaky tests: those that both passed and failed on the same code.
- `qt flaky --runs 20` runs the tests 20 times in different orders and lists the ones that sometimes fail.
- `qt bisect test/user.test.rb:12` takes the last run where that test failed and replays the tests that ran before it in the same worker, in halves, to find which one it depends on.

## Coverage

`qt --coverage` measures which lines, branches and methods your tests run, across every worker. It shows totals, changed lines that no test ran, the least covered files and files no test loaded. It also writes these to `.quickdraw/coverage/`:

- `index.html`, a report with a page for each file;
- `lcov.info`, for editors and coverage services;
- `coverage.json`.

A coverage run also records which source files each test file runs. `qt --changed` uses that to run only the tests affected by your uncommitted changes. Until there's been a coverage run, it runs each changed file's tests by name.

## Profiling

`qt --profile` samples tests as they run and lists the methods that take the most test time, and how many tests they run in. A method that takes a large share across most tests is a cost they share, such as a slow factory or setup hook, which you can fix once. `qt -t` lists the slowest tests and files.

## Configuration

`config/quickdraw.rb` is loaded once before tests run, and shared by every worker.

```ruby
Quickdraw.configure do |config|
  config.timeout = 60

  # Once, before workers start: boot your app here.
  config.before_forking { require_relative "../config/environment" }

  # In each worker. QUICKDRAW_WORKER is its number, for a database per worker.
  config.after_forking { connect_to_database("test_#{ENV['QUICKDRAW_WORKER']}") }

  # Tests that need a gem the rest shouldn't see run in processes of their own.
  config.group :browser, "test/browser/**/*.test.rb" do
    require "playwright"
  end

  # Or with a bundle of their own, such as another version of Rails.
  config.group :rails7, "test/rails7/**/*.test.rb", gemfile: "gemfiles/rails7.gemfile"

  # Around every test, including its setup and teardown.
  config.around_test { |test, run| Timecop.freeze { run.call } }
end
```

`Quickdraw::Counters.add("emails", seconds)` counts something a test does. The summary shows counts per test, and JSON output has each test's.

## Rails

```ruby
Quickdraw.configure(&:rails)
```

- The app boots once, before workers start, and workers share it.
- Each worker gets its own databases, named as Rails' parallel tests name them (`myapp_test_2`, `test.sqlite3_2`). They're created and loaded from the schema when a worker starts, or emptied if the schema hasn't changed.
- Each test runs in a transaction on every database, rolled back afterwards. Threads the test starts share it.
- The summary shows SQL queries and factory_bot factories per test, and their time.

Fixtures and Rails' test helpers aren't supported yet.

## Commands

- `qt init` sets a project up, with config and an example test.
- `qt doctor` checks that the machine and project are ready, and how long config takes to boot.
- `qt counterpart lib/user.rb` prints a source file's test, or a test's source file.
- `qt completions zsh` prints shell completions, for bash, zsh or fish.
