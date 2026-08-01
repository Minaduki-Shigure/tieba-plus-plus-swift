# frozen_string_literal: true

log_path = ARGV.fetch(0)
lines = File.readlines(log_path, chomp: true, encoding: "UTF-8")
patterns = [
  /error:/i,
  /fatal error:/i,
  /testing failed:/i,
  /build failed/i,
  /the following build commands failed:/i,
]

diagnostics = lines.select { |line| patterns.any? { |pattern| pattern.match?(line) } }
diagnostics = lines.last(40) if diagnostics.empty?

diagnostics.last(80).each do |line|
  escaped = line.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
  puts "::error title=Xcode diagnostic::#{escaped}"
end

exit 1
