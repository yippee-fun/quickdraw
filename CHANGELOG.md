## [Unreleased]

- `qt` leaves browser tests (`config.browser`'s) out unless they're named by file, failing with `--failed`, or asked for with `--browser`, and says how many files it left out. `qt browser` runs only browser tests, and `qt all` runs everything. `config.browser(…, by_default: true)` keeps them in a plain run.

## [0.1.0] - 2023-02-19

- Initial release
