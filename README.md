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

- **Assertions:** `assert`, `refute`, `assert_equal`, `assert_includes`, `assert_match` (uses `===`, so regexes, ranges and classes work), `assert_in_delta`, `assert_operator`, `assert_raises`, `assert_same`, `assert_nil`, `assert_equivalent_html` and `assert_equivalent_ruby`, most with a `refute_` form. `assert_eventually(within: 1) { ready? }` waits for what another thread or process does, rather than sleeping long enough. `outcome { … }` is what a block returned or raised (its error's class and message, with object addresses hidden), so two ways of doing something can be compared, errors included: `assert_equal outcome { cached }, outcome { uncached }`, or `assert_equal outcome { parse("x") }, raised(ArgumentError, "bad input")`. `match { value => pattern }` asserts a pattern match. Failure messages are only built when a test fails, so detailed ones cost nothing.
- **Diffs:** `assert_equal` diffs strings line by line, and hashes, arrays, sets, `Data`, structs and plain objects one element per line.
- **Groups of tests:** `describe` blocks nest, and their names join the test's name (`CalculatorTest › #divide › divides`). Each block is a subclass, so `setup` and helper methods work with `super`.
- **Skipping:** `skip "needs a network"` stops a test and reports it as skipped. A `test` without a block is pending.
- **Cleanup:** `defer { … }` runs after the test, even if it fails, in reverse order. `tmpdir` gives a fresh directory that's removed afterwards.
- **Stubs and spies:** `stub(object, :name) { |*args, **kwargs, &block| … }`, or `stub(object, :name, returns: value)`, replaces a method on that one object (a class or module, for its class methods), keeping its visibility. The method must exist. `spy(object, :name)` lets a method run and records each call: `calls = spy(mailer, :deliver)` gives `calls.called?`, `calls.count` and `calls.calls`, each with its `args`, `kwargs`, `block`, `result` or `error`, and `thread`. A spy on a stub records the stub's calls. `stub_const("Billing::RATE", 2)` sets a constant, defining it if it's missing, and `stub_env("API_KEY" => "test", "DEBUG" => nil)` sets ENV, deleting the variables given `nil`. All are undone after the test, however it ends, in reverse order and before the leak checks. They change the object itself, so every thread in the worker sees them while the test runs, including those of an app a browser test drives.
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

- **Generators:** `integer(-10..10)`, `float(0.0..1.0)`, `boolean`, `string` (any Unicode, or `string("a".."z", length: 1..8)`, or `string(:ascii)`, with `dictionary: ["true", "null"]` to mix in words), `bytes` (binary, with a `dictionary:` too), `symbol`, `array(integer, length: 0..5)`, `hash_of(symbol, integer)`, `fixed_hash(name: string, age: integer(0..))`, `tuple(integer, string)`, `one_of(:red, :green, integer)`, `constant(value)` and `nilable(string)`. Ranges can be open-ended.
- **Your own:** `map`, `filter` and `flat_map` build generators from others, and `generator { |choices| User.new(name: choices.draw(string)) }` draws from several. They shrink as well as the built-in ones. Outside a test, call generators on `Quickdraw::Generators`.
- **How many:** `cases: 1000`, or `seconds: 2` to stop sooner if time runs out. A property counts as one assertion.

## Fuzzing

A property tries 100 cases. Fuzzing tries hundreds of thousands, and learns as it goes: a case that runs code no case ran before is kept, and new cases are made by changing kept ones, so it gets deeper into your code over time. `fuzz` defines a test that's an ordinary property when tests run:

```ruby
class ParserTest < Quickdraw::Test
  fuzz "parses anything", bytes(dictionary: ["{", "}", "[", "]", ":", ",", "true", "null"]) do |input|
    Parser.parse(input)
  rescue Parser::Error
    # Invalid input is fine. Any other error is a bug.
  end
end
```

`qt fuzz` fuzzes it, on every worker at once:

```sh
qt fuzz                          # the tests fuzz defines, in every test file that mentions fuzz
qt fuzz test/parser.test.rb      # in a file, or a directory
qt fuzz test/sorting.test.rb:12  # any test that checks a property, by line
qt fuzz --seconds 300            # for longer (the default is 30 seconds a test)
qt fuzz --forget test/parser.test.rb  # forget what fuzzing found there, after changing a property
```

```
ERRORED parses anything  ParserTest · test/parser.test.rb:3

    NoMethodError: undefined method 'fetch' for nil
    lib/parser.rb:41:in 'Parser.object'

  Input (found after 10,715 cases, shrunk 9 times)

    "{null:true"

ParserTest › parses anything  test/parser.test.rb:3
  861,402 cases in 30.0s (28,713/s) · 92 edges · 96 in the corpus · 6 methods traced
  Edges: 75 by 0.2s, 92 by 0.8s.
```

- **Finds:** failed assertions and errors, as properties do; cases that crash the process (a segfault, `exit!`), or raise past the property (`exit`); and cases that hang, running longer than `--timeout` (a second, by default). Each is shrunk as a property's are, and saved with the property's failing cases, so `qt` replays it first until it passes. Whatever one is found, fuzzing carries on looking for others.
- **Guided by:** which edges between lines of your project's methods a case runs (not gems', tests' or Quickdraw's), and roughly how many times (1, 2–3, 4–7…), as AFL does. A case that reaches a new edge, or a new count, joins the corpus, kept in `.quickdraw/fuzz/`, which later runs start from, and every worker shares.
- **New cases:** made by changing a kept case's choices rather than its value, so they keep its shape: a choice replaced or nudged, a value (an array's item, a string's character) deleted, duplicated or swapped for one from another case, or the end made afresh. A tenth are fresh. A `dictionary:` on `string` or `bytes` mixes in words a format uses, which random characters would rarely spell.
- **Which property:** a test's first `check`. Its others run as usual.
- **Results:** `--format human`, `agent` or `json`, with what's found, cases a second, edges reached, and when it reached them: if the last came long before the end, more time is unlikely to find more. It exits with 1 if it finds anything. `--seed N` makes the same cases on one worker, as long as nothing else changes the corpus.
- **Speed:** 29,000–37,000 cases a second on one worker on a small JSON-like parser, and 70,000–113,000 on four. Tracing the edges costs about 9µs a case there, and saving each case before it runs, so a crash can be traced to it, about 4µs.

## Running tests

```sh
qt                         # every **/*.test.rb file
qt test/models             # a directory
qt test/user.test.rb:12    # the test at line 12
qt -n /admin/i -x slow     # tests whose names match /admin/i, but not "slow"
qt --failed                # what failed last time
qt --changed               # tests affected by uncommitted changes
qt --changed --base main   # or by everything since this branched from main
qt --watch                 # run again when files change
```

`quickdraw` and `qt` are the same command. `qt --help` lists every option.

- **Workers:** Quickdraw chooses the number of workers from previous runs, exploring until it finds the fastest. Pass `-p N` to choose, `--max` for every core, or `--efficiency` for an Apple silicon Mac's efficiency cores. `--elastic` adds workers during a run while its tests mostly wait (on IO, the network or `sleep`) and the CPU is idle, which speeds up the first run of tests like that, before there's history to go on. It never adds workers to tests that keep the CPU busy, or when memory is short.
- **Order:** tests run in a random order. The seed is printed after each run, and `--seed N` repeats it.
- **Stopping:** `--fail-fast` stops starting tests after the first problem. Ctrl-C stops the run, lets running tests clean up, and reports what finished.
- **Watch mode:** a changed test file reruns on its own, and a changed source file reruns its tests. Keys rerun everything, run only failures, or filter by path or name. Config stays booted between runs, so only the first waits for it (a Rails app's rerun takes about 100ms rather than 600ms). It boots again when `config/`, the Gemfile or a file it loaded changes, or a file is added to or deleted from an autoloaded directory. File events come from FSEvents on macOS and inotify on Linux, without a gem. Elsewhere it polls every 0.5s, as it does with `QUICKDRAW_POLL=1`, for file systems that don't send events, such as some Docker volumes.

## Output

The output suits whoever is running the tests. For people, each test file gets a line as it finishes, with its count, time and how many problems it had. Once every file has finished, each problem follows in full. In a terminal, a status line with a spinner sits under the file lines while config boots and tests run, with how many files and tests have finished, and it's gone at the end, so the output reads the same in a terminal as in a CI log. The summary at the end leads with PASSED or FAILED and the counts, lists each problem on a line, says how to rerun them, and notes skips and anything slow in a line each. `--timings` adds the slowest tests and files, where test time goes, and how busy the workers were.

```
✓ test/calculator.test.rb   3 tests · 220.0μs · 1 pending
✗ test/models/user.test.rb  3 tests · 325.0μs · 1 failed · 1 skipped

FAIL greets  UserTest · test/models/user.test.rb:3
…

FAILED  6 tests · 4 assertions · 1 failed · 1 skipped · 1 pending · 0.04s

  ✗ test/models/user.test.rb:3 UserTest › greets

  Rerun failures  qt --failed
  Same order      qt --seed 56282

  Skipped  Mail server isn't running (1)
  Pending  test/calculator.test.rb:4 CalculatorTest › divides
```

AI coding agents, which are detected automatically, get a short report instead, since they pay for every line they read: each problem on one line with the gist of why, and problems with the same cause grouped, so a thousand failures with one cause take one line. The details are a command away:

```
1,203 × ERROR NoMethodError: undefined method 'name' for nil, such as test/user.test.rb:40 UserTest › greets
FAILED test/cart.test.rb:12 CartTest › totals: Expected 30 · Actual 3

FAILED: 5,030 tests, 3,816 passed, 9 failed, 1,205 errored in 41.20s (seed 1234)
Details: qt last test/user.test.rb:40 (or a whole file). All problems: qt last --list
Rerun the failures with: qt --failed
```

Every run is kept, so after you see a failure you can tell an agent the tests failed, and it can read what happened, however the run was shown:

```sh
qt last                        # the result, a line per problem
qt last test/cart.test.rb:12   # a problem in full: the failing line, message, backtrace and output
qt last --list                 # every problem, a line each
```

Runs with `--no-history` aren't kept, so their agent report shows the first problem in full instead. `--format` chooses a format: `human`, `agent`, `json` or `junit`. Repeat it to write more than one, with all but one going to a file:

```sh
qt --format human --format junit:reports/junit.xml
```

Under GitHub Actions, failures are annotated and a summary is written for the job.

What a test prints, to stdout or stderr, from Ruby, a subprocess or a C extension writing to the file descriptor, is shown with its failure rather than as it's printed, so output from parallel tests can't interleave. Passing tests' output isn't shown. A test that crashes or hangs its worker still has its output shown. What config and test files print while loading shows as usual, above the live block. `--no-capture` turns off both capturing and the live block.

`--no-capture` shows output as it's printed instead.

Debuggers work in any run. When a test reaches `binding.irb`, `debugger`, `binding.break` or `binding.pry`, Quickdraw pauses its display and gives that worker the terminal, one debugger at a time, while other workers keep going. The test's timeout is paused, and Ctrl-C goes to the debugger.

## Leaks

After each test, Quickdraw checks for state it left behind, which can make later tests fail depending on the order they run in:

- threads it started (in your project, not in a gem) that are still running, and Ractors;
- a thread it started that ended with an exception nobody saw, since it wasn't joined;
- a failed assertion from a thread it started, made after it finished, which is reported with the test running then, naming the one that started the thread;
- a fiber scheduler it set and didn't unset, in which later tests' fibers would run;
- child processes it started and didn't wait for (unless config started some too, which can't be told apart);
- changes to `ENV` it didn't undo. Only the names are reported, since values can be secrets.

Leaks are listed as warnings after the run. `--leaks fail` makes them errors, and `--leaks off` turns the checks off. They cost about a microsecond per test.

## Threads, fibers and Ractors

Assertions made in threads, fibers, enumerators and fiber schedulers (such as Async's) count towards the test that made them, and their failures fail it, with the line they were made on. A property's cases only take assertions from their own fibers and the threads they start, so another thread can't fail a case and make up a counterexample. Counters (see Rails) from threads a test started count towards it, even if they run on after it.

A Ractor can't use the test's assertions, since the test isn't shareable, so return what it computes and assert on that. Quickdraw's constants are shareable, apart from `Quickdraw::Config`. Ruby's coverage only sees the main Ractor, so code that runs only in a Ractor counts as not run, both for `--coverage` and for choosing which tests run a mutant. What a Ractor writes to `$stdout` isn't captured, as it's buffered apart from the test's; `$stderr` is.

## History, flaky tests and order bugs

Quickdraw records each run in `.quickdraw/`, which belongs in `.gitignore`. That's how it orders slow files first, tunes the worker count, and knows what failed. `--no-history` turns it off.

- A test that fails is retried, first in the worker it failed in, then in a fresh worker, one that has loaded no other test files. If a retry passes, it's reported as flaky, and where it passed says what kind:
  - passing again in the same worker means it fails some of the time on its own, from timing, randomness or the network;
  - failing again there but passing in a fresh worker means it likely depends on a test that ran before it, which `qt bisect` can find.

  Flaky tests still fail the run, unless you pass `--allow-flaky`. `--retry 3` retries up to three times in fresh workers, and `--retry 0` turns retries off. Retries stop after 10 failing tests, since that many usually means broken code.
- **Reporting flakes**, from CI, say. `config.on_flaky` is called with each flaky test once the tests have finished, in the process that booted your config, so your app and its error reporting are loaded:

  ```ruby
  config.on_flaky do |flake|
    Sentry.capture_message("Flaky test: #{flake.name}", fingerprint: ["flaky-test", flake.key], extra: flake.to_h)
  end
  ```

  A flake has a `key` that stays the same from run to run, for grouping; its `path`, `line` and `name`; its `kind` (`:nondeterministic`, `:order_dependent`, or `:unknown` if its worker crashed); each of its `attempts`, with where it ran, its status, duration, failures and errors; the run's `seed` and a `rerun` command; and the `commit`, `branch` and CI build's `ci_url` (on GitHub Actions, Buildkite, GitLab or CircleCI). `--flakes FILE` writes the same as JSON, for a pipeline that isn't in Ruby.
- **Quarantine:** with `--quarantine`, a test that was flaky in the last 50 runs still runs, and its failures are still shown and recorded, but it doesn't fail the run, so a known flaky test doesn't block a merge while someone fixes it. It's quarantined until 50 runs have gone by without it being flaky. In JUnit reports it's skipped, and on GitHub Actions it's a warning. In CI, quarantine needs the history from earlier runs, so cache `.quickdraw/` (see On pull requests).
- `qt history` lists recent runs, the slowest tests, and flaky tests: those that both passed and failed on the same code.
- `qt flaky --runs 20` runs the tests 20 times in different orders and lists the ones that sometimes fail.
- `qt bisect test/user.test.rb:12` takes the last run where that test failed and replays the tests that ran before it in the same worker, in halves, to find which one it depends on.

## Coverage

`qt --coverage` measures which lines, branches and methods your tests run, across every worker. It shows totals, changed lines that no test ran, the least covered files and files no test loaded. It also writes these to `.quickdraw/coverage/`:

- `index.html`, a report with a page for each file;
- `lcov.info`, for editors and coverage services;
- `coverage.json`.

A coverage run also records which source files each test file runs. `qt --changed` uses that to run only the tests affected by your uncommitted changes. Until there's been a coverage run, it runs each changed file's tests by name.

## Mutation testing

Coverage says which code your tests run, not whether they check it. `qt mutate` changes your code in small ways, one at a time, and runs the tests that run each change. If none fails, the change survives, and the tests don't notice that line being wrong:

```sh
qt mutate                      # the lines changed since the last commit
qt mutate --base origin/main   # the lines changed since this branched from main
qt mutate lib/cart.rb          # a file, or a directory
qt mutate lib/cart.rb:12-20    # some of its lines
```

```
✗ lib/cart.rb:14  > → >= in Cart#discount
    - if total > 100
    + if total >= 100
    2 tests ran it and passed: CartTest › discounts big orders, CartTest › doesn't discount small orders

Mutation score 90% · 18 killed · 2 survived
20 mutants in 0.12s (167/s)
```

- **Changes:** only in methods, including those in `Data.define`, `Struct.new` (assigned to a constant) and `class_methods` blocks.
  - Conditions: negating one, or making it `true` or `false` (in `if`, `unless`, ternaries, loops and `in … if` guards); `a && b` to `a || b`, `a` or `b`; removing a `!`.
  - Operators: comparisons (`>` to `>=`, `==` to `!=`), arithmetic (`+` to `-`, `*` to `/`, `+=` to `-=`), `..` to `...`, and `||=` to `=`.
  - Literals: `true` to `false`, a number to one more or to 0, emptying a string, array or hash or dropping one of its elements or pairs, and a regexp to one that never matches.
  - Calls: methods such as `select` to `reject`, `first` to `last`, `map` to `each` or `is_a?` to `instance_of?`; dropping a call that changes its receiver (`name.strip` to `name`), a block, an argument the method doesn't need, or `&.`'s check for nil; `fetch(key)` to `[key]`; `super(a)` and `super` to `super()`, and `yield(a)` to `yield`.
  - Control flow: removing a statement, a `when` or `in` branch, a `return`, `next` or `break` value, or a modifier `rescue`; doing nothing in a `rescue` or `ensure`; and replacing a method's body with `nil`.
  - Not changes that can't make a difference, such as `x + 0` to `x - 0`, `map` to `each` where the value isn't used, or dropping `to_s` in interpolation, and not changes that could only raise, such as removing an argument the method requires, or a block `tap` needs.
- **Which tests:** the test files that run a file, from the last `qt --coverage` run, or else its counterpart by name. Those run once unchanged, tracing which lines of the changed methods each test runs, so each change runs only the tests that reach it, fastest first, and stops at the first failure. Tests that fail without changes don't count, and changes no test reaches aren't run, but are listed by line.
- **Safely:** your files never change. Config boots once, and each change is made by redefining its method in a process forked for it, which exits when its tests finish. A change that makes tests run three times as long as they did (plus half a second) is taken to loop forever, and counts as noticed.
- **Results:** `--format human`, `agent` or `json`. It exits with 1 if any change survives, or with `--threshold 80`, if fewer than 80% are noticed, and also if some tests or changes couldn't run. Tests' `rand` is seeded the same way every time (`--seed N` changes it), so results don't vary between runs. On GitHub Actions, each surviving change, and each test that fails `--unique-kills`, is also an error annotation on its line, so it shows in the pull request's diff.
- **Only what changed runs again:** a mutant's outcome is kept in `.quickdraw/mutants.json`, and reused while nothing it depends on has changed: its file, the test files that run it, the files those tests ran in the last `qt --coverage` run, `Gemfile.lock` and `config/quickdraw.rb`. So after you add a test for a survivor, only the mutants that test file runs are tried again. `--no-cache` runs every mutant.
- **Survivors** have ids that stay the same while their method's code does, since they don't include line numbers. For agents, each survivor is one line with its id, and `qt mutate --show ID` shows its change and the tests that ran it (`--show all` lists them all again).
- **Which tests do the work:** `--matrix` runs every test that reaches each change, rather than stopping at the first failure, and lists **blind** tests, which ran changed code and noticed none of the changes, so they run code without checking it, and **redundant** tests, which only noticed changes another test noticed too. Since each change only runs the tests that reached its line, a blind test really did run the changed code. Redundancy is judged one test at a time, so remove redundant tests one at a time. It takes longer, since every test runs, but doesn't change the score.
- **Equivalent changes:** some changes can't make a difference, such as `>` to `>=` where the two are never equal. Mark one with a comment on its line, naming the change as the output does and saying why, and it's left out of the score and listed as marked equivalent. A mark without a name covers every change on its line. Quickdraw warns about a mark with no reason, or one that matches no change.

  ```ruby
  return a if a > b # quickdraw:equivalent > → >= -- when they're equal, either is the larger
  ```

### On pull requests

Mutation testing a whole suite is slow, but a pull request only needs its own changes tested. On CI, `qt mutate` with `--base` mutates just the lines the pull request changes, and runs just the tests that run them, which the coverage map from a `qt --coverage` run on the main branch says.

`--unique-kills` also checks the tests the pull request adds or changes: each must be the only test to notice some change, so every test earns its place. To judge them, it also runs the changes they reach outside the pull request's lines, which don't count towards the score. A test that checks something that can't be changed this way, such as a log line or a rendered page, can opt out with `test("renders the receipt", mutation: false) { … }`.

```yaml
# .github/workflows/mutation.yml
on:
  push:
    branches: [main]
  pull_request:

jobs:
  mutate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # for the commit the pull request shares with main
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - uses: actions/cache@v4
        with:
          path: |
            .quickdraw/history.sqlite3
            .quickdraw/mutants.json
          key: quickdraw-${{ github.sha }}
          restore-keys: quickdraw-
      - if: github.event_name == 'push'
        run: bundle exec qt --coverage
      - if: github.event_name == 'pull_request'
        run: bundle exec qt mutate --base origin/${{ github.base_ref }} --unique-kills
```

On a pull request in GitHub Actions, `--base` defaults to the branch it merges into, so `qt mutate --unique-kills` alone does the same.

## Profiling

`qt --profile` samples tests as they run and lists the methods that take the most test time, and how many tests they run in. A method that takes a large share across most tests is a cost they share, such as a slow factory or setup hook, which you can fix once. `qt -t` lists the slowest tests and files.

## Timeline

`qt --timeline` shows where workers' time went, for when they're less busy than they could be:

```
Timeline .quickdraw/timeline.html
  0.21s booting · 0.37s running tests · 0.01s stopping
  8 workers: 78% running tests · 7% between tests · 4% loading files · 3% starting · 8% idle at the end
  For the last 0.12s, workers ran out of work while these ran:
     0.31s  test/compiler.test.rb:178 CompilerTest › compiles a large template
```

- **Booting** is config loading, before any worker starts. Watch mode pays it only when config changes.
- **Workers' time**, across every worker slot: running tests; between tests in a batch (sending results, checking for leaks, capturing output); loading test files; starting (forking, and your `after_forking` callbacks); waiting for work while others were busy; replacing workers (to move between groups, retry a failure or replace a crashed worker); and idle at the end.
- **At the end:** once the first worker ran out of work, the tests that kept the run going, longest first. One long test there sets how long the run takes, and splitting it lets workers share it.

`.quickdraw/timeline.html` charts each worker slot across the run. Hover over a part of it for the tests, file or phase it shows. Recording happens in the coordinator, at the cost of an array per test, and not at all without `--timeline`.

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

  # A group whose workers run something else beside them, such as a server,
  # can count each as more than one core, so fewer run at once. One whose
  # tests are slow can say how long a file takes before history says, so it
  # gets workers early, rather than finishing last.
  config.group :search, "test/search/**/*.test.rb", cores: 2, file_seconds: 3

  # Around every test, including its setup and teardown.
  config.around_test { |test, run| Timecop.freeze { run.call } }

  # Settings the command line has options for, which those override.
  config.leaks = :fail          # --leaks fail (:warn, :fail or :off)
  config.retries = 2            # --retry 2 (0 to 3; --retry can go higher)
  config.allow_flaky = true     # --allow-flaky
  config.quarantine = true      # --quarantine
  config.flakes = "tmp/flakes.json" # --flakes tmp/flakes.json
  config.capture = false        # --no-capture
  config.elastic = true         # --elastic
  config.processes = 4          # -p 4
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
- In watch mode, the app stays booted between runs. With `config.enable_reloading = true` in the test environment, app code that booting loaded (all of it, with eager loading) is reloaded when it changes, rather than booting again.

### Fixtures

```ruby
Quickdraw.configure { |config| config.rails(fixtures: :all) }
```

That gives every test the fixtures in `test/fixtures` (or `fixture_paths:`). A test class can ask for sets of its own instead:

```ruby
class UserTest < Quickdraw::Test
  fixtures :users, :posts

  test "has posts" do
    assert_equal users(:ada).posts, [posts(:hello)]
  end
end
```

- Each set loads once into each worker's databases, committed, and tests see it through their transactions, as with Rails' transactional fixtures. A test that commits loads the fixtures again.
- A later run keeps the sets whose files (with ERB rendered) are unchanged, rather than loading them again. Rows added or removed since, or the schema changing, load them again, but rows another process changed in place are kept. The times Rails fills in (`created_at`) move to when the worker started, as if they'd just loaded; sets with dates it filled in (`created_on`) load again the next day.
- A database keeps every set loaded into it, so, as in Rails, a test can see fixtures it didn't ask for.

### Test helpers

```ruby
class SignupTest < Quickdraw::Test
  include Quickdraw::Rails::TimeHelpers   # travel_to, travel, freeze_time
  include Quickdraw::Rails::JobHelpers    # assert_enqueued_with, perform_enqueued_jobs, …
  include Quickdraw::Rails::MailerHelpers # assert_emails, capture_emails, and the job helpers

  test "sends a welcome email" do
    travel_to Time.utc(2030)

    assert_difference(-> { User.count }) do
      assert_emails(1) { Signup.call(email: "ada@example.com") }
    end
  end
end
```

They're Rails' own, and their assertions count as the test's. Time travels back, jobs go back to their adapter and sent emails are cleared after each test, even one that fails. `JobHelpers` and `MailerHelpers` set up in `setup`, so a test's own `setup` must call `super`.

`assert_difference`, `assert_no_difference`, `assert_changes` and `assert_no_changes` work in any test, and take something to call, such as a lambda, rather than a string.

## Browser testing

Browser tests use [Playwright](https://playwright.dev) with Chromium, Firefox or WebKit. Each worker runs Playwright's JavaScript API in a Node process of its own, so you need Node, but no Playwright gem; Puma, which serves your app, needs to be in your bundle. `config.browser` runs the files matching its patterns in a group of their own, so other tests never start a browser. The block returns the app they test:

```ruby
Quickdraw.configure do |config|
  config.rails
  config.browser("test/system/**/*.test.rb") { Rails.application }
end
```

Browser tests run in a group of their own (see Configuration). Each worker's browser needs a core of its own, so a browser test's worker counts as two of the run's cores (`config.browser(…, cores: 1)` to count it as one), and since browser tests are usually the slowest, they get workers first, before history says how long they take, rather than holding up the end of the run.

To run every browser test in several browsers, give `browsers:` instead of `browser:`. Each browser gets a group of its own, `browser:chromium` and so on, so they run at the same time, sharing the run's cores:

```ruby
config.browser("test/system/**/*.test.rb", browsers: [:chromium, :firefox, :webkit]) { Rails.application }
```

Each test's name ends with the browser it ran in (`SignupTest › signs up [firefox]`), as do file lines, and JSON gives it as `variant`. Each browser's results are separate in history, so durations, flakiness, retries and quarantine are per browser, and `--failed` reruns a failure only in the browser it failed in. `qt test/system/signup.test.rb:4` runs that test in every browser; `--browser firefox` (repeatable) runs browser tests in just that one, as a failure's rerun command does; a browser config doesn't have runs nothing and fails. A failure's screenshot, HTML and console log go in `.quickdraw/browser/firefox/` and so on. `Quickdraw::Browser.browser_name` is the worker's browser.

`qt browser install` installs Playwright and config's browsers (or the ones you name: `qt browser install firefox webkit`), and `qt doctor` checks they're there. Tests never download anything.

```ruby
class SignupTest < Quickdraw::Test
  include Quickdraw::Browser

  test "signs up" do
    visit "/signup"
    page.get_by_label("Email").fill("ada@example.com")
    page.get_by_label("I agree").check
    page.get_by_role("button", name: "Sign up").click
    assert_text "Welcome, Ada"
  end
end
```

- **Pages:** `page` is a page in a fresh browser context, like a private window, closed after the test. Each worker launches its own browser, and opens the next tests' pages while a test runs. `visit` takes paths relative to the app.
- **Playwright's API, in Ruby:** `page` has all of Playwright's methods, in snake case, with options as keywords and `?` for `is…`: `page.locator("li").filter(has_text: /ada/i).first.visible?` is `isVisible()`, and `page.keyboard.press("Enter")` works too. Locators are built in Ruby and sent with the call that needs an answer, so a line like `page.get_by_role("button", name: "Go").click` is one round trip. Objects that aren't JSON, such as element handles, come back as objects with the same methods. `evaluate` takes JavaScript as a string, which can be a function given an argument: `page.evaluate("(name) => 'Hi, ' + name", "Ada")`. Timeouts there are in milliseconds, as in Playwright.
- **The app:** each worker serves it with Puma, in the worker's threads. With `config.rails`, the page sees the records a test creates, and they're rolled back after it. What the app raises while serving the page is raised in the test.
- **Waiting assertions:** `assert_text` and `refute_text` (a String or Regexp, `within:` a selector or locator), and `assert_selector` and `refute_selector` (with `text:` or `count:`) wait, in Node, for the page to match. A browser test that calls `sleep` gets a warning, and the summary counts them.
- **Failures:** a failed or errored test's screenshot, HTML and console log are saved in `.quickdraw/browser/`, and their paths are shown with it.
- **Options:** `browser: "firefox"` or `"webkit"` (or `browsers:`, above), `headless: false`, `timeout:` in seconds for actions and assertions (5 by default), `port:` for a fixed port (plus the worker's number) rather than any free one, and `launch:` and `context:` options for Playwright's `launch` and `newContext`.
- **Where Playwright comes from:** the project's own `node_modules/playwright-core` or `node_modules/playwright` if there is one, else the one `qt browser install` put in your cache directory (or `QUICKDRAW_BROWSERS_PATH`, such as a directory CI caches). `QUICKDRAW_PLAYWRIGHT` names another package, and `QUICKDRAW_NODE` another Node. Browsers go where Playwright keeps them (`PLAYWRIGHT_BROWSERS_PATH`).

## Commands

- `qt init` sets a project up, with config and an example test.
- `qt doctor` checks that the machine and project are ready, including for browser tests, and how long config takes to boot.
- `qt browser install` installs what `config.browser`'s tests need (see Browser testing).
- `qt counterpart lib/user.rb` prints a source file's test, or a test's source file.
- `qt mutate` finds code the tests run but don't check (see Mutation testing).
- `qt fuzz` runs properties for longer, guided by the code their cases reach (see Fuzzing).
- `qt completions zsh` prints shell completions, for bash, zsh or fish.
