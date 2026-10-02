require_relative "../test_helper"
require "scrap4rb"

class StructureTest < Minitest::Test
  def errors(src) = Scrap4rb::Structure.errors(Prism.parse(src))

  def test_a_clean_file_has_no_errors
    assert_empty errors("class T\n  test \"a\" do\n    assert true\n  end\nend\n")
  end

  def test_a_test_inside_a_test_is_an_error
    assert_equal ["ERROR line 3: (test) inside (test) at line 2"],
                 errors("class T\n  test \"a\" do\n    test \"b\" do\n    end\n  end\nend\n")
  end

  def test_setup_teardown_describe_and_class_inside_a_test_are_errors
    src = "class T\n  test \"a\" do\n    setup { }\n    teardown { }\n    describe(\"x\") { }\n    class Inner; end\n  end\nend\n"
    assert_equal ["setup", "teardown", "describe", "class"], errors(src).map { _1[/\((\w+)\) inside/, 1] }
  end

  def test_a_second_def_with_the_same_test_name_is_an_error_because_the_first_never_runs
    src = "class T\n  def test_a\n  end\n  def test_a\n  end\nend\n"
    assert_equal ["ERROR line 4: test_a is defined again; line 2 never runs"], errors(src)
  end

  def test_the_same_name_in_two_classes_is_not_an_error
    assert_empty errors("class A\n  def test_a; end\nend\nclass B\n  def test_a; end\nend\n")
  end

  def test_a_parse_error_is_reported_with_its_line
    assert_match(/\AERROR line \d+: parse error:/, errors("class T\n  test \"a\" do\nend\n").first)
  end
end
