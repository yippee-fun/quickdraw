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

## Mutation testing

Coverage says which code your tests run, not whether they check it. `qt mutate` changes your code in small ways, one at a time, and runs the tests that run each change. If none fails, the change survives, and the tests don't notice that line being wrong:

```sh
qt mutate                      # the lines changed since the last commit
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

- **Changes:** comparisons (`>` to `>=`, `==` to `!=`), arithmetic (`+` to `-`, `*` to `/`), `&&` to `||`, removing a `!`, negating a condition, `true` to `false`, a number to one more or to 0, methods such as `select` to `reject` or `first` to `last`, removing a statement, and replacing a method's body with `nil`. Only in methods, and not changes that can't make a difference, such as `x + 0` to `x - 0`.
- **Which tests:** the test files that run a file, from the last `qt --coverage` run, or else its counterpart by name. Those run once unchanged, tracing which lines of the changed methods each test runs, so each change runs only the tests that reach it, fastest first, and stops at the first failure. Tests that fail without changes don't count, and changes no test reaches aren't run, but are listed by line.
- **Safely:** your files never change. Config boots once, and each change is made by redefining its method in a process forked for it, which exits when its tests finish. A change that makes tests run three times as long as they did (plus half a second) is taken to loop forever, and counts as noticed.
- **Results:** `--format human`, `agent` or `json`. It exits with 1 if any change survives, or with `--threshold 80`, if fewer than 80% are noticed, and also if some tests or changes couldn't run. Tests' `rand` is seeded the same way every time (`--seed N` changes it), so results don't vary between runs.

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

Browser tests use [Playwright](https://playwright.dev), through the `playwright-ruby-client` gem, which needs to be in your bundle, with Puma to serve your app. `config.browser` runs the files matching its patterns in a group of their own, so other tests never load Playwright. The block returns the app they test:

```ruby
Quickdraw.configure do |config|
  config.rails
  config.browser("test/system/**/*.test.rb") { Rails.application }
end
```

```ruby
class SignupTest < Quickdraw::Test
  include Quickdraw::Browser

  test "signs up" do
    visit "/signup"
    page.get_by_label("Email").fill("ada@example.com")
    page.get_by_role("button", name: "Sign up").click
    assert_text "Welcome, Ada"
  end
end
```

- **Pages:** `page` is a Playwright page in a fresh browser context, like a private window, closed after the test. Each worker launches its own browser, and opens the next test's page while a test runs. `visit` takes paths relative to the app.
- **The app:** each worker serves it with Puma, in the worker's threads. With `config.rails`, the page sees the records a test creates, and they're rolled back after it. What the app raises while serving the page is raised in the test.
- **Waiting assertions:** `assert_text` and `refute_text` (a String or Regexp, `within:` an element), and `assert_selector` and `refute_selector` (with `text:` or `count:`) wait, in the browser, for the page to match. A browser test that calls `sleep` gets a warning, and the summary counts them.
- **Failures:** a failed or errored test's screenshot, HTML and console log are saved in `.quickdraw/browser/`, and their paths are shown with it.
- **Options:** `browser: "firefox"` or `"webkit"`, `headless: false`, `timeout:` in seconds for actions and assertions (5 by default), `port:` for a fixed port (plus the worker's number) rather than any free one, `launch:` and `context:` options for Playwright, and `driver:`, the Playwright command, which must be the version the gem needs. By default it's `PLAYWRIGHT_CLI_EXECUTABLE_PATH`, or `node_modules/.bin/playwright` if there is one, or `npx playwright@VERSION`. Install its browsers with `npx playwright@VERSION install chromium`.

## Commands

- `qt init` sets a project up, with config and an example test.
- `qt doctor` checks that the machine and project are ready, and how long config takes to boot.
- `qt counterpart lib/user.rb` prints a source file's test, or a test's source file.
- `qt mutate` finds code the tests run but don't check (see Mutation testing).
- `qt completions zsh` prints shell completions, for bash, zsh or fish.
