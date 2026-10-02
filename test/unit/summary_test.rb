require_relative "../test_helper"
require "scrap4rb"

class SummaryTest < Minitest::Test
  def summary_of(body)
    src = "class T < Minitest::Test\n#{body}\nend\n"
    Scrap4rb::Summary.summarize(Scrap4rb::Example.from_source(src, shared_assert_helpers: Set.new))
  end

  def boundary_trio
    [200, -1, 168].map do |hours|
      "test \"#{hours}\" do\n  a = Availability.new(employee: employees(:tim), year: 2026, week: 30, hours: #{hours})\n  assert_not a.valid?\nend"
    end.join("\n")
  end

  def test_jaccard_is_shared_over_union_and_zero_for_two_empty_sets
    assert_in_delta 0.5, Scrap4rb::Summary.jaccard(Set[1, 2], Set[2, 3, 1, 4]), 0.0001
    assert_equal 0.0, Scrap4rb::Summary.jaccard(Set.new, Set.new)
  end

  def test_duplication_cost_is_zero_up_to_three_shared_forms_and_above_four_variable_points
    assert_equal 0.0, Scrap4rb::Summary.duplication_cost(3, 5, 0)
    assert_equal 0.0, Scrap4rb::Summary.duplication_cost(5, 5, 5)
    assert_equal 8.0, Scrap4rb::Summary.duplication_cost(5, 5, 1)
    assert_equal 1.0, Scrap4rb::Summary.duplication_cost(4, 2, 0)
  end

  def test_three_tests_that_differ_only_in_one_number_get_one_extraction
    s = summary_of(boundary_trio)
    assert_equal 1, s[:recommended_extraction_count]
    assert_equal 3, s[:recommended_extractions].first[:instances]
    assert_equal 0, s[:recommended_extractions].first[:variable_points]
  end

  def test_one_test_has_no_extraction_and_no_duplication
    s = summary_of("test \"a\" do\n  assert_equal 1, f(1)\nend")
    assert_equal [0, 0, 0], s.values_at(:recommended_extraction_count, :harmful_duplication_score, :coverage_matrix_candidates)
  end

  def test_small_one_assertion_siblings_are_a_coverage_matrix_not_an_extraction
    s = summary_of([5, 6, 10, 11].map { "test \"#{_1}\" do\n  assert_equal 1, f(#{_1})\nend" }.join("\n"))
    assert_equal 4, s[:coverage_matrix_candidates]
    assert_equal 0, s[:recommended_extraction_count]
  end

  def test_counts_low_zero_and_branching_tests
    s = summary_of("test \"a\" do\n  f\nend\ntest \"b\" do\n  assert f if g\nend\ntest \"c\" do\n  assert a\n  assert b\nend")
    assert_equal [3, 2, 1, 1], s.values_at(:example_count, :low_assertion_examples, :zero_assertion_examples, :branching_examples)
  end
end
