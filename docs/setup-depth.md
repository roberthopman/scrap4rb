# Setup depth

This document explains how scrap4rb counts the setup depth of a test, and why the count differs from a literal port of SCRAP.

## Setup depth in SCRAP

SCRAP gives each test (`it`) a setup depth in two steps:

  1. The start value is the number of setup forms in the enclosing `describe` and `context` blocks: `before`, `before-all`, `with`, `around`, `with-stubs`, `let`, `binding` and `with-redefs`. Each form counts 1, however many lines it has.
  2. Inside the test, each nested `let`, `binding` or `with-redefs` adds 1. SCRAP keeps the deepest level, not the sum.

The setup depth has three effects:

  - It goes into the complexity score: `saturating(1 + branches + setup_depth + helper_calls)`. The curve rises quickly at the start: 1 gives 1.0, 3 gives 8.26 and 5 gives 13.32.
  - An API-contract test gets 2 levels free.
  - A test with a setup depth above 2 cannot be a coverage-matrix candidate. Thus a file of such tests does not get the "make it table-driven" advice.

The source is `example_collect.clj`, `example_node.clj` and `example_metrics.clj` in [unclebob/scrap](https://github.com/unclebob/scrap).

## Why a literal port does not work

speclj has two kinds of setup:

  - `with` is a named, lazy binding. The Minitest equivalent is `let`, or an instance variable in `setup`.
  - `before` is a block of actions. It counts 1, however many lines it has.

A Rails `setup` block mixes the two kinds:

```ruby
setup do
  @user = users(:alice)
  @order = orders(:open)
  sign_in @user
  visit order_path(@order)
end
```

In speclj, this is two `with` forms and one `before`, so the setup depth is 3.

## The rule

scrap4rb counts the setup depth of a test class or a `describe` block as follows:

  - Each `let`, `let!` and `subject` counts 1.
  - In each `setup` block, `before` block and `def setup`, each instance variable assignment counts 1. For `setup :build_order`, scrap4rb reads the body of the method `build_order`.
  - A setup block that also has other statements counts 1 more. A `super` call is not a statement for this rule.

A nested `describe` block adds its own setup depth to the setup depth of its parent. Inside a test, a context block (`travel_to`, `with_*`, `stub` with a block) adds 1, as a nested `with-redefs` does in SCRAP.

The three possible rules give different results for the setup block above:

```
Rule                                   Depth   API test   Large test   Matrix candidate
----                                   -----   --------   ----------   ----------------
A: 1 per setup block (+1 per let)      1       1.0        4.95         yes
B: 1 per statement (in 0.1.0)          4       8.26       13.32        no
C: 1 per @ivar or let, +1 if actions   3       4.95       11.0         no
```

  - Rule A is the literal mapping of `before`. A 20-line setup block costs 1, but SCRAP has the same weakness with a large `before`.
  - Rule B counts too many. Each action line costs as much as a binding. With a 10-line setup block, the complexity score of a large test is 21.03 instead of 4.95. `let` costs nothing, so a move of the same setup from `setup` into `let` improves the score without a real change.
  - Rule C gives the same number as the equivalent speclj code. scrap4rb uses rule C.

## Locals in a test

In Clojure, a test keeps its locals in a `let`. That `let` adds 1 to the setup depth. SCRAP also gives the `let` form the setup phase, so the assertions inside it do not count as phases. Thus SCRAP never reports multiple-phases for this test:

```clojure
(it "x" (let [x (atom 1)] (should= 1 @x) (reset! x 2) (should= 2 @x)))
```

The same test in Ruby has flat locals. It gets a setup depth of 0 and multiple-phases (5 points). scrap4rb does not copy the Clojure behavior, because Ruby has no `let` scope for the locals of a test. The result is that a Ruby score and a speclj score of the same test can differ.
