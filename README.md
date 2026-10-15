# scrap4rb

`scrap4rb` scores Minitest test code for structural quality. It is a Ruby port of [SCRAP](https://github.com/unclebob/scrap) by Robert C. Martin (Uncle Bob). SCRAP does for test code what CRAP does for production code: it finds the tests that are too large, too weak, too logic-heavy or too mock-heavy, and the duplicated scaffolding that is worth a helper.

For each test file, scrap4rb answers three questions for a programmer or an AI assistant:

  - Is this file poorly structured enough to refactor?
  - Where is the worst structure: which tests, which lines?
  - How to refactor: split the file, fix tests in place, make a table, or leave it alone?

The output is advice, not a verdict. Read the file before you act on it.

## Installation

```bash
gem install scrap4rb
```

Or add it to a Gemfile:

```ruby
gem "scrap4rb", group: :development
```

From a checkout you can run it without installing:

```bash
ruby -Ilib exe/scrap4rb path/to/project/test
```

## Usage

Run it from the project root. The default path is `test`.

```bash
scrap4rb                                   # files that need attention, plus totals
scrap4rb --all                             # every file, STABLE included
scrap4rb --verbose test/models             # per-test metrics
scrap4rb --json > scrap.json               # the full report as data
scrap4rb test/models/order_test.rb         # one file
```

Before and after a refactor:

```bash
scrap4rb --write-baseline tmp/scrap.json
# refactor the tests
scrap4rb --compare tmp/scrap.json
```

The comparison gives each changed file a verdict: `improved`, `worse`, `mixed` or `unchanged`. When the verdict is `worse`, revert the refactor or simplify the helpers.

## Output

```
test/models/smelly_test.rb
  score 48.46 HIGH  mode LOCAL  ai AUTO_REFACTOR  tests=6 avg=12.78 max=18.26
  HIGH   Strengthen assertions in weak tests before doing structural cleanup.
  LOW    Be skeptical of helper extraction that only hides setup; ...
   18.3  L59   it uses a long local helper          low-assertion-density,helper-hidden-complexity
   17.3  L35   it handles a large payload           low-assertion-density,literal-heavy-setup
   11.0  L8    it saves the record                  no-assertions
  EXTRACT L4-17 net=31.74 (I=3 shared=22 variable=0): hours above 168 ... | negative hours ...
```

```
Field      Meaning
-----      -------
score      Refactor pressure of the file
level      STABLE, LOW, MEDIUM, HIGH or CRITICAL
mode       STABLE: leave it. LOCAL: fix tests in place. SPLIT: split the file first
ai         LEAVE_ALONE, AUTO_TABLE_DRIVE, AUTO_REFACTOR, MANUAL_SPLIT or REVIEW_FIRST
HIGH/...   Recommendations, ranked by confidence, at most four
tests      The SCRAP score of each test, worst first, with its smells
EXTRACT    A group of tests where a shared helper pays for itself
```

## What it checks

Structure errors:

  - a `test` inside a `test`
  - a `setup`, `teardown`, `describe`, `context` or `class` inside a test
  - a second `def test_x` with the same name in one class (the first one never runs)
  - parse errors

Smells per test, with the SCRAP penalty:

```
Smell                      Fires when                                      Penalty
-----                      ----------                                      -------
no-assertions              the test has no assertion                       10
low-assertion-density      one assertion in more than 10 lines              6
multiple-phases            assert, act, assert again                        5
high-mocking               more than 3 stubs or mocks                       4
large-example              more than 20 lines                               4
helper-hidden-complexity   more than 8 lines hidden in local helpers        4
temp-resource-work         files, directories, threads or processes         3
literal-heavy-setup        a string over 5 lines, a hash or array over 10   3
```

A short test with one or two assertions and few subjects is an "API contract" test. SCRAP excuses it from the low-assertion-density and large-example smells.

Duplication is structural and fuzzy. Names and literal values become placeholders, so two tests that differ only in their numbers have the same shape. scrap4rb separates three kinds:

  - **Harmful duplication**: repeated setup, arrange or assertion code. It becomes an EXTRACT recommendation only when a helper pays for itself after its own cost.
  - **Coverage matrix**: many small, similar tests. The advice is "make it one table-driven test", not "this is bad".
  - **Subject repetition**: many tests of the same API. This is normal and costs almost nothing.

## How SCRAP maps to Minitest

```
SCRAP (speclj)          scrap4rb (Minitest)
--------------          -------------------
describe, context       a test class, or a minitest/spec describe block
it                      test "..." do, def test_*, it "..." do, define_method(:"test_...")
before, with            setup blocks, setup :method and def setup, let and subject,
                        inherited by every test in the class (see docs/setup-depth.md)
let, binding            travel_to, freeze_time, within, using_session,
                        perform_enqueued_jobs, with_*, and stub with a block
with-redefs             stub, stub_request, any_instance, expects, stubs, Minitest::Mock.new
should*                 assert*, refute*, must_*, wont_*
doseq, for, every?      for, each, each_with_index, map, times, all?, ...
if, when, cond, and     if, unless, case, while, until, &&, ||, rescue modifier
loop, try               loop, begin/rescue (one per begin)
```

The policy numbers (weights, thresholds, levels) are SCRAP's, unchanged.

## Deviations from SCRAP

  - A test whose whole body is one context block, such as `travel_to(...) do ... end`, is unwrapped before the phase count. In Ruby that block is test context, not arrange code.
  - A call to an assertion helper defined in `test/test_helper.rb`, `test/application_system_test_case.rb`, `test/test_helpers/` or `test/support/` counts as one assertion. SCRAP only reads the spec file itself. Without this rule, every test that uses a shared assertion helper would be "no-assertions".
  - A loop over a literal hash (`{ 5 => 0, 6 => 10 }.each`) counts as table-driven, the same as a loop over an array of arrays.

## Notes for Rails suites

Two SCRAP rules can disagree with common Rails practice. Decide for your own suite.

  - **multiple-phases**: a system test that asserts after each click (to prove that the page changed before the next step) has several phases, and SCRAP gives it 5 points.
  - **Low-assertion files**: a file is not STABLE when more than 35% of its tests have one assertion or fewer. A suite with "one behavior, one assertion" tests will have many LOCAL files for this reason only.

## Development

```bash
bundle install
rake test                      # unit tests and golden snapshots
UPDATE_GOLDEN=1 rake test      # rewrite the snapshots after an intended change
```

The golden tests run the executable against the fixture suite in `test/fixtures/sample`. A golden diff means that the output changed. Accept it only when the change was intended.

## Credits

SCRAP is by Robert C. Martin (Uncle Bob): [github.com/unclebob/scrap](https://github.com/unclebob/scrap). The algorithm, the metrics, the smells and the policy numbers in scrap4rb come from SCRAP. scrap4rb is an independent Ruby implementation. It contains no SCRAP source code.

scrap4rb 0.1.0 follows SCRAP at commit [`f793b28`](https://github.com/unclebob/scrap/tree/f793b28906d3c60e30b128e1ec08df6269a72b13) (2026-03-17). When SCRAP changes its rules or numbers, scrap4rb can differ until it follows again.

Related tools by the same author: [crap4clj](https://github.com/unclebob/crap4clj), [crap4java](https://github.com/unclebob/crap4java), [crap4go](https://github.com/unclebob/crap4go) and [clj-mutate](https://github.com/unclebob/clj-mutate).

## License

scrap4rb is released under the MIT License. See [LICENSE](LICENSE). The license covers the code in this repository. It does not cover SCRAP itself.
