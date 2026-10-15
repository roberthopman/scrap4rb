require_relative "../test_helper"
require "scrap4rb"

class JudgmentTest < Minitest::Test
  J = Scrap4rb::Judgment

  def summary(**over)
    { example_count: 10, avg_scrap: 1.0, max_scrap: 1.0, effective_duplication_score: 0, low_assertion_examples: 0,
      zero_assertion_examples: 0, branching_examples: 0, with_redefs_examples: 0, helper_hidden_example_count: 0,
      case_matrix_repetition: 0, coverage_matrix_candidates: 0, subject_repetition_score: 0 }.merge(over)
  end

  def test_a_file_is_stable_up_to_a_max_scrap_of_twelve
    assert J.stable?(summary(max_scrap: 12))
    refute J.stable?(summary(max_scrap: 12.01))
  end

  def test_a_file_is_stable_up_to_35_percent_low_assertion_tests
    assert J.stable?(summary(example_count: 20, low_assertion_examples: 7))
    refute J.stable?(summary(example_count: 20, low_assertion_examples: 8))
  end

  def test_one_test_without_assertions_makes_a_file_unstable
    refute J.stable?(summary(zero_assertion_examples: 1))
  end

  def test_pressure_levels_change_at_18_35_and_55
    unstable = { max_scrap: 13 }
    level_for = ->(avg) { J.level(summary(**unstable, avg_scrap: avg)) }
    score = ->(avg) { J.pressure_score(summary(**unstable, avg_scrap: avg)) }
    assert_in_delta 9.0, score.(1), 0.001
    assert_equal %w[LOW MEDIUM HIGH CRITICAL], [8.4, 8.5, 22.7, 39.4].map { level_for.(_1) }
    assert_operator score.(8.4), :<, 18
    assert_operator score.(8.5), :>=, 18
  end

  def test_a_small_file_scales_its_pressure_down
    assert_equal 0.25 * (1.2 * 10 + 0.6 * 20), J.pressure_score(summary(example_count: 1, avg_scrap: 10, max_scrap: 20))
  end

  def test_split_needs_twelve_tests_a_hotspot_and_spread_pressure
    hot = { avg_scrap: 10, max_scrap: 35 }
    assert_equal "SPLIT", J.remediation_mode(summary(example_count: 12, **hot), [])
    assert_equal "LOCAL", J.remediation_mode(summary(example_count: 11, **hot), [])
    assert_equal "LOCAL", J.remediation_mode(summary(example_count: 12, avg_scrap: 9.9, max_scrap: 35), [])
    assert_equal "STABLE", J.remediation_mode(summary, [])
  end

  def test_actionability_walks_stable_matrix_local_split_and_review
    assert_equal "LEAVE_ALONE", J.actionability(summary, "STABLE")
    assert_equal "AUTO_TABLE_DRIVE", J.actionability(summary(coverage_matrix_candidates: 2, case_matrix_repetition: 2, max_scrap: 12), "LOCAL")
    assert_equal "AUTO_REFACTOR", J.actionability(summary(zero_assertion_examples: 1), "LOCAL")
    assert_equal "MANUAL_SPLIT", J.actionability(summary(branching_examples: 5), "SPLIT")
    assert_equal "REVIEW_FIRST", J.actionability(summary(zero_assertion_examples: 1, branching_examples: 4), "LOCAL")
  end

  def test_a_stable_file_gets_one_leave_it_alone_action
    assert_equal [[3, "No refactor recommended; the file is structurally stable enough to leave alone."]], J.actions(summary, "STABLE")
  end

  def test_actions_are_capped_at_four_and_sorted_by_confidence
    s = summary(coverage_matrix_candidates: 1, zero_assertion_examples: 1, max_scrap: 21, effective_duplication_score: 1,
                with_redefs_examples: 4, branching_examples: 4, helper_hidden_example_count: 1, avg_scrap: 13)
    actions = J.actions(s, "LOCAL")
    assert_equal 4, actions.size
    assert_equal [3, 3, 3, 2], actions.map(&:first)
  end

  def verdict(**over)
    J.verdict({ file_score_delta: 0, extraction_pressure_delta: 0, max_scrap_delta: 0, case_matrix_delta: 0, helper_hidden_delta: 0,
                example_count_delta: 0 }.merge(over))
  end

  def test_a_comparison_is_improved_from_a_five_point_drop
    assert_equal "improved", verdict(file_score_delta: -5)
    assert_equal "mixed", verdict(file_score_delta: -4.99)
  end

  def test_a_comparison_is_worse_when_a_helper_only_hides_complexity
    assert_equal "worse", verdict(file_score_delta: -1, helper_hidden_delta: 1)
  end

  def test_new_tests_that_call_a_helper_are_not_a_helper_regression
    assert_equal "mixed", verdict(file_score_delta: -1, helper_hidden_delta: 2, example_count_delta: 2)
    assert_equal "worse", verdict(file_score_delta: -1, helper_hidden_delta: 3, example_count_delta: 2)
  end

  def test_removed_tests_without_new_helper_calls_are_not_a_helper_regression
    assert_equal "mixed", verdict(file_score_delta: -1, helper_hidden_delta: 0, example_count_delta: -2)
  end

  def test_a_comparison_is_worse_from_a_five_point_rise_or_any_max_rise
    assert_equal "worse", verdict(file_score_delta: 5)
    assert_equal "mixed", verdict(file_score_delta: 4.99)
    assert_equal "worse", verdict(max_scrap_delta: 0.1)
  end

  def test_no_change_is_unchanged
    assert_equal "unchanged", verdict
  end
end
