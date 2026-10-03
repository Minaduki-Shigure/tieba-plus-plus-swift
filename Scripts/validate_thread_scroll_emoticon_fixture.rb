#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

abort "usage: #{$PROGRAM_NAME} PROOF_JSON SCENARIO EXPERIMENT" unless ARGV.length == 3
path, scenario, experiment = ARGV
abort "Unexpected emoticon scenario" unless %w[emoticon-nested-comments emoticon-long-text].include?(scenario)
abort "Unexpected emoticon experiment" unless %w[emoticon-text-baseline emoticon-images].include?(experiment)

proof = JSON.parse(File.read(path))
names = %w[滑稽 泪 笑眼 吃瓜 捂嘴笑 菜狗]
abort "Fixture does not match the requested profile" unless
  proof.fetch("scenario") == scenario && proof.fetch("experiment") == experiment
abort "Fixture did not prepare every compiled image" unless
  proof.fetch("fixtureNames") == names && proof.fetch("seededImageCount") == names.length
abort "Fixture did not verify every decoded cache hit" unless
  proof.fetch("verifiedCacheHitCount") == names.length
abort "Fixture did not use the bounded offline image path" unless
  proof.fetch("offlineFixture") == true && proof.fetch("maximumPixelSize") == 120

images_expected = experiment == "emoticon-images"
abort "Renderer did not select the requested path" unless proof.fetch("rendersImages") == images_expected
rendered = proof.fetch("renderedImageCount")
abort "Image rendering count is invalid" unless rendered.is_a?(Integer) && rendered >= 0
if images_expected
  abort "Image candidate never rendered a decoded image" unless rendered > 0
else
  abort "Text baseline rendered images" unless rendered.zero?
end

puts "#{scenario}/#{experiment}: #{names.length} verified cached images, #{rendered} rendered image fragments"
