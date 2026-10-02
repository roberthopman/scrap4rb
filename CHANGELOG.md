# Changelog

All notable changes are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
