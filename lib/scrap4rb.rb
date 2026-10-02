require_relative "scrap4rb/version"
require "prism"
require "set"
require "json"
require "digest"
require "fileutils"

module Scrap4rb
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

  ASSERTION = /\A(assert|refute|must_|wont_)/
  CONTEXT_CALLS = %i[travel_to travel freeze_time within within_frame using_session perform_enqueued_jobs].to_set
  STUB_CALLS = %i[stub stub_request any_instance expects stubs stub_const].to_set
  TABLE_CALLS = %i[each each_with_index each_pair each_with_object each_slice map flat_map times all? any? none?].to_set
  BRANCH_NODES = [Prism::IfNode, Prism::UnlessNode, Prism::CaseNode, Prism::CaseMatchNode, Prism::WhileNode,
                  Prism::UntilNode, Prism::AndNode, Prism::OrNode, Prism::RescueNode, Prism::RescueModifierNode].freeze
  TEST_CALLS = %i[test it specify].to_set
  BLOCK_CALLS = %i[describe context].to_set
  SETUP_CALLS = %i[setup before].to_set
  INSIDE_TEST_ERRORS = %i[test it specify setup teardown before after describe context].to_set
  SHARED_HELPER_GLOBS = %w[test/test_helper.rb test/application_system_test_case.rb test/test_helpers/**/*.rb test/support/**/*.rb].freeze

  module_function

  # ---------- AST helpers ----------

  def kids(node) = node.compact_child_nodes
  def call?(node) = node.is_a?(Prism::CallNode)
  def bare_call?(node) = call?(node) && node.receiver.nil?
  def lines_of(node) = node.location.end_line - node.location.start_line + 1

  def statements(body)
    case body
    when nil then []
    when Prism::StatementsNode then body.body
    when Prism::BeginNode then body.statements&.body || []
    else [body]
    end
  end

  def block_body(call) = call.block.is_a?(Prism::BlockNode) ? statements(call.block.body) : []

  def context_head?(node)
    return false unless call?(node) && node.block.is_a?(Prism::BlockNode)
    CONTEXT_CALLS.include?(node.name) || node.name.start_with?("with_") || node.name == :stub
  end

  def stub_call?(node)
    call?(node) && (STUB_CALLS.include?(node.name) ||
                    (node.name == :new && node.receiver&.slice == "Minitest::Mock"))
  end

  def assertion?(node) = call?(node) && ASSERTION.match?(node.name)

  def table_literal?(node)
    case node
    when Prism::ArrayNode then node.elements.size >= 2 && node.elements.all? { _1.is_a?(Prism::ArrayNode) || _1.is_a?(Prism::HashNode) }
    when Prism::HashNode then node.elements.size >= 2
    else false
    end
  end

  def table_driven_form?(node)
    return false unless call?(node)
    (TABLE_CALLS.include?(node.name) && node.block && table_literal?(node.receiver)) ||
      (assertion?(node) && (node.arguments&.arguments || []).any? { table_literal?(_1) })
  end

  def temp_resource?(node)
    return true if node.is_a?(Prism::XStringNode) || node.is_a?(Prism::InterpolatedXStringNode)
    return false unless call?(node)
    recv = node.receiver&.slice
    %i[mktmpdir tmpdir system spawn fork].include?(node.name) ||
      recv == "Tempfile" || recv == "Thread" ||
      (recv == "File" && %i[write binwrite].include?(node.name)) ||
      (recv == "FileUtils")
  end

  def large_literal?(node)
    case node
    when Prism::StringNode, Prism::InterpolatedStringNode
      node.opening_loc&.slice&.start_with?("<<") && node.slice.lines.size > 5
    when Prism::HashNode, Prism::KeywordHashNode, Prism::ArrayNode then node.elements.size > 10
    else false
    end
  end

  def control_call?(node)
    assertion?(node) || context_head?(node) || stub_call?(node) || TABLE_CALLS.include?(node.name) ||
      TEST_CALLS.include?(node.name) || SETUP_CALLS.include?(node.name) || !node.name.match?(/\A[a-z_]/i)
  end

  # ---------- metrics (example_node.clj) ----------

  EMPTY = { assertions: 0, branches: 0, table_branches: 0, with_redefs: 0, helper_calls: 0, helper_hidden_lines: 0,
            temp_resources: 0, large_literals: 0, max_setup_depth: 0, subject_symbols: Set.new.freeze, table_driven: false }.freeze

  def combine(*metrics)
    metrics.reduce(EMPTY) do |acc, m|
      {
        assertions: acc[:assertions] + m.fetch(:assertions, 0),
        branches: acc[:branches] + m.fetch(:branches, 0),
        table_branches: acc[:table_branches] + m.fetch(:table_branches, 0),
        with_redefs: acc[:with_redefs] + m.fetch(:with_redefs, 0),
        helper_calls: acc[:helper_calls] + m.fetch(:helper_calls, 0),
        helper_hidden_lines: acc[:helper_hidden_lines] + m.fetch(:helper_hidden_lines, 0),
        temp_resources: acc[:temp_resources] + m.fetch(:temp_resources, 0),
        large_literals: acc[:large_literals] + m.fetch(:large_literals, 0),
        max_setup_depth: [acc[:max_setup_depth], m.fetch(:max_setup_depth, 0)].max,
        subject_symbols: acc[:subject_symbols] | m.fetch(:subject_symbols, Set.new),
        table_driven: acc[:table_driven] || m.fetch(:table_driven, false)
      }
    end
  end

  Context = Struct.new(:helpers, :shared_assert_helpers, :cache)

  def analyze(node, ctx, depth, stack)
    helper = bare_call?(node) && ctx.helpers.key?(node.name)
    shared_assert = bare_call?(node) && !helper && ctx.shared_assert_helpers.include?(node.name)
    next_depth = context_head?(node) ? depth + 1 : depth
    children = kids(node).map { analyze(_1, ctx, next_depth, stack) }
    expanded = helper && !stack.include?(node.name) ? expand(ctx, node.name, stack | [node.name], depth) : nil
    subject = if call?(node) && !helper && !control_call?(node)
                recv = node.receiver
                Set[recv.is_a?(Prism::ConstantReadNode) || recv.is_a?(Prism::ConstantPathNode) ? "#{recv.slice}.#{node.name}" : node.name.to_s]
              else
                Set.new
              end
    local = {
      assertions: assertion?(node) || shared_assert ? 1 : 0,
      branches: BRANCH_NODES.any? { node.is_a?(_1) } ? 1 : 0,
      table_branches: call?(node) && TABLE_CALLS.include?(node.name) && node.block ? 1 : 0,
      with_redefs: stub_call?(node) ? 1 : 0,
      helper_calls: helper ? 1 : 0,
      temp_resources: temp_resource?(node) ? 1 : 0,
      large_literals: large_literal?(node) ? 1 : 0,
      max_setup_depth: depth,
      subject_symbols: subject,
      table_driven: table_driven_form?(node)
    }
    combine(local, *children, *[expanded].compact)
  end

  def expand(ctx, name, stack, depth)
    ctx.cache[[name, depth]] ||= begin
      body = ctx.helpers[name]
      hidden = body.sum { [1, lines_of(_1)].max }
      combine({ helper_hidden_lines: hidden }, *body.map { analyze(_1, ctx, depth, stack) })
    end
  end

  def top_forms(body)
    forms = body
    forms = block_body(forms.first) while forms.size == 1 && context_head?(forms.first)
    forms
  end

  def phase(form, ctx)
    return :setup if context_head?(form)
    analyze(form, ctx, 0, Set.new)[:assertions].positive? ? :assert : :action
  end

  def assertion_clusters(forms, ctx) = forms.map { phase(_1, ctx) }.chunk_while { _1 == _2 }.count { _1.first == :assert }

  # ---------- normalize.clj ----------

  def shape(node)
    case node
    when nil then nil
    when Prism::StringNode, Prism::InterpolatedStringNode, Prism::XStringNode, Prism::InterpolatedXStringNode then :string
    when Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode then :number
    when Prism::TrueNode, Prism::FalseNode then :boolean
    when Prism::NilNode then :nil
    when Prism::SymbolNode then :"#{node.unescaped}"
    when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode, Prism::ConstantReadNode,
         Prism::ConstantPathNode, Prism::SelfNode, Prism::ItLocalVariableReadNode then :sym
    when Prism::HashNode, Prism::KeywordHashNode then [:hash, *node.elements.map { shape(_1) }.sort_by(&:inspect)]
    when Prism::AssocNode then [shape(node.key), shape(node.value)]
    when Prism::ArrayNode then [:vec, *node.elements.map { shape(_1) }]
    when Prism::CallNode then [:sym, *[node.receiver, node.arguments, node.block].compact.map { shape(_1) }]
    when Prism::ArgumentsNode then node.arguments.map { shape(_1) }
    when Prism::StatementsNode then node.body.map { shape(_1) }
    when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode then [:assign, :sym, shape(node.value)]
    else [node.type, *kids(node).map { shape(_1) }]
    end
  end

  def signature(value) = value.inspect

  def shape_features(value, acc = Set.new)
    acc << signature(value)
    value.each { shape_features(_1, acc) } if value.is_a?(Array)
    acc
  end

  def form_features(forms) = forms.each_with_object(Set.new) { |f, acc| shape_features(shape(f), acc) }
  def form_signatures(forms) = forms.map { signature(shape(_1)) }

  def large_literal_signatures(node)
    own = large_literal?(node) ? [signature(shape(node))] : []
    own + kids(node).flat_map { large_literal_signatures(_1) }
  end

  # ---------- example_score.clj ----------

  def saturating(complexity)
    return COMPLEXITY[:floor] if complexity <= 1
    COMPLEXITY[:floor] + (COMPLEXITY[:cap] - COMPLEXITY[:floor]) * (1.0 - Math.exp(-COMPLEXITY[:rise_rate] * (complexity - 1)))
  end

  def api_contract?(m, line_count, phases)
    m[:assertions] <= 2 && m[:branches] + m[:table_branches] <= 4 && m[:table_branches] <= 1 &&
      m[:with_redefs] <= 0 && m[:helper_calls] <= 1 && m[:helper_hidden_lines] <= 0 && m[:temp_resources] <= 0 &&
      m[:large_literals] <= 0 && m[:subject_symbols].size <= 4 && phases <= 1 && line_count <= 18
  end

  def smells(m, line_count, phases, table_driven, api_contract)
    [
      [m[:assertions].zero?, "no-assertions", 10],
      [m[:assertions] == 1 && line_count > 10 && !table_driven && !api_contract, "low-assertion-density", 6],
      [phases > 1, "multiple-phases", 5],
      [m[:with_redefs] > 3, "high-mocking", 4],
      [line_count > 20 && !api_contract, "large-example", 4],
      [m[:temp_resources].positive?, "temp-resource-work", 3],
      [m[:large_literals].positive?, "literal-heavy-setup", 3],
      [m[:helper_hidden_lines] > 8, "helper-hidden-complexity", 4]
    ].select(&:first).map { { label: _2, penalty: _3 } }
  end

  def score_example(name:, node:, body:, ctx:, inherited_setup:, describe_path:)
    m = combine(*body.map { analyze(_1, ctx, inherited_setup.size, Set.new) })
    raw_lines = lines_of(node)
    line_count = raw_lines + m[:helper_hidden_lines]
    forms = top_forms(body)
    phases = assertion_clusters(forms, ctx)
    api = api_contract?(m, line_count, phases)
    setup_depth = api ? [0, m[:max_setup_depth] - 2].max : m[:max_setup_depth]
    branch_penalty = m[:table_driven] ? m[:table_branches] : m[:branches] + m[:table_branches]
    branch_penalty = [0, branch_penalty - 2].max if api
    found = smells(m, line_count, phases, m[:table_driven], api)
    complexity_score = saturating(1 + branch_penalty + setup_depth + m[:helper_calls])

    local_setup = forms.select { context_head?(_1) }
    setup = inherited_setup + local_setup
    asserts = forms.select { phase(_1, ctx) == :assert }
    arrange = forms.reject { phase(_1, ctx) == :assert }
    setup_signatures = form_signatures(setup)
    {
      name:, describe_path:, line: node.location.start_line, end_line: node.location.end_line,
      line_count:, raw_line_count: raw_lines, assertions: m[:assertions],
      branches: m[:branches] + m[:table_branches], setup_depth: m[:max_setup_depth], with_redefs: m[:with_redefs],
      helper_calls: m[:helper_calls], helper_hidden_lines: m[:helper_hidden_lines], temp_resources: m[:temp_resources],
      table_driven: m[:table_driven], api_contract: api, phases:,
      complexity: 1 + m[:branches] + m[:max_setup_depth] + m[:helper_calls] + m[:helper_hidden_lines] / 8,
      complexity_score: complexity_score.round(2),
      subject_symbols: m[:subject_symbols],
      assert_signatures: form_signatures(asserts), assert_features: form_features(asserts),
      setup_signatures:, setup_features: form_features(setup),
      arrange_signatures: form_signatures(arrange), arrange_features: form_features(arrange),
      literal_signatures: body.flat_map { large_literal_signatures(_1) },
      fixture_features: setup_signatures.empty? ? Set.new : shape_features(setup_signatures.map { :string }.unshift(:vec)),
      scrap: (complexity_score + found.sum { _1[:penalty] }).round(2),
      smells: found.map { _1[:label] }
    }.tap { _1[:literal_features] = _1[:literal_signatures].to_set }
  end

  # ---------- collection (example_collect.clj) and nesting errors (scan_nesting.clj) ----------

  def test_name(node)
    if node.is_a?(Prism::DefNode) then node.name.to_s
    else node.arguments&.arguments&.first.then { _1.respond_to?(:unescaped) ? _1.unescaped : _1&.slice.to_s }
    end
  end

  def test_node?(node)
    (node.is_a?(Prism::DefNode) && node.name.start_with?("test_")) ||
      (bare_call?(node) && TEST_CALLS.include?(node.name) && node.block.is_a?(Prism::BlockNode))
  end

  def test_body(node) = node.is_a?(Prism::DefNode) ? statements(node.body) : block_body(node)

  def setup_forms(scope_body)
    scope_body.flat_map do |n|
      if bare_call?(n) && SETUP_CALLS.include?(n.name) && n.block.is_a?(Prism::BlockNode) then block_body(n)
      elsif n.is_a?(Prism::DefNode) && n.name == :setup then statements(n.body).reject { bare_call?(_1) && _1.name == :super }
      else []
      end
    end
  end

  def scope_children(node)
    case node
    when Prism::ClassNode, Prism::ModuleNode then [node.constant_path.slice, statements(node.body)]
    when Prism::CallNode
      [test_name(node) || node.name.to_s, block_body(node)] if bare_call?(node) && BLOCK_CALLS.include?(node.name) && node.block
    end
  end

  def collect(forms, ctx, path = [], inherited = [], out = [])
    setup = inherited + setup_forms(forms)
    forms.each do |f|
      if (name, body = scope_children(f))
        collect(body, ctx, path + [name], setup, out)
      elsif test_node?(f)
        out << score_example(name: test_name(f), node: f, body: test_body(f), ctx:, inherited_setup: setup, describe_path: path)
      end
    end
    out
  end

  def structure_errors(result)
    errors = result.errors.map { "ERROR line #{_1.location.start_line}: parse error: #{_1.message}" }
    walk = lambda do |node, parent|
      if parent && (test_node?(node) || (bare_call?(node) && INSIDE_TEST_ERRORS.include?(node.name) && node.block) ||
                    node.is_a?(Prism::ClassNode) || (node.is_a?(Prism::DefNode) && node.name == :setup))
        label = node.is_a?(Prism::ClassNode) ? "class" : node.name
        errors << "ERROR line #{node.location.start_line}: (#{label}) inside (#{parent[:form]}) at line #{parent[:line]}"
      end
      inner = test_node?(node) ? { form: node.is_a?(Prism::DefNode) ? "def #{node.name}" : node.name, line: node.location.start_line } : parent
      kids(node).each { walk.(_1, inner) }
    end
    walk.(result.value, nil)
    scopes = [result.value] + descendants(result.value).select { _1.is_a?(Prism::ClassNode) || (call?(_1) && BLOCK_CALLS.include?(_1.name)) }
    scopes.each do |scope|
      body = scope.is_a?(Prism::ProgramNode) ? scope.statements.body : (scope_children(scope)&.last || [])
      body.select { test_node?(_1) }.group_by { method_name_of(_1) }.each do |name, nodes|
        next if nodes.size < 2
        errors << "ERROR line #{nodes.last.location.start_line}: #{name} is defined again; line #{nodes.first.location.start_line} never runs"
      end
    end
    errors
  end

  def method_name_of(node) = node.is_a?(Prism::DefNode) ? node.name.to_s : "test_#{test_name(node).to_s.gsub(/\s+/, "_")}"
  def descendants(node) = kids(node).flat_map { [_1, *descendants(_1)] }

  def helper_defs(tree)
    descendants(tree).select { _1.is_a?(Prism::DefNode) && !_1.name.start_with?("test_") && !%i[setup teardown].include?(_1.name) }
                     .to_h { [_1.name, statements(_1.body)] }
  end

  def shared_assert_helpers(root)
    SHARED_HELPER_GLOBS.flat_map { Dir[File.join(root, _1)] }.flat_map do |file|
      descendants(Prism.parse_file(file).value).select do |d|
        d.is_a?(Prism::DefNode) && descendants(d).any? { assertion?(_1) }
      end.map(&:name)
    end.to_set
  end

  # ---------- summary.clj and extraction_pressure.clj ----------

  def jaccard(a, b)
    union = (a || Set.new) | (b || Set.new)
    union.empty? ? 0.0 : ((a || Set.new) & (b || Set.new)).size.fdiv(union.size)
  end

  def similar_to_any?(ex, exs, key) = ex[key].any? && exs.any? { !_1.equal?(ex) && jaccard(ex[key], _1[key]) >= DUPLICATION[:threshold] }
  def similar_count(exs, key) = exs.count { similar_to_any?(_1, exs, key) }

  def average_similarity(exs, key)
    pairs = exs.combination(2).map { jaccard(_1[key], _2[key]) }
    pairs.empty? ? 0.0 : pairs.sum / pairs.size
  end

  def harmful_features(ex) = ex[:setup_features] | ex[:assert_features] | ex[:fixture_features] | ex[:arrange_features]

  def matrix_base?(ex)
    d = DUPLICATION
    ex[:scrap] <= d[:matrix_max_scrap] && ex[:line_count] <= d[:matrix_max_lines] && ex[:assertions] <= d[:matrix_max_assertions] &&
      ex[:branches] <= d[:matrix_max_branches] && ex[:setup_depth] <= d[:matrix_max_setup_depth] &&
      ex[:with_redefs] <= d[:matrix_max_with_redefs] && ex[:temp_resources] <= d[:matrix_max_temp_resources] &&
      ex[:helper_hidden_lines] <= d[:matrix_max_helper_hidden_lines]
  end

  def extraction_matrix?(ex)
    matrix_base?(ex) && (ex[:table_driven] || (ex[:subject_symbols].size <= DUPLICATION[:matrix_max_subject_symbols] && harmful_features(ex).any?))
  end

  def summary_matrix?(ex)
    matrix_base?(ex) && (ex[:table_driven] || (ex[:subject_symbols].size <= DUPLICATION[:matrix_max_subject_symbols] &&
                                               (ex[:assert_features].any? || ex[:arrange_features].any?)))
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
      next unless jaccard(features[i], features[j]) >= DUPLICATION[:threshold]
      adjacency[i] << j
      adjacency[j] << i
    end
    seen = Set.new
    exs.each_index.filter_map do |start|
      next if seen.include?(start)
      component = Set.new
      stack = [start]
      until stack.empty?
        i = stack.pop
        next if component.include?(i)
        component << i
        stack.concat(adjacency[i].to_a)
      end
      seen.merge(component)
      component.sort.map { exs[_1] } if component.size > 1
    end
  end

  def duplication_cost(shared, instances, variable)
    return 0.0 if shared <= 3 || variable > 4
    (shared - 3) * (instances - 1)**1.5 / (variable + 1)
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

  def summarize(exs)
    total = exs.size
    recs = components(exs).reject { |c| c.all? { extraction_matrix?(_1) } }.map { extraction(_1) }
                          .select { _1[:net_benefit].positive? }.sort_by { [_1[:line_start], -_1[:net_benefit]] }
    matrix = coverage_matrix_count(exs)
    dup = %i[setup assert fixture literal arrange].to_h { [_1, similar_count(exs, :"#{_1}_features")] }
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
      extraction_pressure_score: recs.sum { _1[:net_benefit] }.round(2),
      effective_duplication_score: recs.sum { _1[:net_benefit] }.round(2),
      recommended_extractions: recs
    }
  end

  # ---------- pressure_*.clj ----------

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
    w = PRESSURE[:weights]
    base = w[:avg_scrap] * s[:avg_scrap] + w[:max_scrap] * s[:max_scrap] +
           w[:effective_duplication_score] * s[:effective_duplication_score] +
           w[:low_assertion_ratio] * ratio(s[:low_assertion_examples], n) +
           w[:branching_ratio] * ratio(s[:branching_examples], n) +
           w[:with_redefs_ratio] * ratio(s[:with_redefs_examples], n) +
           w[:helper_hidden_ratio] * ratio(s[:helper_hidden_example_count], n)
    factor = PRESSURE[:size_factors].find { |up_to, _| up_to.nil? || n <= up_to }.last
    [0, factor * base - PRESSURE[:matrix_credit] * s[:case_matrix_repetition]].max.round(2)
  end

  def level(s)
    score = pressure_score(s)
    l = PRESSURE[:levels]
    if stable?(s) then "STABLE"
    elsif score >= l[:critical] then "CRITICAL"
    elsif score >= l[:high] then "HIGH"
    elsif score >= l[:medium] then "MEDIUM"
    else "LOW"
    end
  end

  def remediation_mode(s, blocks)
    sp = PRESSURE[:split]
    hot_blocks = blocks.count { %w[HIGH CRITICAL].include?(level(_1[:summary])) }
    split_pressure = s[:avg_scrap] >= sp[:avg_scrap] || s[:effective_duplication_score] >= sp[:effective_duplication_score] ||
                     s[:subject_repetition_score] >= sp[:subject_repetition_score] || s[:helper_hidden_example_count].positive?
    if stable?(s) then "STABLE"
    elsif s[:example_count] >= sp[:example_count] && (hot_blocks >= sp[:high_pressure_blocks] || s[:max_scrap] >= sp[:max_scrap]) && split_pressure
      "SPLIT"
    else "LOCAL"
    end
  end

  # ---------- actionability_*.clj ----------

  def ratios(s)
    n = s[:example_count]
    { low: ratio(s[:low_assertion_examples], n), zero: ratio(s[:zero_assertion_examples], n),
      branching: ratio(s[:branching_examples], n), mocking: ratio(s[:with_redefs_examples], n) }
  end

  def actionability(s, mode)
    r = ratios(s)
    m = ACTIONABILITY[:matrix]
    l = ACTIONABILITY[:local]
    harmful = s[:effective_duplication_score]
    matrix_heavy = s[:coverage_matrix_candidates].positive? &&
                   s[:case_matrix_repetition] >= [m[:min_case_matrix_repetition], (harmful / m[:effective_duplication_divisor]).floor].max &&
                   s[:max_scrap] <= m[:max_scrap] && r[:branching] <= m[:max_branching_ratio] && r[:mocking] < m[:max_mocking_ratio]
    local_safe = mode == "LOCAL" && (harmful.positive? || r[:zero].positive? || r[:low] > l[:low_assertion_ratio] || s[:max_scrap] > l[:max_scrap]) &&
                 r[:branching] <= l[:max_branching_ratio] && r[:mocking] < l[:max_mocking_ratio]
    if mode == "STABLE" then "LEAVE_ALONE"
    elsif matrix_heavy then "AUTO_TABLE_DRIVE"
    elsif local_safe then "AUTO_REFACTOR"
    elsif mode == "SPLIT" then "MANUAL_SPLIT"
    else "REVIEW_FIRST"
    end
  end

  def actions(s, mode)
    return [[3, "No refactor recommended; the file is structurally stable enough to leave alone."]] if mode == "STABLE"
    r = ratios(s)
    l = ACTIONABILITY[:local]
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
    ].select(&:first).map { _1.drop(1) }.sort_by { [-_1[0], _1[1]] }.first(ACTIONABILITY[:max_actions])
  end

  # ---------- analysis and report ----------

  def analyze_file(path, shared_asserts)
    src = File.read(path)
    result = Prism.parse(src)
    ctx = Context.new(helper_defs(result.value), shared_asserts, {})
    exs = collect(statements(result.value.statements), ctx)
    summary = summarize(exs)
    blocks = exs.group_by { _1[:describe_path] }.reject { |p, _| p.empty? }.map { |p, b| { path: p, summary: summarize(b) } }
    mode = remediation_mode(summary, blocks)
    { path:, content_hash: Digest::SHA256.hexdigest(src)[0, 16], errors: structure_errors(result), examples: exs, summary:,
      file_score: pressure_score(summary), level: level(summary), mode:, ai: actionability(summary, mode),
      actions: actions(summary, mode) }
  end

  LABEL = { 3 => "HIGH", 2 => "MEDIUM", 1 => "LOW" }.freeze

  def print_report(r, verbose:)
    s = r[:summary]
    puts "\n#{r[:path]}"
    r[:errors].each { puts "  #{_1}" }
    puts "  score #{r[:file_score]} #{r[:level]}  mode #{r[:mode]}  ai #{r[:ai]}  tests=#{s[:example_count]} avg=#{s[:avg_scrap]} max=#{s[:max_scrap]}"
    r[:actions].each { |c, t| puts "  #{LABEL[c].ljust(6)} #{t}" }
    worst = r[:examples].sort_by { -_1[:scrap] }
    worst = worst.first(5) unless verbose
    worst.each do |e|
      extra = verbose ? "  [a=#{e[:assertions]} b=#{e[:branches]} d=#{e[:setup_depth]} stub=#{e[:with_redefs]} h=#{e[:helper_calls]} hh=#{e[:helper_hidden_lines]} ph=#{e[:phases]}#{" table" if e[:table_driven]}#{" api" if e[:api_contract]}]" : ""
      puts format("  %5.1f  L%-4d %-58s %s%s", e[:scrap], e[:line], e[:name].to_s[0, 58], e[:smells].join(","), extra)
    end
    s[:recommended_extractions].each do |x|
      puts "  EXTRACT L#{x[:line_start]}-#{x[:line_end]} net=#{x[:net_benefit]} (I=#{x[:instances]} shared=#{x[:shared_forms]} variable=#{x[:variable_points]}): " +
           x[:examples].map { _1[:name].to_s[0, 40] }.join(" | ")
    end
  end

  def compare(baseline, reports)
    before = baseline["reports"].to_h { [_1["path"], _1["summary"].transform_keys(&:to_sym)] }
    reports.filter_map do |r|
      b = before[r[:path]] or next
      a = r[:summary]
      cmp = { file_score_delta: (pressure_score(a) - pressure_score(b)).round(2),
              max_scrap_delta: (a[:max_scrap] - b[:max_scrap]).round(2),
              extraction_pressure_delta: (a[:effective_duplication_score] - b[:effective_duplication_score]).round(2),
              case_matrix_delta: a[:case_matrix_repetition] - b[:case_matrix_repetition],
              helper_hidden_delta: a[:helper_hidden_example_count] - b[:helper_hidden_example_count] }
      [r[:path], cmp.merge(verdict: verdict(cmp))]
    end
  end

  def verdict(c)
    if c[:file_score_delta] <= -5 && c[:extraction_pressure_delta] <= 0 && c[:max_scrap_delta] <= 0 then "improved"
    elsif c[:helper_hidden_delta].positive? && c[:extraction_pressure_delta] >= 0 && c[:case_matrix_delta] <= 0 then "worse"
    elsif c[:extraction_pressure_delta].positive? || c[:max_scrap_delta].positive? || c[:file_score_delta] >= 5 then "worse"
    elsif c[:file_score_delta].zero? then "unchanged"
    else "mixed"
    end
  end

  def json_safe(value)
    case value
    when Set then value.to_a
    when Hash then value.to_h { [_1, json_safe(_2)] }
    when Array then value.map { json_safe(_1) }
    else value
    end
  end

  def main(argv)
    opts = { all: argv.delete("--all"), verbose: argv.delete("--verbose"), json: argv.delete("--json") }
    if (i = argv.index("--write-baseline")) then opts[:write] = argv.slice!(i, 2).last end
    if (i = argv.index("--compare")) then opts[:compare] = argv.slice!(i, 2).last end
    paths = argv.empty? ? ["test"] : argv
    files = paths.flat_map { File.directory?(_1) ? Dir["#{_1}/**/*_test.rb"] : [_1] }.sort
    shared = shared_assert_helpers(Dir.pwd)
    reports = files.map { analyze_file(_1, shared) }

    if opts[:write]
      FileUtils.mkdir_p(File.dirname(opts[:write]))
      File.write(opts[:write], JSON.pretty_generate(version: 1, reports: reports.map { json_safe(_1.slice(:path, :content_hash, :summary)) }))
    end
    return puts(JSON.pretty_generate(json_safe(reports))) if opts[:json]

    reports.each { print_report(_1, verbose: opts[:verbose]) if opts[:all] || _1[:mode] != "STABLE" || _1[:errors].any? }
    if opts[:compare]
      puts "\nComparison with #{opts[:compare]}:"
      compare(JSON.parse(File.read(opts[:compare])), reports).each do |path, c|
        next if c[:verdict] == "unchanged"
        puts "  #{c[:verdict].ljust(9)} #{path}  #{c.except(:verdict).map { "#{_1}=#{_2}" }.join(" ")}"
        puts "            the refactor made it worse: revert it, or simplify the helpers" if c[:verdict] == "worse"
      end
    end
    exs = reports.flat_map { _1[:examples] }
    puts "\n#{files.size} files, #{exs.size} tests, #{reports.sum { _1[:errors].size }} structure errors"
    puts "modes:   " + reports.map { _1[:mode] }.tally.sort.map { "#{_1}=#{_2}" }.join(" ")
    puts "ai:      " + reports.map { _1[:ai] }.tally.sort.map { "#{_1}=#{_2}" }.join(" ")
    puts "levels:  " + reports.map { _1[:level] }.tally.sort.map { "#{_1}=#{_2}" }.join(" ")
    puts "smells:  " + exs.flat_map { _1[:smells] }.tally.sort_by { -_2 }.map { "#{_1}=#{_2}" }.join(" ")
    puts "extractions recommended: #{reports.sum { _1[:summary][:recommended_extraction_count] }}, " \
         "table-drive candidates: #{reports.sum { _1[:summary][:coverage_matrix_candidates] }}"
  end

  # ---------- self-check ----------

  def self_check
    analyze_src = lambda do |src|
      result = Prism.parse(src)
      ctx = Context.new(helper_defs(result.value), Set[:assert_card], {})
      [collect(statements(result.value.statements), ctx).to_h { [_1[:name], _1] }, structure_errors(result)]
    end
    exs, errors = analyze_src.(<<~RUBY)
      class T < Minitest::Test
        setup { @x = 1 }
        test "empty" do
          foo
        end
        test "shared helper asserts" do
          assert_card
        end
        test "table" do
          [[5, 0], [6, 10]].each { |mm, eur| assert_equal eur, f(mm) }
        end
        test "two phases" do
          click
          assert_text "a"
          click
          assert_text "b"
        end
        test "unwrapped" do
          travel_to(1) do
            click
            assert_text "a"
          end
        end
        def build_it
          a = 1
          b = 2
          c = 3
          d = 4
          e = 5
          f = 6
          g = 7
          h = 8
          i = 9
        end
        test "hidden" do
          build_it
          assert true
        end
        test "nested" do
          test "inner" do
          end
        end
        def test_dup; end
        def test_dup; end
      end
    RUBY
    check = ->(cond, label) { raise "self-check failed: #{label}" unless cond }
    check.(exs["empty"][:smells].include?("no-assertions"), "no-assertions")
    check.(exs["shared helper asserts"][:assertions] == 1, "shared assert helper counts")
    check.(exs["table"][:table_driven], "table-driven")
    check.(exs["two phases"][:smells].include?("multiple-phases"), "multiple-phases")
    check.(exs["unwrapped"][:phases] == 1, "context wrapper unwrapped")
    check.(exs["hidden"][:helper_hidden_lines] == 9 && exs["hidden"][:smells].include?("helper-hidden-complexity"), "helper-hidden")
    check.(errors.any? { _1.include?("(test) inside (test)") }, "nested test error")
    check.(errors.any? { _1.include?("test_dup is defined again") }, "duplicate test error")
    check.(saturating(1) == 1.0 && saturating(2).round(3) == 4.954, "saturating curve")
    check.(duplication_cost(3, 5, 0).zero? && duplication_cost(5, 5, 5).zero? && duplication_cost(5, 5, 1) == 8.0, "duplication cost")
    check.(verdict(file_score_delta: -6, extraction_pressure_delta: 0, max_scrap_delta: 0, case_matrix_delta: 0, helper_hidden_delta: 0) == "improved", "verdict improved")
    check.(verdict(file_score_delta: -1, extraction_pressure_delta: 0, max_scrap_delta: 0, case_matrix_delta: 0, helper_hidden_delta: 1) == "worse", "verdict helper regression")
    puts "self-check ok"
  end
end

