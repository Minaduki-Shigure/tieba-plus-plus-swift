#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tempfile"

class ThreadScrollEmoticonFixtureTest < Minitest::Test
  VALIDATOR = File.expand_path("validate_thread_scroll_emoticon_fixture.rb", __dir__)
  PLAN_VALIDATOR = File.expand_path("validate_thread_scroll_profile_plan.rb", __dir__)
  PLAN = File.expand_path("thread_scroll_profile_plan.tsv", __dir__)

  def proof(experiment = "emoticon-images")
    {
      "scenario" => "emoticon-nested-comments", "experiment" => experiment,
      "fixtureNames" => %w[滑稽 泪 笑眼 吃瓜 捂嘴笑 菜狗],
      "seededImageCount" => 6, "verifiedCacheHitCount" => 6,
      "rendersImages" => experiment == "emoticon-images",
      "renderedImageCount" => experiment == "emoticon-images" ? 600 : 0,
      "offlineFixture" => true, "maximumPixelSize" => 120,
    }
  end

  def validate(value, expected_experiment: value.fetch("experiment"))
    Tempfile.create(["emoticon-proof", ".json"]) do |file|
      file.write(JSON.generate(value))
      file.flush
      Open3.capture3("ruby", VALIDATOR, file.path, "emoticon-nested-comments", expected_experiment)
    end
  end

  def test_accepts_actual_images_and_the_text_baseline
    %w[emoticon-images emoticon-text-baseline].each do |experiment|
      _, error, status = validate(proof(experiment))
      assert status.success?, error
    end
  end

  def test_rejects_candidate_that_only_rendered_fallback_text
    _, error, status = validate(proof.merge("renderedImageCount" => 0))
    refute status.success?
    assert_includes error, "never rendered"
  end

  def test_rejects_images_in_the_old_text_baseline
    _, error, status = validate(proof("emoticon-text-baseline").merge("renderedImageCount" => 1))
    refute status.success?
    assert_includes error, "baseline rendered"
  end

  def test_rejects_missing_cache_hits_unknown_tokens_and_online_fixtures
    [
      { "verifiedCacheHitCount" => 5 },
      { "seededImageCount" => 0 },
      { "fixtureNames" => %w[微笑 unknown] },
      { "offlineFixture" => false },
      { "maximumPixelSize" => 1600 },
      { "renderedImageCount" => "600" },
    ].each do |mutation|
      _, _, status = validate(proof.merge(mutation))
      refute status.success?, mutation.inspect
    end
  end

  def test_rejects_a_stale_proof_from_the_other_variant
    _, error, status = validate(proof, expected_experiment: "emoticon-text-baseline")
    refute status.success?
    assert_includes error, "does not match"
  end

  def test_complete_plan_contains_reversed_pairs_and_rejects_missing_replicates
    output, error, status = Open3.capture3("ruby", PLAN_VALIDATOR, PLAN)
    assert status.success?, error
    assert_equal 16, output.lines.length
    Tempfile.create(["profile-plan", ".tsv"]) do |file|
      file.write(File.readlines(PLAN).take(16).join)
      file.flush
      _, _, incomplete = Open3.capture3("ruby", PLAN_VALIDATOR, file.path)
      refute incomplete.success?
    end
  end
end
