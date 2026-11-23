## [Unreleased]

- The `qt` executable is now `qd`.
- `qd` leaves browser tests (`config.browser`'s) out unless they're named by file, failing with `--failed`, or asked for with `--browser`, and says how many files it left out. `qd browser` runs only browser tests, and `qd all` runs everything. `config.browser(…, by_default: true)` keeps them in a plain run.
- A test that finishes without making an assertion fails, unless it skips. A test without a block is still pending. The summary no longer counts tests without assertions, and JSON drops `without_assertions`.
- The last run is kept as `.quickdraw/last-run.jsonl`, written as problems are found, with the Ruby, platform and arguments it ran with. `qd last --from FILE` reads one kept elsewhere, such as a CI artifact.
- GitHub Actions annotations' messages start with the test's name and location, and indent their other lines.
- With `config.rails` on PostgreSQL, each worker's databases are copies of a template database that holds the schema and every fixture set, built once and kept until either changes.

## [0.1.0] - 2023-02-19

- Initial release
