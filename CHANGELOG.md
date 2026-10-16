# Changelog

All notable changes are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-10-16

### Fixed
- The README tells you to run scrap4rb from the project root when you run it from a checkout. From the scrap4rb folder, scrap4rb does not find the shared assertion helpers of the project, and a test that uses one reads as `no-assertions`.
- The README lists all structure errors, limits the 35% low-assertion rule to files with more than two tests, and lists three more deviations from SCRAP.

## [0.2.0] - 2026-10-15

### Changed
- The setup depth counts 1 for each `let`, `let!`, `subject` and instance variable in a setup block, plus 1 for a setup block with other statements. Before, it counted 1 for each statement in a setup block, and 0 for `let` and `subject`. See `docs/setup-depth.md`.
- temp-resource-work also counts file reads and writes, directories and processes: `File`, `IO` and `Dir` calls such as `read`, `open` and `mkdir`, `IO.popen`, `Open3` and `exec`. `File.join` and `file_fixture(...).read` do not count.
- A `begin` with several `rescue` clauses is one branch, as a `try` is in SCRAP. Before, each clause counted 1.
- The `--compare` verdict is `worse` for hidden helper lines only when more tests have them than the number of new tests. Before, a new test that called a helper made the verdict `worse`. See `docs/compare-verdict.md`.

### Added
- A `why` line for each file, with the ratios and counts behind the score, as in the SCRAP report.
- `where` lines for a file with more than one describe block or class: the three blocks with the most pressure and the worst test of each. The JSON report has them as `top_blocks`.
- `--compare` shows `example_count_delta`.
- `loop do` is a branch, and `for x in` is a table branch. A `for` loop over a literal table is table-driven.
- The setup depth follows `setup :method_name` to the body of the method.

### Fixed
- A bare `super` in `def setup` no longer counts as a setup statement.

## [0.1.0] - 2026-10-02

### Added
- Initial release. A Ruby port of SCRAP by Robert C. Martin for Minitest
  test files: structure errors, a SCRAP score and smells per test, fuzzy
  duplication with extraction pressure, coverage-matrix detection, and per
  file a refactor pressure, a remediation mode and an AI actionability class.
- `scrap4rb` executable with `--all`, `--verbose`, `--json`,
  `--write-baseline` and `--compare`.
- Support for `test "..." do`, `def test_*`, `define_method(:"test_...")` and minitest/spec
  `describe`/`it` blocks. A `define_method` test inside a loop over a table
  (`CASES.each`) is one table-driven test that spans the loop.

[Unreleased]: https://github.com/roberthopman/scrap4rb/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/roberthopman/scrap4rb/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/roberthopman/scrap4rb/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/roberthopman/scrap4rb/releases/tag/v0.1.0
