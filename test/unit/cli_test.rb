require_relative "../test_helper"
require "scrap4rb"

class CLITest < Minitest::Test
  def printed(src)
    report = Scrap4rb::CLI.analyze_source("x_test.rb", src, Set.new)
    capture_io { Scrap4rb::CLI.print_report(report, verbose: false) }.first
  end

  def test_the_why_line_shows_the_ratios_behind_the_file_score
    out = printed(<<~RUBY)
      class T < Minitest::Test
        test("a") { X.stubs(:y); assert a; assert b }
        test("b") { X.stubs(:y); assert a; assert b }
        test("c") { d if c; assert a; assert b }
        test("d") { d if c; assert a; assert b }
        test("e") { d if c; assert a; assert b }
        test("f") { assert a }
      end
    RUBY
    assert_match(/^  why    low-assert=0\.17 branching=0\.50 mocking=0\.33 /, out)
  end

  def test_the_where_lines_rank_the_describe_blocks_by_refactor_pressure
    out = printed(<<~RUBY)
      describe Order do
        describe "calm" do
          it "is empty" do
            _(a).must_equal 1
          end
        end
        describe "messy" do
          it "saves" do
            save
          end
        end
      end
    RUBY
    where = out.lines.grep(/^  where /)
    assert_equal 2, where.size
    assert_match(%r{\A  where  Order / messy +\S+ +[\d.]+ +avg=11\.0 dup=0 +worst: saves \(11\.0\)}, where[0])
    assert_match(%r{\A  where  Order / calm }, where[1])
  end

  def test_a_file_with_one_block_has_no_where_line
    out = printed("class T < Minitest::Test\n  test \"a\" do\n    save\n  end\nend\n")
    refute_match(/^  where /, out)
    assert_match(/^  why /, out)
  end
end
