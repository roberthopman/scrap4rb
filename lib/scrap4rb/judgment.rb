require_relative "policy"

module Scrap4rb
  module Judgment
    extend self

    def ratio(n, d) = d.positive? ? n.fdiv(d) : 0.0

    def stable?(s)
      n = s[:example_count]
      zero = ratio(s[:zero_assertion_examples], n)
      low = ratio(s[:low_assertion_examples], n)
      small = n <= 2 && s[:max_scrap] <= 10 && s[:effective_duplication_score] <= 1 && s[:helper_hidden_example_count].zero? && zero <= 0
      general = n.positive? && s[:max_scrap] <= 12 && s[:effective_duplication_score] <= 3 && zero <= 0 && low <= 0.35
      small || general
    end

    def pressure_score(s)
      n = s[:example_count]
      w = Policy::PRESSURE[:weights]
      base = w[:avg_scrap] * s[:avg_scrap] + w[:max_scrap] * s[:max_scrap] +
             w[:effective_duplication_score] * s[:effective_duplication_score] +
             w[:low_assertion_ratio] * ratio(s[:low_assertion_examples], n) +
             w[:branching_ratio] * ratio(s[:branching_examples], n) +
             w[:with_redefs_ratio] * ratio(s[:with_redefs_examples], n) +
             w[:helper_hidden_ratio] * ratio(s[:helper_hidden_example_count], n)
      factor = Policy::PRESSURE[:size_factors].find { |up_to, _| up_to.nil? || n <= up_to }.last
      [0, factor * base - Policy::PRESSURE[:matrix_credit] * s[:case_matrix_repetition]].max.round(2)
    end

    def level(s)
      score = pressure_score(s)
      l = Policy::PRESSURE[:levels]
      if stable?(s) then "STABLE"
      elsif score >= l[:critical] then "CRITICAL"
      elsif score >= l[:high] then "HIGH"
      elsif score >= l[:medium] then "MEDIUM"
      else "LOW"
      end
    end

    def remediation_mode(s, blocks)
      sp = Policy::PRESSURE[:split]
      hot_blocks = blocks.count { %w[HIGH CRITICAL].include?(level(_1[:summary])) }
      split_pressure = s[:avg_scrap] >= sp[:avg_scrap] || s[:effective_duplication_score] >= sp[:effective_duplication_score] ||
                       s[:subject_repetition_score] >= sp[:subject_repetition_score] || s[:helper_hidden_example_count].positive?
      if stable?(s) then "STABLE"
      elsif s[:example_count] >= sp[:example_count] && (hot_blocks >= sp[:high_pressure_blocks] || s[:max_scrap] >= sp[:max_scrap]) && split_pressure
        "SPLIT"
      else "LOCAL"
      end
    end

    def ratios(s)
      n = s[:example_count]
      { low: ratio(s[:low_assertion_examples], n), zero: ratio(s[:zero_assertion_examples], n),
        branching: ratio(s[:branching_examples], n), mocking: ratio(s[:with_redefs_examples], n) }
    end

    def actionability(s, mode)
      if mode == "STABLE" then "LEAVE_ALONE"
      elsif matrix_heavy?(s) then "AUTO_TABLE_DRIVE"
      elsif local_safe?(s, mode) then "AUTO_REFACTOR"
      elsif mode == "SPLIT" then "MANUAL_SPLIT"
      else "REVIEW_FIRST"
      end
    end

    def matrix_heavy?(s)
      r = ratios(s)
      m = Policy::ACTIONABILITY[:matrix]
      s[:coverage_matrix_candidates].positive? &&
        s[:case_matrix_repetition] >= [m[:min_case_matrix_repetition], (s[:effective_duplication_score] / m[:effective_duplication_divisor]).floor].max &&
        s[:max_scrap] <= m[:max_scrap] && r[:branching] <= m[:max_branching_ratio] && r[:mocking] < m[:max_mocking_ratio]
    end

    def local_safe?(s, mode)
      r = ratios(s)
      l = Policy::ACTIONABILITY[:local]
      mode == "LOCAL" &&
        (s[:effective_duplication_score].positive? || r[:zero].positive? || r[:low] > l[:low_assertion_ratio] || s[:max_scrap] > l[:max_scrap]) &&
        r[:branching] <= l[:max_branching_ratio] && r[:mocking] < l[:max_mocking_ratio]
    end

    def actions(s, mode)
      return [[3, "No refactor recommended; the file is structurally stable enough to leave alone."]] if mode == "STABLE"
      r = ratios(s)
      l = Policy::ACTIONABILITY[:local]
      [
        [mode == "SPLIT", 3, "Split this test file by responsibility before attempting local cleanup; the structural pressure is spread across multiple hotspots."],
        [s[:coverage_matrix_candidates].positive?, 3, "Convert repeated low-complexity tests into table-driven checks; treat this as coverage-matrix repetition, not harmful duplication."],
        [r[:zero].positive? || r[:low] > l[:low_assertion_ratio], 3, "Strengthen assertions in weak tests before doing structural cleanup."],
        [mode == "LOCAL" && s[:max_scrap] > l[:max_scrap], 3, "Split oversized tests into narrower tests."],
        [s[:effective_duplication_score].positive?, 2, "Extract shared setup or repeated assertion scaffolding only where harmful duplication is dominating."],
        [r[:mocking] > l[:max_mocking_ratio], 2, "Reduce mocking and move coverage toward higher-level behaviors."],
        [r[:branching] > l[:max_branching_ratio], 2, "Remove logic from tests or keep variation in explicit data tables rather than control flow."],
        [s[:helper_hidden_example_count].positive?, 1, "Be skeptical of helper extraction that only hides setup; helper-hidden complexity should still count as complexity."],
        [mode == "LOCAL" && s[:avg_scrap] > l[:avg_scrap], 1, "Consider splitting this file or block by responsibility."]
      ].select(&:first).map { _1.drop(1) }.sort_by { [-_1[0], _1[1]] }.first(Policy::ACTIONABILITY[:max_actions])
    end

    def verdict(c)
      if c[:file_score_delta] <= -5 && c[:extraction_pressure_delta] <= 0 && c[:max_scrap_delta] <= 0 then "improved"
      elsif c[:helper_hidden_delta] > [c[:example_count_delta], 0].max && c[:extraction_pressure_delta] >= 0 && c[:case_matrix_delta] <= 0
        "worse"
      elsif c[:extraction_pressure_delta].positive? || c[:max_scrap_delta].positive? || c[:file_score_delta] >= 5 then "worse"
      elsif c[:file_score_delta].zero? then "unchanged"
      else "mixed"
      end
    end
  end
end
