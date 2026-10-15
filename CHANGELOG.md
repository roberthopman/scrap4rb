# Changelog

All notable changes are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- The setup depth counts 1 for each `let`, `let!`, `subject` and instance variable in a setup block, plus 1 for a setup block with other statements. Before, it counted 1 for each statement in a setup block, and 0 for `let` and `subject`. See `docs/setup-depth.md`.

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

[Unreleased]: https://github.com/roberthopman/scrap4rb/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/roberthopman/scrap4rb/releases/tag/v0.1.0
