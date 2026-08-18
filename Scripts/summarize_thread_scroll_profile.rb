#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "csv"

options = { analyses: [] }
OptionParser.new do |parser|
  parser.on("--metrics PATH") { |value| options[:metrics] = value }
  parser.on("--build-log PATH") { |value| options[:build_log] = value }
  parser.on("--xcode-log PATH") { |value| options[:xcode_log] = value }
  parser.on("--sample PATH") { |value| options[:sample] = value }
  parser.on("--xctrace-log PATH") { |value| options[:xctrace_log] = value }
  parser.on("--xctrace-toc PATH") { |value| options[:xctrace_toc] = value }
  parser.on("--xctrace-profile PATH") { |value| options[:xctrace_profile] = value }
  parser.on("--analysis LABEL=PATH") do |value|
    label, path = value.split("=", 2)
    abort "--analysis expects LABEL=PATH" unless label && path

    options[:analyses] << [label, path]
  end
  parser.on("--profile-plan PATH") { |value| options[:profile_plan] = value }
  parser.on("--profile-results PATH") { |value| options[:profile_results] = value }
  parser.on("--environment PATH") { |value| options[:environment] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!

abort "--output is required" unless options[:output]

def read_file(path, limit: nil)
  return nil unless path && File.file?(path)

  if limit
    value = File.binread(path, limit + 1)
    truncated = value.bytesize > limit
    value = value.byteslice(0, limit).to_s.force_encoding(Encoding::UTF_8).scrub
    return truncated ? "#{value}\n... truncated ..." : value
  end

  File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
end

def fenced(text, language: "text", limit: 24_000)
  value = text.to_s
  if value.bytesize > limit
    value = "#{value.byteslice(0, limit).to_s.scrub}\n... truncated ..."
  end
  "```#{language}\n#{value.rstrip}\n```"
end

def section(lines, start_pattern, end_pattern, limit: 100)
  start = lines.index { |line| line.match?(start_pattern) }
  return [] unless start

  selected = []
  lines.drop(start + 1).each do |line|
    break if line.match?(end_pattern)

    selected << line
    break if selected.length >= limit
  end
  selected
end

def mean(values)
  return nil if values.empty?

  values.sum(0.0) / values.length
end

def category_weight(analysis, name)
  analysis.dig("categories", name, "weight_ms").to_f
end

def percent_delta(control, candidate)
  return nil if control.zero?

  ((candidate - control) / control) * 100
end

profile_plan = if options[:profile_plan] && File.file?(options[:profile_plan])
                 CSV.read(options[:profile_plan], headers: true, col_sep: "\t")
               end
profile_results = if options[:profile_results] && File.file?(options[:profile_results])
                    CSV.read(options[:profile_results], headers: true, col_sep: "\t")
                  end

report = ["# Thread scroll performance profile", ""]

report << "## Scenarios"
report << ""
if profile_plan
  report << "This run performs two isolated Profile-only A/B comparisons. Each side is recorded " \
            "twice, and the order is reversed for the second replicate."
  report << ""
  report << "- `inline`: the candidate omits only `minimumScaleFactor(0.75)` from inline reply previews."
  report << "- `long`: the candidate omits only vertical `fixedSize` from 900-character plain text."
  report << ""
  report << "| Order | Profile | Comparison | Variant | Replicate | Scenario | Experiment |"
  report << "| ---: | --- | --- | --- | ---: | --- | --- |"
  profile_plan.each do |row|
    report << "| #{row['ordinal']} | `#{row['profile_id']}` | #{row['comparison']} | " \
              "#{row['variant']} | #{row['replicate']} | `#{row['scenario']}` | " \
              "`#{row['experiment']}` |"
  end
else
  report << "- `baseline`: 30 floors, about 120 CJK characters per floor."
  report << "- `long-plain-text`: 30 floors, one plain 900-character text block per floor."
  report << "- `inline-replies`: 30 floors, 120 characters and 4 retained inline replies per " \
            "floor; the production UI previews the first three."
  report << "- `many-floors`: 120 retained short-text floors, modeling four loaded pages; the " \
            "self-driven trace settles at floor 61 before measuring adjacent-floor scrolling."
end
report << ""
report << "All fixtures are deterministic and disable network media, pagination during measurement, " \
          "authenticated requests, history writes, and favorites writes."
report << ""

environment = read_file(options[:environment])
if environment
  report << "## Environment"
  report << ""
  report << fenced(environment, limit: 8_000)
  report << ""
end

parsed_analyses = {}
unless options[:analyses].empty?
  report << "## Self-driven Time Profiler analysis"
  report << ""
  report << "The app drives adjacent scroll targets itself, so these traces do not contain " \
            "XCUITest gesture or accessibility-snapshot work. Category weights are inclusive " \
            "and may overlap."
  report << ""
  options[:analyses].each do |label, path|
    analysis_contents = read_file(path)
    unless analysis_contents
      report << "### `#{label}`"
      report << ""
      report << "Analysis output was unavailable."
      report << ""
      next
    end
    analysis = JSON.parse(analysis_contents)
    parsed_analyses[label] = analysis
    main_weight = analysis.dig("totals", "main weight ms") || 0
    report << "### `#{label}`"
    report << ""
    report << "Main-thread running samples: **#{format('%.0f ms', main_weight)}**"
    report << ""
    report << "| Inclusive category | Weight | Main-thread share |"
    report << "| --- | ---: | ---: |"
    analysis.fetch("categories", {}).each do |category, values|
      report << "| #{category} | #{format('%.0f ms', values['weight_ms'])} | " \
                "#{format('%.1f%%', values['percent_of_main'])} |"
    end
    report << ""

    inclusive_symbols = analysis.fetch("inclusive_symbols", {})
    hotspot_groups = {
      "Layout/View Graph" => /(?:AG::Graph|ViewGraph|Layout|sizeThatFits|LazyStack)/,
      "Text" => /(?:ResolvedText|Text\.resolve|AttributedString|Typesetter|CTLine)/,
      "App" => /(?:ThreadView|PostView|BrowseContent|InlineComment|Reply)/,
    }
    hotspots = hotspot_groups.flat_map do |group, pattern|
      inclusive_symbols.select { |symbol, _| symbol.match?(pattern) }.first(7).map do |entry|
        [group, *entry]
      end
    end
    report << "| Group | Inclusive stack | Weight |"
    report << "| --- | --- | ---: |"
    hotspots.each do |group, symbol, weight|
      escaped_symbol = symbol.gsub("|", "\\|").gsub("`", "'")
      report << "| #{group} | `#{escaped_symbol}` | #{format('%.0f ms', weight)} |"
    end
    report << ""
  rescue JSON::ParserError => error
    report << "Analysis JSON for `#{label}` was invalid: `#{error.message}`"
    report << ""
  end
end

if profile_plan
  report << "## Paired A/B comparison"
  report << ""
  report << "Weights are inclusive sampled main-thread milliseconds and may overlap. Negative " \
            "deltas mean the candidate sampled less work. With two replicates, consistency is " \
            "descriptive only and is not a statistical significance claim."
  report << ""

  comparison_metrics = {
    "inline" => [
      ["Main-thread running", ->(analysis) { analysis.dig("totals", "main weight ms").to_f }],
      ["SwiftUI layout/view graph", ->(analysis) { category_weight(analysis, "SwiftUI layout and view graph") }],
      ["Text shaping/measurement", ->(analysis) { category_weight(analysis, "Text shaping and measurement") }],
      ["Core Animation/drawing", ->(analysis) { category_weight(analysis, "Core Animation and drawing") }],
      ["App implementation frames", ->(analysis) { category_weight(analysis, "App implementation frames") }],
      ["Scaled-text layout", ->(analysis) { category_weight(analysis, "Scaled-text layout") }],
    ],
    "long" => [
      ["Main-thread running", ->(analysis) { analysis.dig("totals", "main weight ms").to_f }],
      ["SwiftUI layout/view graph", ->(analysis) { category_weight(analysis, "SwiftUI layout and view graph") }],
      ["Text shaping/measurement", ->(analysis) { category_weight(analysis, "Text shaping and measurement") }],
      ["Core Animation/drawing", ->(analysis) { category_weight(analysis, "Core Animation and drawing") }],
      ["App implementation frames", ->(analysis) { category_weight(analysis, "App implementation frames") }],
      ["Fixed-size layout", ->(analysis) { category_weight(analysis, "Fixed-size layout") }],
    ],
  }

  comparison_metrics.each do |comparison, metrics|
    report << "### `#{comparison}`"
    report << ""
    report << "| Metric (ms) | Control r1 | Candidate r1 | Delta r1 | Control r2 | Candidate r2 | Delta r2 | Mean paired delta | Direction |"
    report << "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |"
    metrics.each do |metric_name, value_for|
      replicate_values = %w[1 2].map do |replicate|
        rows = profile_plan.select do |row|
          row.fetch("comparison") == comparison && row.fetch("replicate") == replicate
        end
        control_row = rows.find { |row| row.fetch("variant") == "control" }
        candidate_row = rows.find { |row| row.fetch("variant") == "candidate" }
        control = control_row && parsed_analyses[control_row.fetch("profile_id")]
        candidate = candidate_row && parsed_analyses[candidate_row.fetch("profile_id")]
        next unless control && candidate

        control_value = value_for.call(control)
        candidate_value = value_for.call(candidate)
        [control_value, candidate_value, percent_delta(control_value, candidate_value)]
      end

      deltas = replicate_values.filter_map { |values| values&.fetch(2) }
      direction = if deltas.length < 2
                    "incomplete"
                  elsif deltas.all?(&:negative?)
                    "both lower"
                  elsif deltas.all?(&:positive?)
                    "both higher"
                  elsif deltas.all?(&:zero?)
                    "both unchanged"
                  else
                    "mixed"
                  end
      formatted = replicate_values.flat_map do |values|
        next ["unavailable", "unavailable", "unavailable"] unless values

        control, candidate, delta = values
        [format("%.0f", control), format("%.0f", candidate), delta ? format("%+.1f%%", delta) : "n/a"]
      end
      paired_mean = mean(deltas)
      report << "| #{metric_name} | #{formatted[0]} | #{formatted[1]} | #{formatted[2]} | " \
                "#{formatted[3]} | #{formatted[4]} | #{formatted[5]} | " \
                "#{paired_mean ? format('%+.1f%%', paired_mean) : 'n/a'} | #{direction} |"
    end
    report << ""
  end

  if profile_results
    failures = profile_results.reject { |row| row.fetch("status") == "success" }
    unless failures.empty?
      report << "Incomplete recordings: #{failures.map { |row| row.fetch('profile_id') }.join(', ')}."
      report << ""
    end
  end
end

build_log = read_file(options[:build_log])
if build_log
  error_lines = build_log.lines.filter_map do |line|
    stripped = line.strip
    next if stripped.empty?
    next unless stripped.match?(
      /(?:error:|fatal error|BUILD FAILED|Undefined symbols|CodeSign|Testing failed)/i
    )

    stripped
  end.uniq.last(200)
  report << "## Profile build diagnostics"
  report << ""
  report << (error_lines.empty? ? "No compiler diagnostic lines were matched." : fenced(error_lines.join("\n"), limit: 16_000))
  report << ""
end

xcode_log = read_file(options[:xcode_log])
if xcode_log
  xcode_lines = xcode_log.lines
  metric_lines = xcode_lines.filter_map do |line|
    stripped = line.strip
    next if stripped.empty?
    next unless stripped.match?(
      /(?:measured|average:|Hitch|hitch|CPU|Memory|Clock|Wall Clock|standard deviation)/i
    )

    stripped
  end.uniq.last(160)
  report << "## XCTest console metrics"
  report << ""
  report << (metric_lines.empty? ? "No metric lines were found in xcodebuild output." : fenced(metric_lines.join("\n")))
  report << ""

  failure_lines = xcode_lines.filter_map do |line|
    stripped = line.strip
    next if stripped.empty?
    next unless stripped.match?(
      /(?:error:|Test (?:Case|Suite).* failed|with [1-9][0-9]* failures|TEST EXECUTE FAILED|XCTAssert|Failing tests:)/i
    )

    stripped
  end.uniq.last(160)
  unless failure_lines.empty?
    report << "### XCTest diagnostics"
    report << ""
    report << fenced(failure_lines.join("\n"), limit: 16_000)
    report << ""
  end
end

metrics = read_file(options[:metrics])
if metrics
  begin
    pretty_metrics = JSON.pretty_generate(JSON.parse(metrics))
    report << "## XCTest metrics JSON"
    report << ""
    report << fenced(pretty_metrics, language: "json", limit: 20_000)
    report << ""
  rescue JSON::ParserError => error
    report << "## XCTest metrics JSON"
    report << ""
    report << "Metrics export was not valid JSON: `#{error.message}`"
    report << ""
  end
end

xctrace_toc = read_file(options[:xctrace_toc])
if xctrace_toc
  report << "## Time Profiler table of contents"
  report << ""
  report << fenced(xctrace_toc, language: "xml", limit: 8_000)
  report << ""
end

xctrace_profile = read_file(options[:xctrace_profile], limit: 16_000)
if xctrace_profile
  report << "## Exported Time Profiler samples"
  report << ""
  report << "The full XML export is retained in the workflow artifact. This excerpt is for " \
            "checking the schema and first sampled rows."
  report << ""
  report << fenced(xctrace_profile, language: "xml", limit: 16_000)
  report << ""
end

sample = read_file(options[:sample])
if sample
  lines = sample.lines.map(&:rstrip)
  call_graph_lines = section(
    lines,
    /Call graph:/i,
    /Binary Images:/i,
    limit: 2_000
  )
  top_stacks = section(
    lines,
    /Sort by top of stack/i,
    /Binary Images:/i,
    limit: 120
  ).reject(&:empty?)
  framework_lines = call_graph_lines.filter do |line|
    line.match?(
      /(?:CoreText|TextKit|SwiftUI|AttributeGraph|CoreGraphics|QuartzCore|UIKitCore|layout|glyph|Typesetter|BrowseContentView|ThreadView|InlineComment)/i
    )
  end.uniq.first(160)
  report << "## Sampled call stacks"
  report << ""
  report << "### Top-of-stack summary"
  report << ""
  report << (top_stacks.empty? ? "The sample report had no top-of-stack section." : fenced(top_stacks.join("\n"), limit: 8_000))
  report << ""
  report << "### Rendering-related stack lines"
  report << ""
  report << (framework_lines.empty? ? "No rendering-related symbols were matched." : fenced(framework_lines.join("\n"), limit: 8_000))
  report << ""
end

xctrace_log = read_file(options[:xctrace_log])
if xctrace_log
  report << "## Time Profiler recorder"
  report << ""
  report << fenced(xctrace_log.lines.last(120).join, limit: 5_000)
  report << ""
end

report << "## Interpretation boundary"
report << ""
report << "These measurements come from an ephemeral GitHub-hosted iOS Simulator. " \
          "Use the fixed-window Time Profiler samples for call-stack attribution and same-run " \
          "scenario comparisons, not as " \
          "absolute iPhone frame-rate or LiveContainer results."
report << ""
report << "Programmatic scrolling exercises SwiftUI layout and rendering without a UI-test " \
          "driver, but it does not reproduce finger tracking or inertial deceleration. Absolute " \
          "hitch and frame-rate conclusions still require a physical device."
report << ""

File.write(options[:output], report.join("\n"))
