# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tempfile"

class ReportXcodeErrorsTests < Minitest::Test
  def report(lines)
    annotations(lines).grep(/title=Xcode diagnostic/)
  end

  def annotations(lines, mode: "xcode", title: "Xcode", source: nil)
    Tempfile.create(["xcode-diagnostics", ".log"]) do |file|
      file.write(lines.join("\n"))
      file.flush
      arguments = ["--mode", mode, "--title", title]
      arguments += ["--file", source] if source
      output, status = Open3.capture2(
        RbConfig.ruby, File.join(__dir__, "report_xcode_errors.rb"), *arguments, file.path
      )
      assert status.success?
      output.lines.grep(/\A::error /)
    end
  end

  def annotation_message(annotation)
    annotation.split("::", 3).last.chomp
      .gsub("%0A", "\n").gsub("%0D", "\r").gsub("%25", "%")
  end

  def assert_bounded_annotations(values, maximum_count: 10)
    assert_operator values.length, :<=, maximum_count
    values.each do |annotation|
      escaped_message = annotation.split("::", 3).last.chomp
      assert_operator escaped_message.bytesize, :<=, 3_500
      assert annotation_message(annotation).valid_encoding?
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

  def test_final_failed_commands_survive_a_verbose_tail_without_source_located_errors
    context = 90.times.map { |index| "Build context #{index}: #{'detail ' * 80}" }
    command = "SwiftCompile normal arm64 App/Sources/Problem.swift (in target 'App')"
    values = annotations(
      context + ["LLVM Profile Error: Cannot write default.profraw", "Testing failed:",
                 "The following build commands failed:", command, "(1 failure)"]
    )

    assert_bounded_annotations(values)
    assert_match(/title=Xcode failed commands/, values.first)
    assert_includes annotation_message(values.first), command
    assert_includes annotation_message(values.first), "(1 failure)"
    tails = values.grep(/title=Xcode log tail/)
    assert_equal 3, tails.length
    assert_includes annotation_message(tails.first), "(1 failure)", "Latest tail block must be emitted first"
    refute_includes annotation_message(tails.last), "Build context 0:"
  end

  def test_source_failure_is_not_crowded_out_by_tail_chunks_and_progress_noise
    failure = "App/Tests/Images.swift:7: error: -[Images testColor] : pixel mismatch"
    context = 70.times.map { |index| "Context #{index}: #{'detail ' * 80}" }
    noise = 20.times.map { |index| "SwiftCompile normal arm64 Progress#{index}.swift" }
    values = annotations([failure] + context + noise + ["** TEST FAILED **"])

    assert_bounded_annotations(values)
    assert_includes values.map { |value| annotation_message(value) }.join, failure
    refute_includes values.grep(/log tail/).join, "Progress19.swift"
  end

  def test_long_unicode_command_keeps_its_identity_and_final_path_with_safe_escaping
    command = "SwiftCompile normal arm64 " + ("目录%\r " * 1_000) + "FinalProblem.swift"
    values = annotations(["The following build commands failed:", command, "(1 failure)"])

    assert_bounded_annotations(values)
    assert_includes annotation_message(values.first), "SwiftCompile normal arm64"
    assert_includes annotation_message(values.first), "目录%\r "
    assert_includes annotation_message(values.first), "FinalProblem.swift"
    assert_includes annotation_message(values.first), "(1 failure)"
    assert_includes values.first, "%25"
    assert_includes values.first, "%0D"
  end

  def test_failure_summary_keeps_the_last_commands_not_only_the_first_25_lines
    commands = 40.times.map { |index| "CompileC /tmp/Object#{index}.o Source#{index}.m" }
    values = annotations(["The following build commands failed:"] + commands + ["(40 failures)"])

    assert_bounded_annotations(values)
    assert_includes annotation_message(values.first), commands.last
    assert_includes annotation_message(values.first), "(40 failures)"
  end

  def test_full_mode_splits_latest_context_without_losing_final_failure_and_escapes_properties
    context = 140.times.map { |index| "Full log #{index}: #{'输出 ' * 80}" }
    values = annotations(
      context + ["Final failure: xcodebuild exited 65"], mode: "full",
      title: "Export: IPA, failed", source: "App:Sources,File.swift"
    )

    assert_bounded_annotations(values, maximum_count: 3)
    assert_equal 3, values.length
    assert_includes annotation_message(values.first), "Final failure: xcodebuild exited 65"
    assert_includes values.first, "title=Export%3A IPA%2C failed"
    assert_includes values.first, "file=App%3ASources%2CFile.swift"
  end

  def test_colored_source_errors_and_failed_commands_strip_terminal_sequences_before_matching
    source_error = "App/Sources/Runtime.swift:166:5: error: sending task risks a data race"
    command = "SwiftCompile normal arm64 App/Sources/Runtime.swift"
    values = annotations([
      "\e[1;31m#{source_error}\e[0m",
      "\e]0;hidden terminal title\aTesting failed:",
      "\e[31mThe following build commands failed:\e[0m",
      "\e]8;;https://example.invalid/terminal-link\e\\\t#{command}\e]8;;\e\\",
      "(1 failure)",
    ])

    assert_bounded_annotations(values)
    combined = values.map { |value| annotation_message(value) }.join("\n")
    assert_includes combined, source_error
    assert_includes annotation_message(values.first), "\t#{command}"
    refute_includes combined, "hidden terminal title"
    refute_includes combined, "example.invalid"
    refute_match(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/, combined)
  end

  def test_c1_and_other_control_sequences_are_removed_but_log_whitespace_is_retained
    values = annotations([
      "\u009B31merror: invalid\u009B0m\u0000\u0007\u0008\u007F\u0085",
      "\u009Dhidden OSC\u009Cvisible\ttext\rcontinued",
      "\ePhidden DCS\e\\\u009Fhidden APC\u009Cfinal error: result",
    ], mode: "full")

    assert_bounded_annotations(values, maximum_count: 3)
    combined = values.map { |value| annotation_message(value) }.join("\n")
    assert_includes combined, "error: invalid"
    assert_includes combined, "visible\ttext\rcontinued"
    assert_includes combined, "final error: result"
    refute_includes combined, "hidden"
    refute_match(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/, combined)
    assert_includes values.join, "%0D"
  end

  def test_swift_irgen_crash_keeps_source_and_thunk_context_ahead_of_profile_errors
    request = '3. While evaluating request IRGenRequest(IR Generation for file "/build/App/Sources/AutomaticForumCheckInSettingsView.swift")'
    function = '4. While emitting IR SIL function "@$sSbScA_pSgIeAghyg_SbIeAghn_TR".'
    crash = [
      "Please submit a bug report (https://swift.org/contributing/#reporting-bugs)",
      "Stack dump:",
      "1. Apple Swift version 6.1.2 (swiftlang-6.1.2.1.2 clang-1700.0.13.5)",
      "2. Compiling with effective version 6.0",
      request,
      function,
      "llvm::SmallVectorBase<unsigned int>::grow_pod(void*, unsigned long, unsigned long)",
      "swift::irgen::SyncCallEmission::setArgs(llvm::ArrayRef<llvm::Value*>)",
      "Abort trap: 6",
    ]
    context = 120.times.map { |index| "Other build output #{index}: #{'detail ' * 80}" }
    profiles = 20.times.map { |index| "LLVM Profile Error: default.profraw Operation not permitted #{index}" }
    command = "SwiftCompile normal arm64 App/Sources/AutomaticForumCheckInSettingsView.swift"
    values = annotations(
      crash + context + profiles + ["Testing failed:", "The following build commands failed:", command, "(1 failure)"]
    )

    assert_bounded_annotations(values)
    assert_match(/title=Xcode compiler crash/, values.first)
    details = annotation_message(values.first)
    assert_includes details, request
    assert_includes details, function
    assert_includes details, "Apple Swift version 6.1.2"
    assert_includes details, "SmallVectorBase"
    assert_includes details, "SyncCallEmission::setArgs"
    assert_includes annotation_message(values[1]), command
  end

  def test_normal_swift_version_banner_is_not_reported_as_a_compiler_crash
    values = annotations([
      "Apple Swift version 6.1.2", "App/Sources/Value.swift:1:5: error: cannot find value"
    ])

    assert_empty values.grep(/title=Xcode compiler crash/)
    assert_includes values.map { |value| annotation_message(value) }.join, "cannot find value"
  end
end
