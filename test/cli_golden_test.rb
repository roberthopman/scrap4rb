require_relative "test_helper"

class CLIGoldenTest < Minitest::Test
  CASES = {
    "default" => %w[test],
    "all" => %w[--all test],
    "verbose" => %w[--all --verbose test],
    "json" => %w[--json test],
    "single_file" => %w[test/models/smelly_test.rb]
  }.freeze

  def setup
    @dir = Dir.mktmpdir("scrap4rb-fixture")
    FileUtils.cp_r("#{FIXTURE}/.", @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  CASES.each do |name, args|
    define_method(:"test_#{name}") { assert_golden(name, run_cli(args)) }
  end

  def test_compare_after_write_baseline_reports_no_change
    run_cli(%w[--write-baseline baseline.json test])
    assert_golden("compare_unchanged", run_cli(%w[--compare baseline.json test]))
  end

  def test_compare_after_a_refactor_reports_the_verdict
    run_cli(%w[--write-baseline baseline.json test])
    smelly = File.join(@dir, "test/models/smelly_test.rb")
    File.write(smelly, File.read(smelly).sub("    record.save\n", "    record.save\n    assert record.persisted?\n"))
    assert_golden("compare_changed", run_cli(%w[--compare baseline.json test]))
  end

  private

  def run_cli(args)
    stdout, stderr, status = Open3.capture3(RUBY, "-I", LIB, EXE, *args, chdir: @dir)
    assert status.success?, "scrap4rb #{args.join(" ")} failed:\n#{stderr}"
    stdout
  end

  def assert_golden(name, output)
    golden = File.join(GOLDEN_DIR, "#{name}.txt")
    if ENV["UPDATE_GOLDEN"]
      File.write(golden, output)
      skip "wrote golden: #{name}"
    end
    assert File.exist?(golden), "missing golden #{name}; run UPDATE_GOLDEN=1 rake test"
    assert_equal File.read(golden), output, "golden mismatch for #{name}"
  end
end
