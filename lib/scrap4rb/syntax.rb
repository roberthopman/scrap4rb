require "prism"
require "set"

module Scrap4rb
  module Syntax
    ASSERTION = /\A(assert|refute|must_|wont_)/
    CONTEXT_CALLS = %i[travel_to travel freeze_time within within_frame using_session perform_enqueued_jobs].to_set
    STUB_CALLS = %i[stub stub_request any_instance expects stubs stub_const].to_set
    TABLE_CALLS = %i[each each_with_index each_pair each_with_object each_slice map flat_map times all? any? none?].to_set
    BRANCH_NODES = [Prism::IfNode, Prism::UnlessNode, Prism::CaseNode, Prism::CaseMatchNode, Prism::WhileNode,
                    Prism::UntilNode, Prism::AndNode, Prism::OrNode, Prism::RescueNode, Prism::RescueModifierNode].freeze
    TEST_CALLS = %i[test it specify].to_set
    BLOCK_CALLS = %i[describe context].to_set
    SETUP_CALLS = %i[setup before].to_set

    extend self

    def kids(node) = node.compact_child_nodes
    def descendants(node) = kids(node).flat_map { [_1, *descendants(_1)] }
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

    def test_node?(node)
      (node.is_a?(Prism::DefNode) && node.name.start_with?("test_")) ||
        (bare_call?(node) && TEST_CALLS.include?(node.name) && node.block.is_a?(Prism::BlockNode))
    end

    def test_name(node)
      if node.is_a?(Prism::DefNode) then node.name.to_s
      else node.arguments&.arguments&.first.then { _1.respond_to?(:unescaped) ? _1.unescaped : _1&.slice.to_s }
      end
    end

    def method_name_of(node) = node.is_a?(Prism::DefNode) ? node.name.to_s : "test_#{test_name(node).to_s.gsub(/\s+/, "_")}"

    def scope_children(node)
      case node
      when Prism::ClassNode, Prism::ModuleNode then [node.constant_path.slice, statements(node.body)]
      when Prism::CallNode
        [test_name(node) || node.name.to_s, block_body(node)] if bare_call?(node) && BLOCK_CALLS.include?(node.name) && node.block
      end
    end

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
  end
end
