#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "json"
require "rexml/security"
require "rexml/parsers/pullparser"

path = ARGV.fetch(0)

frames = {}
binaries = {}
threads = {}
weights = {}
states = {}
backtraces = {}
totals = Hash.new(0.0)
top_symbols = Hash.new(0.0)
top_binaries = Hash.new(0.0)
inclusive_symbols = Hash.new(0.0)
inclusive_binaries = Hash.new(0.0)
categories = Hash.new(0.0)

row = nil
in_backtrace = false
current_frame_id = nil
current_backtrace_id = nil
text_target = nil
text_value = +""

def decoded(value)
  CGI.unescapeHTML(value.to_s)
end

def classify_stack(entries)
  names = entries.map { |entry| entry[:name] }
  binary_names = entries.map { |entry| entry[:binary] }
  joined = names.join("\n")

  {
    "XCTest UI automation" => (
      binary_names.include?("XCTAutomationSupport") ||
        joined.match?(/\bXCT|XCTest|XCUIApplication|XCTElement/)
    ),
    "Accessibility semantics" => (
      binary_names.any? do |name|
        name.match?(/UIAccessibility|AXRuntime|AXCoreUtilities/)
      end || joined.match?(/[Aa]ccessibility|AXUIElement/)
    ),
    "SwiftUI layout and view graph" => (
      binary_names.include?("AttributeGraph") ||
        joined.match?(/sizeThatFits|LayoutEngine|LayoutComputer|StackLayout|LazyStack|ViewList|AG::Graph/)
    ),
    "Text shaping and measurement" => (
      binary_names.any? { |name| ["CoreText", "UIFoundation", "libicucore.A.dylib"].include?(name) } ||
        joined.match?(/Typesetter|CTLine|AttributedString\.measured|StyledTextLayout|ResolvedText|Text\.resolve/)
    ),
    "Scaled-text layout" => joined.include?("__NSScaledTextOversized"),
    "Fixed-size layout" => joined.include?("_FixedSizeLayout"),
    "Core Animation and drawing" => (
      binary_names.any? { |name| ["QuartzCore", "CoreGraphics"].include?(name) } ||
        joined.match?(/CA::Transaction|CA::Layer|CGContext/)
    ),
    "App implementation frames" => entries.any? do |entry|
      entry[:binary] == "TiebaPlusPlus" &&
        !entry[:name].match?(/TiebaPlusPlusApp\.\$main|\bmain\b/)
    end,
  }
end

File.open(path, "rb") do |file|
  parser = REXML::Parsers::PullParser.new(file)
  while parser.has_next?
    event = parser.pull
    if event.start_element?
      name = event[0]
      attributes = event[1]
      case name
      when "row"
        row = { thread_id: nil, weight_id: nil, weight: nil, state_id: nil, frames: [] }
      when "thread"
        next unless row

        if attributes["id"]
          threads[attributes["id"]] = decoded(attributes["fmt"])
          row[:thread_id] = attributes["id"]
        elsif attributes["ref"]
          row[:thread_id] = attributes["ref"]
        end
      when "weight"
        next unless row

        if attributes["id"]
          row[:weight_id] = attributes["id"]
          text_target = [:weight, attributes["id"]]
          text_value = +""
        elsif attributes["ref"]
          row[:weight_id] = attributes["ref"]
          row[:weight] = weights[attributes["ref"]]
        end
      when "thread-state"
        next unless row

        if attributes["id"]
          states[attributes["id"]] = decoded(attributes["fmt"])
          row[:state_id] = attributes["id"]
        elsif attributes["ref"]
          row[:state_id] = attributes["ref"]
        end
      when "backtrace"
        next unless row

        if attributes["ref"]
          row[:frames].concat(backtraces.fetch(attributes["ref"], []))
          current_backtrace_id = nil
        else
          current_backtrace_id = attributes["id"]
          backtraces[current_backtrace_id] = [] if current_backtrace_id
        end
        in_backtrace = true
      when "frame"
        next unless row && in_backtrace

        if attributes["ref"]
          frame_id = attributes["ref"]
          row[:frames] << frame_id
          backtraces[current_backtrace_id] << frame_id if current_backtrace_id
          current_frame_id = nil
        elsif attributes["id"]
          current_frame_id = attributes["id"]
          frames[current_frame_id] = {
            name: decoded(attributes["name"]),
            binary_id: nil,
          }
          row[:frames] << current_frame_id
          backtraces[current_backtrace_id] << current_frame_id if current_backtrace_id
        end
      when "binary"
        next unless current_frame_id

        binary_id = attributes["id"] || attributes["ref"]
        binaries[binary_id] = decoded(attributes["name"]) if attributes["id"]
        frames[current_frame_id][:binary_id] = binary_id
      end
    elsif event.text?
      text_value << event[0] if text_target
    elsif event.end_element?
      name = event[0]
      case name
      when "weight"
        if text_target&.first == :weight
          weight_id = text_target.last
          weights[weight_id] = text_value.to_f / 1_000_000.0
          row[:weight] = weights[weight_id] if row && row[:weight_id] == weight_id
        end
        text_target = nil
        text_value = +""
      when "frame"
        current_frame_id = nil
      when "backtrace"
        in_backtrace = false
        current_backtrace_id = nil
      when "row"
        next unless row

        weight = row[:weight] || weights[row[:weight_id]] || 1.0
        state = states[row[:state_id]].to_s
        thread = threads[row[:thread_id]].to_s
        entries = row[:frames].filter_map do |frame_id|
          frame = frames[frame_id]
          next unless frame

          { name: frame[:name], binary: binaries[frame[:binary_id]].to_s }
        end

        totals["all rows"] += 1
        totals["all weight ms"] += weight
        if thread.start_with?("Main Thread") && (state.empty? || state == "Running")
          totals["main rows"] += 1
          totals["main weight ms"] += weight
          if (top = entries.first)
            top_symbols[top[:name]] += weight
            top_binaries[top[:binary]] += weight
          end
          entries.map { |entry| entry[:name] }.uniq.each do |symbol|
            inclusive_symbols[symbol] += weight
          end
          entries.map { |entry| entry[:binary] }.reject(&:empty?).uniq.each do |binary|
            inclusive_binaries[binary] += weight
          end
          classify_stack(entries).each do |category, present|
            categories[category] += weight if present
          end
        end
        row = nil
      end
    end
  end
end

main_weight = totals["main weight ms"]
result = {
  source: File.basename(path),
  note: "Category weights are inclusive and may overlap.",
  totals: totals,
  categories: categories.sort_by { |_, value| -value }.to_h.transform_values do |value|
    {
      weight_ms: value,
      percent_of_main: main_weight.zero? ? 0 : value * 100 / main_weight,
    }
  end,
  top_symbols: top_symbols.sort_by { |_, value| -value }.first(30).to_h,
  top_binaries: top_binaries.sort_by { |_, value| -value }.first(20).to_h,
  inclusive_symbols: inclusive_symbols.sort_by { |_, value| -value }.first(160).to_h,
  inclusive_binaries: inclusive_binaries.sort_by { |_, value| -value }.first(30).to_h,
}

puts JSON.pretty_generate(result)
