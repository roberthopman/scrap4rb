module Scrap4rb
  module Policy
    REPORT = { top_example_count: 5, top_block_count: 3 }.freeze
    DUPLICATION = { threshold: 0.5, matrix_max_scrap: 18, matrix_max_lines: 12, matrix_max_assertions: 1,
                    matrix_max_branches: 0, matrix_max_setup_depth: 2, matrix_max_with_redefs: 0,
                    matrix_max_temp_resources: 0, matrix_max_helper_hidden_lines: 0, matrix_max_subject_symbols: 2 }.freeze
    COMPLEXITY = { cap: 25.0, rise_rate: 0.18, floor: 1.0 }.freeze
    PRESSURE = {
      size_factors: [[1, 0.25], [2, 0.40], [4, 0.65], [nil, 1.0]],
      weights: { avg_scrap: 1.2, max_scrap: 0.6, effective_duplication_score: 0.8, low_assertion_ratio: 20,
                 branching_ratio: 15, with_redefs_ratio: 15, helper_hidden_ratio: 12 },
      matrix_credit: 1.5,
      levels: { critical: 55, high: 35, medium: 18 },
      split: { avg_scrap: 10, effective_duplication_score: 20, subject_repetition_score: 12, example_count: 12,
               high_pressure_blocks: 2, max_scrap: 35 }
    }.freeze
    ACTIONABILITY = {
      matrix: { min_case_matrix_repetition: 2, effective_duplication_divisor: 3, max_scrap: 12,
                max_branching_ratio: 0.15, max_mocking_ratio: 0.2 },
      local: { low_assertion_ratio: 0.4, max_branching_ratio: 0.3, max_mocking_ratio: 0.35, max_scrap: 20, avg_scrap: 12 },
      max_actions: 4
    }.freeze
  end
end
