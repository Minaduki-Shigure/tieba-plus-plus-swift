# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tempfile"

class ReportXcodeErrorsTests < Minitest::Test
  def report(lines)
    Tempfile.create(["xcode-diagnostics", ".log"]) do |file|
      file.write(lines.join("\n"))
      file.flush
      output, status = Open3.capture2(
        RbConfig.ruby, File.join(__dir__, "report_xcode_errors.rb"), file.path
      )
      assert status.success?
      output.lines.grep(/title=Xcode diagnostic/)
    end
  end

  def test_test_failures_survive_later_fixture_and_profile_errors
    failure = 'App/Tests/Images.swift:521: error: -[Images testColor] : unsupportedOriginal'
    noise = 20.times.map { |index| "LLVM Profile Error: Cannot write profile #{index}" }
    annotations = report([failure] + noise)
    assert_equal 9, annotations.length
    assert_includes annotations.join, failure
    assert_includes annotations.join, noise.last
  end

  def test_compiler_errors_keep_column_and_remain_bounded
    failures = 12.times.map { |index| "App/Sources/Images.swift:#{index + 1}:5: error: invalid type" }
    annotations = report(failures + ["** BUILD FAILED **"])
    assert_equal 9, annotations.length
    assert_includes annotations.join, failures.last
    refute_includes annotations.join, failures.first
  end
end
