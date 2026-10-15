# The compare verdict

This document explains one deviation from SCRAP in `--compare`: when hidden helper lines make the verdict `worse`.

## The rule in SCRAP

SCRAP compares the summary of each file with the baseline, and gives a verdict in this order:

```
Verdict     When
-------     ----
improved    file score -5 or more, no rise in extraction pressure or in max SCRAP
worse       helper regression: more tests with hidden helper lines, no fall in
            extraction pressure, and no more table-drive candidates
worse       any rise in extraction pressure or max SCRAP, or file score +5 or more
unchanged   file score delta 0
mixed       all other cases
```

The helper regression rule looks for a refactor that moves setup into a local helper. The setup is then hidden, but the duplication does not go down. The rule uses `helper_hidden_delta`: the change in the number of tests that call a local helper.

The source is `comparison.clj` in [unclebob/scrap](https://github.com/unclebob/scrap).

## The problem

`helper_hidden_delta` is a count, not a ratio. A new test that calls an existing helper adds 1. Thus a change that adds tests which call a helper gets the verdict `worse`, also when all scores improve. scrap4rb's own test suite shows this:

```
Change                          file score   max SCRAP   helper_hidden   tests   SCRAP verdict
------                          ----------   ---------   -------------   -----   -------------
4 tests for setup depth         -0.75        0.0         +2              +4      worse
6 tests for branches and files  -0.76        0.0         +6              +6      worse
```

The advice that follows, "revert it, or simplify the helpers", is wrong for these changes. SCRAP has the same behavior.

## The rule in scrap4rb

scrap4rb compares `helper_hidden_delta` with the number of new tests:

```
helper regression = helper_hidden_delta > max(example_count_delta, 0)
                    and extraction pressure did not fall
                    and table-drive candidates did not rise
```

  - A new test that calls a helper is not a regression.
  - An existing test that starts to call a helper is a regression, as in SCRAP.
  - When tests are removed, the limit is 0, so removed tests cannot hide a regression.

`--compare` shows `example_count_delta`, so the reason for a verdict is visible.

## The limit of the rule

The rule counts tests, not names. Suppose a change adds 2 tests without helpers and moves 2 existing tests to a helper. Then `helper_hidden_delta` is 2, `example_count_delta` is 2, and the rule does not see the regression. To see it, scrap4rb would have to match the tests in the baseline by name. The baseline does not store the tests, so scrap4rb does not do this.
