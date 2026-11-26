## [Unreleased]

- Once run history says how much work a run is, workers with two seconds or more of it each run tests with YJIT. `--[no-]yjit` or `config.yjit` overrides that.
- The `qt` executable is now `qd`.
- `qd` leaves browser tests (`config.browser`'s) out unless they're named by file, failing with `--failed`, or asked for with `--browser`, and says how many files it left out. `qd browser` runs only browser tests, and `qd all` runs everything. `config.browser(…, by_default: true)` keeps them in a plain run.
- A test that finishes without making an assertion fails, unless it skips. A test without a block is still pending. The summary no longer counts tests without assertions, and JSON drops `without_assertions`.
- The last run is kept as `.quickdraw/last-run.jsonl`, written as problems are found, with the Ruby, platform and arguments it ran with. `qd last --from FILE` reads one kept elsewhere, such as a CI artifact.
- GitHub Actions annotations' messages start with the test's name and location, and indent their other lines.
- A run with fewer files than workers starts a worker for each file, and the rest once a file has enough tests waiting for them to share, so running one file no longer starts a worker for every core.
- `after_tests` defines a test that runs once the class's other tests have passed, in whichever workers, with what they `gather`ed.

## [0.1.0] - 2023-02-19

- Initial release
