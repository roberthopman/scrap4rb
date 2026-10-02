require "set"
require_relative "policy"

module Scrap4rb
  module Summary
    extend self

    def jaccard(a, b)
      union = a | b
      union.empty? ? 0.0 : (a & b).size.fdiv(union.size)
    end

    def duplication_cost(shared, instances, variable)
      return 0.0 if shared <= 3 || variable > 4
      (shared - 3) * (instances - 1)**1.5 / (variable + 1)
    end

    def summarize(exs)
      total = exs.size
      recs = extractions(exs)
      matrix = coverage_matrix_count(exs)
      dup = %i[setup assert fixture literal arrange].to_h { [_1, similar_count(exs, :"#{_1}_features")] }
      pressure = recs.sum { _1[:net_benefit] }.round(2)
      {
        example_count: total,
        avg_scrap: total.positive? ? (exs.sum { _1[:scrap] } / total).round(2) : 0.0,
        max_scrap: exs.map { _1[:scrap] }.max || 0,
        branching_examples: exs.count { _1[:branches].positive? && !_1[:table_driven] },
        low_assertion_examples: exs.count { _1[:assertions] <= 1 },
        with_redefs_examples: exs.count { _1[:with_redefs].positive? },
        zero_assertion_examples: exs.count { _1[:assertions].zero? },
        helper_hidden_example_count: exs.count { _1[:helper_hidden_lines].positive? },
        table_driven_examples: exs.count { _1[:table_driven] },
        setup_duplication_score: dup[:setup], assertion_duplication_score: dup[:assert],
        fixture_duplication_score: dup[:fixture], literal_duplication_score: dup[:literal],
        arrange_duplication_score: dup[:arrange],
        subject_repetition_score: similar_count(exs, :subject_symbols),
        duplication_score: dup.values.sum,
        harmful_duplication_score: dup.values_at(:setup, :assert, :fixture, :arrange).sum,
        avg_setup_similarity: average_similarity(exs, :setup_features).round(3),
        avg_assert_similarity: average_similarity(exs, :assert_features).round(3),
        avg_arrange_similarity: average_similarity(exs, :arrange_features).round(3),
        avg_subject_similarity: average_similarity(exs, :subject_symbols).round(3),
        coverage_matrix_candidates: matrix, case_matrix_repetition: matrix,
        recommended_extraction_count: recs.size,
        extraction_pressure_score: pressure,
        effective_duplication_score: pressure,
        recommended_extractions: recs
      }
    end

    def extractions(exs)
      components(exs).reject { |c| c.all? { extraction_matrix?(_1) } }.map { extraction(_1) }
                     .select { _1[:net_benefit].positive? }.sort_by { [_1[:line_start], -_1[:net_benefit]] }
    end

    def similar_to_any?(ex, exs, key) = ex[key].any? && exs.any? { !_1.equal?(ex) && jaccard(ex[key], _1[key]) >= Policy::DUPLICATION[:threshold] }
    def similar_count(exs, key) = exs.count { similar_to_any?(_1, exs, key) }

    def average_similarity(exs, key)
      pairs = exs.combination(2).map { jaccard(_1[key], _2[key]) }
      pairs.empty? ? 0.0 : pairs.sum / pairs.size
    end

    def harmful_features(ex) = ex[:setup_features] | ex[:assert_features] | ex[:fixture_features] | ex[:arrange_features]

    def matrix_base?(ex)
      d = Policy::DUPLICATION
      ex[:scrap] <= d[:matrix_max_scrap] && ex[:line_count] <= d[:matrix_max_lines] && ex[:assertions] <= d[:matrix_max_assertions] &&
        ex[:branches] <= d[:matrix_max_branches] && ex[:setup_depth] <= d[:matrix_max_setup_depth] &&
        ex[:with_redefs] <= d[:matrix_max_with_redefs] && ex[:temp_resources] <= d[:matrix_max_temp_resources] &&
        ex[:helper_hidden_lines] <= d[:matrix_max_helper_hidden_lines]
    end

    def few_subjects?(ex) = ex[:subject_symbols].size <= Policy::DUPLICATION[:matrix_max_subject_symbols]

    def extraction_matrix?(ex) = matrix_base?(ex) && (ex[:table_driven] || (few_subjects?(ex) && harmful_features(ex).any?))

    def summary_matrix?(ex)
      matrix_base?(ex) && (ex[:table_driven] || (few_subjects?(ex) && (ex[:assert_features].any? || ex[:arrange_features].any?)))
    end

    def coverage_matrix_count(exs)
      exs.count do |ex|
        summary_matrix?(ex) && (similar_to_any?(ex, exs, :setup_features) || similar_to_any?(ex, exs, :arrange_features) ||
                                (similar_to_any?(ex, exs, :assert_features) && similar_to_any?(ex, exs, :subject_symbols)))
      end
    end

    def components(exs)
      features = exs.map { harmful_features(_1) }
      adjacency = Hash.new { |h, k| h[k] = Set.new }
      exs.each_index.to_a.combination(2).each do |i, j|
        next unless jaccard(features[i], features[j]) >= Policy::DUPLICATION[:threshold]
        adjacency[i] << j
        adjacency[j] << i
      end
      seen = Set.new
      exs.each_index.filter_map do |start|
        next if seen.include?(start)
        component = reachable(start, adjacency)
        seen.merge(component)
        component.sort.map { exs[_1] } if component.size > 1
      end
    end

    def reachable(start, adjacency)
      component = Set.new
      stack = [start]
      until stack.empty?
        i = stack.pop
        next if component.include?(i)
        component << i
        stack.concat(adjacency[i].to_a)
      end
      component
    end

    def extraction(cluster)
      sets = cluster.map { harmful_features(_1) }
      shared = sets.reduce(:&).size
      variable = sets.reduce(:|).size - shared
      before = duplication_cost(shared, cluster.size, variable)
      helper_cost = shared + variable
      { examples: cluster.map { _1.slice(:name, :line, :end_line) }, line_start: cluster.map { _1[:line] }.min,
        line_end: cluster.map { _1[:end_line] }.max, instances: cluster.size, shared_forms: shared,
        variable_points: variable, duplication_before: before.round(2), helper_cost:,
        net_benefit: [0.0, before - helper_cost].max.round(2) }
    end
  end
end
