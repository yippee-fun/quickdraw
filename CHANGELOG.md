## [Unreleased]

- `qt` leaves browser tests (`config.browser`'s) out unless they're named by file, failing with `--failed`, or asked for with `--browser`, and says how many files it left out. `qt browser` runs only browser tests, and `qt all` runs everything. `config.browser(…, by_default: true)` keeps them in a plain run.
- A test that finishes without making an assertion fails, unless it skips. A test without a block is still pending. The summary no longer counts tests without assertions, and JSON drops `without_assertions`.

## [0.1.0] - 2023-02-19

- Initial release
