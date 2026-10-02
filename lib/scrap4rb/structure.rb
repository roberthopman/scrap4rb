require_relative "syntax"

module Scrap4rb
  module Structure
    include Syntax
    extend self

    INSIDE_TEST_ERRORS = %i[test it specify setup teardown before after describe context].to_set

    def errors(result)
      parse_errors(result) + nesting_errors(result.value) + duplicate_name_errors(result.value)
    end

    def parse_errors(result) = result.errors.map { "ERROR line #{_1.location.start_line}: parse error: #{_1.message}" }

    def nesting_errors(node, parent = nil, out = [])
      if parent && misplaced?(node)
        label = node.is_a?(Prism::ClassNode) ? "class" : node.name
        out << "ERROR line #{node.location.start_line}: (#{label}) inside (#{parent[:form]}) at line #{parent[:line]}"
      end
      inner = test_node?(node) ? { form: node.is_a?(Prism::DefNode) ? "def #{node.name}" : node.name, line: node.location.start_line } : parent
      kids(node).each { nesting_errors(_1, inner, out) }
      out
    end

    def misplaced?(node)
      test_node?(node) || (bare_call?(node) && INSIDE_TEST_ERRORS.include?(node.name) && node.block) ||
        node.is_a?(Prism::ClassNode) || (node.is_a?(Prism::DefNode) && node.name == :setup)
    end

    def duplicate_name_errors(tree)
      scopes = [tree] + descendants(tree).select { _1.is_a?(Prism::ClassNode) || (call?(_1) && BLOCK_CALLS.include?(_1.name)) }
      scopes.flat_map do |scope|
        body = scope.is_a?(Prism::ProgramNode) ? scope.statements.body : (scope_children(scope)&.last || [])
        body.select { test_node?(_1) }.group_by { method_name_of(_1) }.filter_map do |name, nodes|
          next if nodes.size < 2
          "ERROR line #{nodes.last.location.start_line}: #{name} is defined again; line #{nodes.first.location.start_line} never runs"
        end
      end
    end
  end
end
