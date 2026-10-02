require_relative "../test_helper"
require "scrap4rb"

class ExampleTest < Minitest::Test
  def examples(body, helpers: "", shared: Set.new)
    src = "class T < Minitest::Test\n#{body}\n#{helpers}\nend\n"
    Scrap4rb::Example.from_source(src, shared_assert_helpers: shared).to_h { [_1[:name], _1] }
  end

  def one(body, **opts) = examples("test \"x\" do\n#{body}\nend", **opts)["x"]

  def lines(n) = Array.new(n) { "step#{_1}(#{_1})" }.join("\n")

  def test_a_test_without_assertions_has_the_no_assertions_smell
    assert_includes one("save")[:smells], "no-assertions"
    refute_includes one("assert saved?")[:smells], "no-assertions"
  end

  def test_assert_refute_must_and_wont_all_count_as_assertions
    assert_equal 4, one("assert a\nrefute b\n_(c).must_equal 1\n_(d).wont_be_nil")[:assertions]
  end

  def test_a_shared_assertion_helper_counts_as_one_assertion_only_when_it_is_known
    assert_equal 1, one("assert_card 1", shared: Set[:assert_card])[:assertions]
    assert_equal 1, one("check_card 1", shared: Set[:check_card])[:assertions]
    assert_equal 0, one("check_card 1")[:assertions]
  end

  def test_low_assertion_density_starts_above_ten_lines_with_one_assertion
    ten = one("#{lines(7)}\nassert ok")
    eleven = one("#{lines(8)}\nassert ok")
    assert_equal [10, 11], [ten[:line_count], eleven[:line_count]]
    refute_includes ten[:smells], "low-assertion-density"
    assert_includes eleven[:smells], "low-assertion-density"
  end

  def test_large_example_starts_above_twenty_lines
    twenty = one("#{lines(15)}\nassert a\nassert b\nassert c")
    twenty_one = one("#{lines(16)}\nassert a\nassert b\nassert c")
    assert_equal [20, 21], [twenty[:line_count], twenty_one[:line_count]]
    refute_includes twenty[:smells], "large-example"
    assert_includes twenty_one[:smells], "large-example"
  end

  def test_high_mocking_starts_at_four_stubs
    three = one("stub_request(:get, \"a\")\nstub_request(:get, \"b\")\nm = Minitest::Mock.new\nassert m")
    four = one("stub_request(:get, \"a\")\nstub_request(:get, \"b\")\nm = Minitest::Mock.new\nX.stubs(:y)\nassert m")
    assert_equal [3, 4], [three[:with_redefs], four[:with_redefs]]
    refute_includes three[:smells], "high-mocking"
    assert_includes four[:smells], "high-mocking"
  end

  def test_helper_hidden_complexity_starts_above_eight_hidden_lines
    eight = one("build\nassert ok", helpers: "def build\n#{lines(8)}\nend")
    nine = one("build\nassert ok", helpers: "def build\n#{lines(9)}\nend")
    assert_equal [8, 9], [eight[:helper_hidden_lines], nine[:helper_hidden_lines]]
    refute_includes eight[:smells], "helper-hidden-complexity"
    assert_includes nine[:smells], "helper-hidden-complexity"
  end

  def test_a_helper_that_calls_itself_is_expanded_once
    ex = one("build\nassert ok", helpers: "def build\nbuild\nend")
    assert_equal 1, ex[:helper_hidden_lines]
  end

  def test_assert_act_assert_is_two_phases_and_a_context_wrapper_is_unwrapped
    assert_includes one("click\nassert_text \"a\"\nclick\nassert_text \"b\"")[:smells], "multiple-phases"
    assert_equal 1, one("travel_to(t) do\nclick\nassert_text \"a\"\nend")[:phases]
  end

  def test_a_heredoc_of_more_than_five_lines_is_literal_heavy_setup
    five = one("data = <<~TXT\n#{Array.new(5) { "l" }.join("\n")}\nTXT\nassert data")
    six = one("data = <<~TXT\n#{Array.new(6) { "l" }.join("\n")}\nTXT\nassert data")
    refute_includes five[:smells], "literal-heavy-setup"
    assert_includes six[:smells], "literal-heavy-setup"
  end

  def test_a_plain_string_of_more_than_five_lines_is_literal_heavy_setup
    refute_includes one("data = \"#{Array.new(5) { "l" }.join("\n")}\"\nassert data")[:smells], "literal-heavy-setup"
    assert_includes one("data = \"#{Array.new(6) { "l" }.join("\n")}\"\nassert data")[:smells], "literal-heavy-setup"
  end

  def test_a_hash_of_more_than_ten_pairs_is_literal_heavy_setup
    pairs = ->(n) { Array.new(n) { "k#{_1}: #{_1}" }.join(", ") }
    refute_includes one("h = { #{pairs.(10)} }\nassert h")[:smells], "literal-heavy-setup"
    assert_includes one("h = { #{pairs.(11)} }\nassert h")[:smells], "literal-heavy-setup"
  end

  def test_temporary_files_and_threads_are_temp_resource_work
    assert_includes one("Dir.mktmpdir { |d| assert d }")[:smells], "temp-resource-work"
    assert_includes one("Thread.new { }.join\nassert ok")[:smells], "temp-resource-work"
    refute_includes one("assert ok")[:smells], "temp-resource-work"
  end

  def test_a_loop_over_a_literal_table_is_table_driven_but_a_loop_over_a_variable_is_not
    assert one("[[5, 0], [6, 10]].each { |mm, eur| assert_equal eur, f(mm) }")[:table_driven]
    assert one("{ 5 => 0, 6 => 10 }.each { |mm, eur| assert_equal eur, f(mm) }")[:table_driven]
    refute one("cases.each { |mm, eur| assert_equal eur, f(mm) }")[:table_driven]
    refute one("[5, 6].each { |mm| assert f(mm) }")[:table_driven]
  end

  def test_branches_count_if_unless_case_and_boolean_operators
    assert_equal 4, one("if a then b end\nc unless d\ncase e when 1 then f end\nassert(g && h)")[:branches]
  end

  def test_setup_blocks_are_inherited_by_every_test_in_the_class
    exs = examples("setup do\n@a = 1\nend\ntest \"one\" do\nassert @a\nend\ntest \"two\" do\nassert @a\nend")
    assert(exs.values.all? { _1[:setup_signatures].size == 1 })
  end

  def test_def_test_methods_and_spec_it_blocks_are_collected_with_their_describe_path
    src = "describe Order do\n  it \"is empty\" do\n    _(1).must_equal 1\n  end\nend\n" \
          "class T < Minitest::Test\n  def test_plain\n    assert true\n  end\nend\n"
    exs = Scrap4rb::Example.from_source(src, shared_assert_helpers: Set.new)
    assert_equal [["is empty", ["Order"]], ["test_plain", ["T"]]], exs.map { [_1[:name], _1[:describe_path]] }
  end

  def test_the_complexity_curve_saturates_at_the_cap
    assert_equal 1.0, Scrap4rb::Example.saturating(1)
    assert_in_delta 4.954, Scrap4rb::Example.saturating(2), 0.001
    assert_in_delta 25.0, Scrap4rb::Example.saturating(200), 0.001
  end
end
