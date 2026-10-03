#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

# Input comes from Xcode's assetutil --info on the actual built app's Assets.car.
# App icons may live entirely in that catalog, without CFBundleIconFiles PNGs.
begin
  raise "Usage: validate_compiled_app_icons.rb <assetutil-info.json>" unless ARGV.length == 1

  assets = JSON.parse(File.read(ARGV.fetch(0)))
  raise "assetutil did not return an array" unless assets.is_a?(Array)

  %w[AppIcon AppIconLight AppIconDark].each do |name|
    renditions = assets.select { |asset| asset.is_a?(Hash) && asset["Name"] == name }
    puts "Compiled icon metadata: #{JSON.generate(renditions)}"
    usable = renditions.any? do |asset|
      width = asset["PixelWidth"]
      height = asset["PixelHeight"]
      size = asset["SizeOnDisk"]
      has_payload = size.is_a?(Numeric) && size.positive?
      # Multi-sized catalog records need not expose one top-level pixel size.
      valid_dimensions = if width.nil? && height.nil? && asset["AssetType"] == "MultiSized Image"
        Array(asset["Sizes"]).any? do |description|
          match = description.to_s.match(/\A(\d+)x(\d+)(?:\s|\z)/)
          match && match[1].to_i.positive? && match[1].to_i == match[2].to_i
        end
      else
        width.is_a?(Numeric) && height.is_a?(Numeric) && width.positive? && width == height
      end
      ["Icon Image", "MultiSized Image", "Image"].include?(asset["AssetType"]) &&
        has_payload && valid_dimensions
    end
    unless usable
      names = assets.filter_map { |asset| asset["Name"] if asset.is_a?(Hash) }.uniq
      raise "Missing compiled image payload for #{name}; available assets: #{names.join(', ')}"
    end
    puts "Compiled icon present: #{name} (#{renditions.length} renditions)"
  end
rescue StandardError => error
  warn "::error title=Compiled app icon validation::#{error.message}"
  exit 1
end
