#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

require_relative "update_sidestore_source"

class SideStoreSourceUpdaterTest < Minitest::Test
  REPOSITORY_ROOT = File.expand_path("..", __dir__)

  def setup
    @directory = Dir.mktmpdir("sidestore-source-test")
    @source_path = File.join(@directory, "sidestore-source.json")
    @project_path = File.join(@directory, "project.yml")
    @ipa_path = File.join(@directory, "TiebaPlusPlus-SideStore.ipa")
    FileUtils.cp(File.join(REPOSITORY_ROOT, "sidestore-source.json"), @source_path)
    FileUtils.cp(File.join(REPOSITORY_ROOT, "project.yml"), @project_path)
    write_pre_release_source_fixture
    File.binwrite(@ipa_path, "deterministic fake IPA for metadata tests\n")
    set_project_version(version: "0.60.0", build: "63")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_adds_livecontainer_compatible_version_and_is_idempotent
    updater = make_updater
    assert updater.update!

    version = JSON.parse(File.read(@source_path)).dig("apps", 0, "versions", 0)
    assert_equal "0.60.0", version["version"]
    assert_equal "63", version["buildVersion"]
    assert_equal "63", version["buildNumber"]
    assert_equal "2026-08-13", version["date"]
    assert_equal "自动发布测试。", version["localizedDescription"]
    assert_equal File.size(@ipa_path), version["size"]
    assert_match(/\A[0-9a-f]{64}\z/, version["sha256"])
    assert_equal "16.0", version["minOSVersion"]
    assert_equal(
      "https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/releases/download/" \
        "v0.60.0-alpha.1/TiebaPlusPlus-SideStore.ipa",
      version["downloadURL"]
    )

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      File.join(REPOSITORY_ROOT, "Scripts", "validate_sidestore_source.rb"),
      "--source", @source_path,
      "--project", @project_path,
      "--ipa", @ipa_path
    )
    assert status.success?, "validator failed: #{stdout}#{stderr}"

    refute updater.update!
  end

  def test_keeps_existing_curated_date_and_description_when_artifact_identity_matches
    updater = make_updater
    assert updater.update!

    source = JSON.parse(File.read(@source_path))
    version = source.dig("apps", 0, "versions", 0)
    version["date"] = "2026-08-12"
    version["localizedDescription"] = "人工整理的版本说明。"
    File.write(@source_path, JSON.pretty_generate(source) + "\n")

    refute updater.update!
    preserved = JSON.parse(File.read(@source_path)).dig("apps", 0, "versions", 0)
    assert_equal "2026-08-12", preserved["date"]
    assert_equal "人工整理的版本说明。", preserved["localizedDescription"]
  end

  def test_stable_release_switches_latest_channel_without_rejecting_prerelease_history
    updater = make_updater(tag: "v0.60.0")

    assert updater.update!

    source = JSON.parse(File.read(@source_path))
    refute source.dig("apps", 0, "beta")
    assert_equal "v0.60.0", release_tag(source.dig("apps", 0, "versions", 0))
    assert_match(/-alpha\./, release_tag(source.dig("apps", 0, "versions", 1)))
    assert_source_valid
  end

  def test_newer_prerelease_can_follow_stable_history_and_restores_beta_channel
    assert make_updater(tag: "v0.60.0").update!
    set_project_version(version: "0.61.0", build: "64")

    assert make_updater(tag: "v0.61.0-beta.1").update!

    source = JSON.parse(File.read(@source_path))
    assert source.dig("apps", 0, "beta")
    assert_equal "v0.61.0-beta.1", release_tag(source.dig("apps", 0, "versions", 0))
    assert_equal "v0.60.0", release_tag(source.dig("apps", 0, "versions", 1))
    assert_source_valid
  end

  def test_rejects_existing_identity_with_a_different_artifact
    updater = make_updater
    assert updater.update!
    original = File.binread(@ipa_path)
    File.binwrite(@ipa_path, original.tr("a-z", "n-za-m"))
    assert_equal original.bytesize, File.size(@ipa_path)

    error = assert_raises(SourceUpdateError) { updater.update! }
    assert_includes error.message, "different immutable fields"
    assert_includes error.message, "sha256"
  end

  def test_rejects_future_source_schema_without_overwriting_it
    source = JSON.parse(File.read(@source_path))
    source["version"] = 3
    original = JSON.pretty_generate(source) + "\n"
    File.write(@source_path, original)

    error = assert_raises(SourceUpdateError) { make_updater.update! }
    assert_includes error.message, "unsupported source schema"
    assert_equal original.b, File.binread(@source_path)
  end

  def test_rejects_duplicate_json_keys
    File.write(@source_path, %({"version":2,"version":2,"apps":[]}\n))

    error = assert_raises(SourceUpdateError) { make_updater.update! }
    assert_includes error.message, "duplicate JSON key"

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      File.join(REPOSITORY_ROOT, "Scripts", "validate_sidestore_source.rb"),
      "--source", @source_path,
      "--project", @project_path
    )
    refute status.success?
    assert_includes "#{stdout}#{stderr}", "duplicate JSON key"
  end

  private

  def write_pre_release_source_fixture
    source = JSON.parse(File.read(@source_path))
    app = source.fetch("apps").fetch(0)
    app["beta"] = true
    app["versions"] = [
      {
        "version" => "0.59.0",
        "buildVersion" => "62",
        "buildNumber" => "62",
        "date" => "2026-08-05",
        "localizedDescription" => "固定的发布前测试基线。",
        "downloadURL" =>
          "https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/releases/download/" \
          "v0.59.0-alpha.1/TiebaPlusPlus-SideStore.ipa",
        "size" => 1,
        "sha256" => "0" * 64,
        "minOSVersion" => "16.0"
      }
    ]
    File.write(@source_path, JSON.pretty_generate(source) + "\n")
  end

  def make_updater(tag: "v0.60.0-alpha.1")
    SideStoreSourceUpdater.new(
      source_path: @source_path,
      project_path: @project_path,
      ipa_path: @ipa_path,
      tag: tag,
      date: "2026-08-13",
      description: "自动发布测试。"
    )
  end

  def assert_source_valid
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      File.join(REPOSITORY_ROOT, "Scripts", "validate_sidestore_source.rb"),
      "--source", @source_path,
      "--project", @project_path,
      "--ipa", @ipa_path
    )
    assert status.success?, "validator failed: #{stdout}#{stderr}"
  end

  def release_tag(version)
    version.fetch("downloadURL").split("/")[-2]
  end

  def set_project_version(version:, build:)
    project = YAML.safe_load_file(@project_path, aliases: false)
    settings = project.dig("targets", "TiebaPlusPlus", "settings", "base")
    settings["MARKETING_VERSION"] = version
    settings["CURRENT_PROJECT_VERSION"] = build
    File.write(@project_path, YAML.dump(project))
  end
end
