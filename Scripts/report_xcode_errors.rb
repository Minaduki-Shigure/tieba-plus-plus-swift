# frozen_string_literal: true

require "optparse"

options = { mode: "xcode", title: "Xcode", file: nil }
MAXIMUM_ANNOTATIONS = 10
# GitHub's public annotation API can truncate a large message at roughly 4 KiB.
# Bound even its workflow-command-escaped form and split the useful tail instead.
MAXIMUM_MESSAGE_BYTES = 3_500
MAXIMUM_TAIL_ANNOTATIONS = 3
OptionParser.new do |parser|
  parser.on("--mode MODE", %w[xcode full]) { |mode| options[:mode] = mode }
  parser.on("--title TITLE") { |title| options[:title] = title }
  parser.on("--file PATH") { |path| options[:file] = path }
end.parse!
log_path = ARGV.fetch(0)
abort "unexpected arguments: #{ARGV.drop(1).join(" ")}" unless ARGV.length == 1

def sanitize_log(value)
  # Strip terminal commands before matching diagnostics or constructing annotations.
  # OSC/DCS payloads may contain window titles, hyperlinks, or other terminal actions;
  # deleting just ESC would leave that payload mixed into the visible error text.
  value = value.gsub(/(?:\e\]|\u009D).*?(?:\a|\e\\|\u009C)/m, "")
  value = value.gsub(/(?:\e[PX^_]|[\u0090\u0098\u009E\u009F]).*?(?:\e\\|\u009C)/m, "")
  value = value.gsub(/(?:\e\[|\u009B)[0-?]*[ -\/]*[@-~]/, "")
  value = value.gsub(/\e[ -\/]*[0-~]/, "")
  # Newlines/tabs remain readable; CR is retained for workflow-command escaping.
  value.gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/, "")
end

content = sanitize_log(File.binread(log_path).force_encoding(Encoding::UTF_8).scrub)
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

def take_message_bytes(value, maximum_bytes:, from_end: false)
  characters = value.each_char
  characters = characters.to_a.reverse_each if from_end
  selected = []
  count = 0
  characters.each do |character|
    bytes = escape_command_message(character).bytesize
    break if count + bytes > maximum_bytes

    selected << character
    count += bytes
  end
  selected.reverse! if from_end
  selected.join
end

def bounded_message(value)
  return value if escape_command_message(value).bytesize <= MAXIMUM_MESSAGE_BYTES

  marker = "\n[long line shortened; beginning and end retained]\n"
  prefix = take_message_bytes(value, maximum_bytes: 1_000)
  suffix_budget = MAXIMUM_MESSAGE_BYTES - escape_command_message(prefix + marker).bytesize
  prefix + marker + take_message_bytes(value, maximum_bytes: suffix_budget, from_end: true)
end

def tail_messages(value)
  chunks = []
  current = +""
  bounded_tail(value).lines.each do |line|
    line = bounded_message(line)
    if !current.empty? && escape_command_message(current + line).bytesize > MAXIMUM_MESSAGE_BYTES
      chunks << current
      current = +""
    end
    current << line
  end
  chunks << current unless current.empty?
  chunks.last(MAXIMUM_TAIL_ANNOTATIONS)
end

def emit_error(title:, message:, file: nil)
  properties = ["title=#{escape_command_property(title)}"]
  properties << "file=#{escape_command_property(file)}" if file
  puts "::error #{properties.join(",")}::#{escape_command_message(bounded_message(message))}"
end

def emit_tail(title:, messages:, file: nil)
  # The newest information stays visible if a consumer caps the annotation count.
  messages.each_with_index.to_a.reverse_each do |message, index|
    part = messages.length > 1 ? " #{index + 1}/#{messages.length}" : ""
    emit_error(title: "#{title}#{part}", message: message, file: file)
  end
end

if options[:mode] == "full"
  emit_tail(
    title: options[:title],
    messages: tail_messages(content),
    file: options[:file]
  )
  exit
end

# These command lines usually contain no literal "error:". In a verbose build
# they are the only actionable clue after the generic "Testing failed" summary.
failed_commands_index = lines.rindex { |line| /the following build commands failed:/i.match?(line) }
failed_commands = if failed_commands_index
  commands = lines.drop(failed_commands_index + 1)
  end_index = commands.index { |line| /\(\d+ failures?\)/i.match?(line) }
  commands = commands.take(end_index + 1) if end_index
  ([lines[failed_commands_index]] + commands.reject(&:empty?).last(24))
    .map { |line| bounded_message(line) }
end

tail_lines = lines.last(100).reject do |line|
  # Preserve the same command in the final failure block; only discard ordinary
  # compile-progress noise from the otherwise bounded contextual tail.
  /\A(?:SwiftCompile|SwiftEmitModule|SwiftDriver|CompileSwiftSources)\b/.match?(line)
end
tails = tail_messages(tail_lines.join("\n"))
diagnostic_budget = MAXIMUM_ANNOTATIONS - tails.length - (failed_commands ? 1 : 0)
diagnostics = lines.select { |line| patterns.any? { |pattern| pattern.match?(line) } }
diagnostics = lines.last(40) if diagnostics.empty?
diagnostics = diagnostics.reject(&:empty?).uniq
# Keep source-located compiler/XCTest failures visible even when fixture decoder
# errors or LLVM profile-write warnings occur later in the same test run.
located = diagnostics.select { |line| /:\d+(?::\d+)?: error:/i.match?(line) }.last(diagnostic_budget)
selected = located + (diagnostics - located).last(diagnostic_budget - located.length)

if failed_commands
  emit_error(
    title: "#{options[:title]} failed commands",
    message: failed_commands.join("\n"),
    file: options[:file]
  )
end
diagnostics.select { |line| selected.include?(line) }.each do |line|
  emit_error(title: "#{options[:title]} diagnostic", message: line, file: options[:file])
end

emit_tail(
  title: "#{options[:title]} log tail",
  messages: tails,
  file: options[:file]
)
