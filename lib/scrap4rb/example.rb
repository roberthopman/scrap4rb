require_relative "syntax"
require_relative "policy"

module Scrap4rb
  module Example
    include Syntax
    extend self

    SHARED_HELPER_GLOBS = %w[test/test_helper.rb test/application_system_test_case.rb test/test_helpers/**/*.rb test/support/**/*.rb].freeze

    EMPTY = { assertions: 0, branches: 0, table_branches: 0, with_redefs: 0, helper_calls: 0, helper_hidden_lines: 0,
              temp_resources: 0, large_literals: 0, max_setup_depth: 0, subject_symbols: Set.new.freeze, table_driven: false }.freeze

    Context = Struct.new(:helpers, :shared_assert_helpers, :cache)

    def from_source(src, shared_assert_helpers:)
      from_tree(Prism.parse(src).value, shared_assert_helpers:)
    end

    def from_tree(tree, shared_assert_helpers:)
      collect(statements(tree.statements), Context.new(helper_defs(tree), shared_assert_helpers, {}))
    end

    def shared_assert_helpers(root)
      SHARED_HELPER_GLOBS.flat_map { Dir[File.join(root, _1)] }.flat_map do |file|
        descendants(Prism.parse_file(file).value).select do |d|
          d.is_a?(Prism::DefNode) && descendants(d).any? { assertion?(_1) }
        end.map(&:name)
      end.to_set
    end

    def saturating(complexity)
      c = Policy::COMPLEXITY
      return c[:floor] if complexity <= 1
      c[:floor] + (c[:cap] - c[:floor]) * (1.0 - Math.exp(-c[:rise_rate] * (complexity - 1)))
    end

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

    def analyze(node, ctx, depth, stack)
      helper = bare_call?(node) && ctx.helpers.key?(node.name)
      shared_assert = bare_call?(node) && !helper && ctx.shared_assert_helpers.include?(node.name)
      next_depth = context_head?(node) ? depth + 1 : depth
      children = kids(node).map { analyze(_1, ctx, next_depth, stack) }
      expanded = helper && !stack.include?(node.name) ? expand(ctx, node.name, stack | [node.name], depth) : nil
      local = {
        assertions: assertion?(node) || shared_assert ? 1 : 0,
        branches: BRANCH_NODES.any? { node.is_a?(_1) } ? 1 : 0,
        table_branches: call?(node) && TABLE_CALLS.include?(node.name) && node.block ? 1 : 0,
        with_redefs: stub_call?(node) ? 1 : 0,
        helper_calls: helper ? 1 : 0,
        temp_resources: temp_resource?(node) ? 1 : 0,
        large_literals: large_literal?(node) ? 1 : 0,
        max_setup_depth: depth,
        subject_symbols: subject_symbols(node, helper),
        table_driven: table_driven_form?(node)
      }
      combine(local, *children, *[expanded].compact)
    end

    def subject_symbols(node, helper)
      return Set.new unless call?(node) && !helper && !control_call?(node)
      recv = node.receiver
      constant = recv.is_a?(Prism::ConstantReadNode) || recv.is_a?(Prism::ConstantPathNode)
      Set[constant ? "#{recv.slice}.#{node.name}" : node.name.to_s]
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

    def score(name:, node:, body:, ctx:, inherited_setup:, describe_path:, table_driven: false)
      m = combine(*body.map { analyze(_1, ctx, inherited_setup.size, Set.new) }, { table_driven: })
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

      setup = inherited_setup + forms.select { context_head?(_1) }
      asserts = forms.select { phase(_1, ctx) == :assert }
      arrange = forms.reject { phase(_1, ctx) == :assert }
      setup_signatures = form_signatures(setup)
      literal_signatures = body.flat_map { large_literal_signatures(_1) }
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
        literal_signatures:,
        fixture_features: setup_signatures.empty? ? Set.new : shape_features(setup_signatures.map { :string }.unshift(:vec)),
        scrap: (complexity_score + found.sum { _1[:penalty] }).round(2),
        smells: found.map { _1[:label] },
        literal_features: literal_signatures.to_set
      }
    end

    def setup_forms(scope_body)
      scope_body.flat_map do |n|
        if bare_call?(n) && SETUP_CALLS.include?(n.name) && n.block.is_a?(Prism::BlockNode) then block_body(n)
        elsif n.is_a?(Prism::DefNode) && n.name == :setup then statements(n.body).reject { bare_call?(_1) && _1.name == :super }
        else []
        end
      end
    end

    def test_body(node) = node.is_a?(Prism::DefNode) ? statements(node.body) : block_body(node)

    def collect(forms, ctx, path = [], inherited = [], out = [])
      setup = inherited + setup_forms(forms)
      forms.each do |f|
        if (name, body = scope_children(f))
          collect(body, ctx, path + [name], setup, out)
        elsif test_node?(f)
          out << score(name: test_name(f), node: f, body: test_body(f), ctx:, inherited_setup: setup, describe_path: path)
        elsif (inner = dynamic_test_in_loop(f))
          out << score(name: dynamic_test_name(inner), node: f, body: block_body(inner), ctx:, inherited_setup: setup,
                       describe_path: path, table_driven: true)
        elsif dynamic_test?(f)
          out << score(name: dynamic_test_name(f), node: f, body: block_body(f), ctx:, inherited_setup: setup, describe_path: path)
        end
      end
      out
    end

    def helper_defs(tree)
      descendants(tree).select { _1.is_a?(Prism::DefNode) && !_1.name.start_with?("test_") && !%i[setup teardown].include?(_1.name) }
                       .to_h { [_1.name, statements(_1.body)] }
    end
  end
end
