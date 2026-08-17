#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

options = {}
OptionParser.new do |parser|
  parser.on("--metrics PATH") { |value| options[:metrics] = value }
  parser.on("--build-log PATH") { |value| options[:build_log] = value }
  parser.on("--xcode-log PATH") { |value| options[:xcode_log] = value }
  parser.on("--sample PATH") { |value| options[:sample] = value }
  parser.on("--xctrace-log PATH") { |value| options[:xctrace_log] = value }
  parser.on("--xctrace-toc PATH") { |value| options[:xctrace_toc] = value }
  parser.on("--xctrace-profile PATH") { |value| options[:xctrace_profile] = value }
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

report = ["# Thread scroll performance profile", ""]

report << "## Scenarios"
report << ""
report << "- `baseline`: 30 floors, about 120 CJK characters per floor."
report << "- `long-plain-text`: 30 floors, one plain 900-character text block per floor."
report << "- `inline-replies`: 30 floors, 120 characters and 50 retained inline replies per " \
          "floor; the production UI previews the first three."
report << "- `many-floors`: 120 retained short-text floors, modeling four loaded pages at steady state."
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
          "Use them for call-stack attribution and same-run scenario comparisons, not as " \
          "absolute iPhone frame-rate or LiveContainer results."
report << ""
report << "Apple does not expose animation hitch count, hitch ratio, frame rate, or frame " \
          "count from XCTest signpost metrics on Simulator. The scrolling metric therefore " \
          "provides interval duration here; hitch and frame conclusions require a physical device."
report << ""

File.write(options[:output], report.join("\n"))
