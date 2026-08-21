# frozen_string_literal: true

require "optparse"

options = { mode: "xcode", title: "Xcode", file: nil }
OptionParser.new do |parser|
  parser.on("--mode MODE", %w[xcode full]) { |mode| options[:mode] = mode }
  parser.on("--title TITLE") { |title| options[:title] = title }
  parser.on("--file PATH") { |path| options[:file] = path }
end.parse!
log_path = ARGV.fetch(0)
abort "unexpected arguments: #{ARGV.drop(1).join(" ")}" unless ARGV.length == 1

content = File.binread(log_path).force_encoding(Encoding::UTF_8).scrub
lines = content.lines(chomp: true)
patterns = [
  /error:/i,
  /fatal error:/i,
  /testing failed:/i,
  /build failed/i,
  /the following build commands failed:/i,
]

def escape_command_message(value)
  value.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
end

def escape_command_property(value)
  escape_command_message(value).gsub(":", "%3A").gsub(",", "%2C")
end

def bounded_tail(value, maximum_bytes: 50_000)
  return value if value.bytesize <= maximum_bytes

  marker = "[truncated to the last #{maximum_bytes} bytes]\n"
  tail_bytes = value.b.byteslice(-(maximum_bytes - marker.bytesize), maximum_bytes)
  marker + tail_bytes.force_encoding(Encoding::UTF_8).scrub
end

def emit_error(title:, message:, file: nil)
  properties = ["title=#{escape_command_property(title)}"]
  properties << "file=#{escape_command_property(file)}" if file
  puts "::error #{properties.join(",")}::#{escape_command_message(message)}"
end

if options[:mode] == "full"
  emit_error(
    title: options[:title],
    message: bounded_tail(content),
    file: options[:file]
  )
  exit
end

diagnostics = lines.select { |line| patterns.any? { |pattern| pattern.match?(line) } }
diagnostics = lines.last(40) if diagnostics.empty?
diagnostics.reject(&:empty?).last(9).each do |line|
  emit_error(title: "#{options[:title]} diagnostic", message: line, file: options[:file])
end

emit_error(
  title: "#{options[:title]} log tail",
  message: bounded_tail(lines.last(100).join("\n")),
  file: options[:file]
)
