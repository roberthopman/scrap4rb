require "json"
require "digest"
require "fileutils"
require "optparse"
require_relative "example"
require_relative "structure"
require_relative "summary"
require_relative "judgment"

module Scrap4rb
  module CLI
    extend self

    LABEL = { 3 => "HIGH", 2 => "MEDIUM", 1 => "LOW" }.freeze

    def run(argv)
      opts = parse(argv)
      files = (argv.empty? ? ["test"] : argv).flat_map { File.directory?(_1) ? Dir["#{_1}/**/*_test.rb"] : [_1] }.sort
      shared = Example.shared_assert_helpers(Dir.pwd)
      reports = files.map { analyze_file(_1, shared) }
      write_baseline(opts[:write], reports) if opts[:write]
      return puts(JSON.pretty_generate(json_safe(reports))) if opts[:json]

      reports.each { print_report(_1, verbose: opts[:verbose]) if opts[:all] || _1[:mode] != "STABLE" || _1[:errors].any? }
      print_comparison(opts[:compare], reports) if opts[:compare]
      print_totals(files, reports)
    end

    def parse(argv)
      opts = {}
      OptionParser.new do |o|
        o.banner = "Usage: scrap4rb [options] [paths...]   (default path: test)"
        o.on("--all", "Show STABLE files too") { opts[:all] = true }
        o.on("--verbose", "Show per-test metrics") { opts[:verbose] = true }
        o.on("--json", "Print the full report as JSON") { opts[:json] = true }
        o.on("--write-baseline FILE", "Write a baseline document to FILE") { opts[:write] = _1 }
        o.on("--compare FILE", "Compare with a baseline document") { opts[:compare] = _1 }
        o.on("-v", "--version", "Show the version") { puts VERSION; exit }
        o.on("-h", "--help", "Show this help") { puts o; exit }
      end.parse!(argv)
      opts
    end

    def analyze_file(path, shared_asserts) = analyze_source(path, File.read(path), shared_asserts)

    def analyze_source(path, src, shared_asserts)
      result = Prism.parse(src)
      exs = Example.from_tree(result.value, shared_assert_helpers: shared_asserts)
      summary = Summary.summarize(exs)
      blocks = exs.group_by { _1[:describe_path] }.reject { |p, _| p.empty? }.map { |p, b| { path: p, summary: Summary.summarize(b), examples: b } }
      mode = Judgment.remediation_mode(summary, blocks)
      { path:, content_hash: Digest::SHA256.hexdigest(src)[0, 16], errors: Structure.errors(result), examples: exs, summary:,
        file_score: Judgment.pressure_score(summary), level: Judgment.level(summary), mode:,
        ai: Judgment.actionability(summary, mode), actions: Judgment.actions(summary, mode), top_blocks: top_blocks(blocks) }
    end

    def top_blocks(blocks)
      blocks.map do |b|
        worst = b[:examples].max_by { _1[:scrap] }
        { path: b[:path], score: Judgment.pressure_score(b[:summary]), level: Judgment.level(b[:summary]),
          avg_scrap: b[:summary][:avg_scrap], harmful_duplication_score: b[:summary][:harmful_duplication_score],
          worst: worst.slice(:name, :line, :scrap) }
      end.sort_by { -_1[:score] }.first(Policy::REPORT[:top_block_count])
    end

    def print_report(r, verbose:)
      s = r[:summary]
      puts "\n#{r[:path]}"
      r[:errors].each { puts "  #{_1}" }
      puts "  score #{r[:file_score]} #{r[:level]}  mode #{r[:mode]}  ai #{r[:ai]}  tests=#{s[:example_count]} avg=#{s[:avg_scrap]} max=#{s[:max_scrap]}"
      puts why_line(s)
      r[:actions].each { |c, t| puts "  #{LABEL[c].ljust(6)} #{t}" }
      r[:top_blocks].each { puts where_line(_1) } if r[:top_blocks].size > 1
      worst = r[:examples].sort_by { -_1[:scrap] }
      worst = worst.first(Policy::REPORT[:top_example_count]) unless verbose
      worst.each { puts example_line(_1, verbose) }
      s[:recommended_extractions].each do |x|
        puts "  EXTRACT L#{x[:line_start]}-#{x[:line_end]} net=#{x[:net_benefit]} (I=#{x[:instances]} shared=#{x[:shared_forms]} variable=#{x[:variable_points]}): " +
             x[:examples].map { _1[:name].to_s[0, 40] }.join(" | ")
      end
    end

    def why_line(s)
      r = Judgment.ratios(s)
      format("  why    low-assert=%.2f branching=%.2f mocking=%.2f helper-hidden=%d harmful-dup=%d extraction=%.1f matrix=%d subject-rep=%d",
             r[:low], r[:branching], r[:mocking], s[:helper_hidden_example_count], s[:harmful_duplication_score],
             s[:extraction_pressure_score], s[:coverage_matrix_candidates], s[:subject_repetition_score])
    end

    def where_line(b)
      format("  where  %s  %s %.1f  avg=%.1f dup=%d  worst: %s (%.1f)", b[:path].join(" / "), b[:level], b[:score],
             b[:avg_scrap], b[:harmful_duplication_score], b[:worst][:name], b[:worst][:scrap])
    end

    def example_line(e, verbose)
      extra = if verbose
                "  [a=#{e[:assertions]} b=#{e[:branches]} d=#{e[:setup_depth]} stub=#{e[:with_redefs]} h=#{e[:helper_calls]} " \
                  "hh=#{e[:helper_hidden_lines]} ph=#{e[:phases]}#{" table" if e[:table_driven]}#{" api" if e[:api_contract]}]"
              else
                ""
              end
      format("  %5.1f  L%-4d %-58s %s%s", e[:scrap], e[:line], e[:name].to_s[0, 58], e[:smells].join(","), extra)
    end

    def write_baseline(file, reports)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, JSON.pretty_generate(version: 1, reports: reports.map { json_safe(_1.slice(:path, :content_hash, :summary)) }))
    end

    def compare(baseline, reports)
      before = baseline["reports"].to_h { [_1["path"], _1["summary"].transform_keys(&:to_sym)] }
      reports.filter_map do |r|
        b = before[r[:path]] or next
        a = r[:summary]
        cmp = { file_score_delta: (Judgment.pressure_score(a) - Judgment.pressure_score(b)).round(2),
                max_scrap_delta: (a[:max_scrap] - b[:max_scrap]).round(2),
                extraction_pressure_delta: (a[:effective_duplication_score] - b[:effective_duplication_score]).round(2),
                case_matrix_delta: a[:case_matrix_repetition] - b[:case_matrix_repetition],
                helper_hidden_delta: a[:helper_hidden_example_count] - b[:helper_hidden_example_count],
                example_count_delta: a[:example_count] - b[:example_count] }
        [r[:path], cmp.merge(verdict: Judgment.verdict(cmp))]
      end
    end

    def print_comparison(file, reports)
      puts "\nComparison with #{file}:"
      compare(JSON.parse(File.read(file)), reports).each do |path, c|
        next if c[:verdict] == "unchanged"
        puts "  #{c[:verdict].ljust(9)} #{path}  #{c.except(:verdict).map { "#{_1}=#{_2}" }.join(" ")}"
        puts "            the refactor made it worse: revert it, or simplify the helpers" if c[:verdict] == "worse"
      end
    end

    def print_totals(files, reports)
      exs = reports.flat_map { _1[:examples] }
      tally = ->(values) { values.tally.sort.map { "#{_1}=#{_2}" }.join(" ") }
      puts "\n#{files.size} files, #{exs.size} tests, #{reports.sum { _1[:errors].size }} structure errors"
      puts "modes:   " + tally.(reports.map { _1[:mode] })
      puts "ai:      " + tally.(reports.map { _1[:ai] })
      puts "levels:  " + tally.(reports.map { _1[:level] })
      puts "smells:  " + exs.flat_map { _1[:smells] }.tally.sort_by { -_2 }.map { "#{_1}=#{_2}" }.join(" ")
      puts "extractions recommended: #{reports.sum { _1[:summary][:recommended_extraction_count] }}, " \
           "table-drive candidates: #{reports.sum { _1[:summary][:coverage_matrix_candidates] }}"
    end

    def json_safe(value)
      case value
      when Set then value.to_a
      when Hash then value.to_h { [_1, json_safe(_2)] }
      when Array then value.map { json_safe(_1) }
      else value
      end
    end
  end
end
