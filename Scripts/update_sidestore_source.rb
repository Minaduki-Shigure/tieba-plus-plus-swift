#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "optparse"
require "tempfile"
require "yaml"

class SourceUpdateError < StandardError; end

class StrictSourceJSONObject < Hash
  def []=(key, value)
    raise JSON::ParserError, "duplicate JSON key: #{key}" if key?(key)

    super
  end
end

class SideStoreSourceUpdater
  REPOSITORY = "Minaduki-Shigure/tieba-plus-plus-swift"
  APP_TARGET = "TiebaPlusPlus"
  ASSET_NAME = "TiebaPlusPlus-SideStore.ipa"

  def initialize(source_path:, project_path:, ipa_path:, tag:, date:, description:)
    @source_path = File.expand_path(source_path)
    @project_path = File.expand_path(project_path)
    @ipa_path = File.expand_path(ipa_path)
    @tag = tag
    @date = date
    @description = description
  end

  def update!
    source = load_source
    metadata = load_project_metadata
    version, prerelease = build_version(source, metadata)
    app = source.dig("apps", 0)
    versions = app["versions"]

    assert(versions.is_a?(Array) && !versions.empty?, "source versions must be a non-empty array")
    existing = versions.find do |candidate|
      candidate.is_a?(Hash) &&
        candidate["version"] == version["version"] &&
        candidate["buildVersion"] == version["buildVersion"]
    end
    if existing
      verify_existing_version(existing, version)
      return false if app["beta"] == prerelease

      replace_beta(app, prerelease)
      write_atomically(source)
      return true
    end

    newest = versions.first
    assert(newest.is_a?(Hash), "latest source version must be an object")
    assert(version["buildVersion"].to_i > positive_build(newest, "latest source version"),
           "new buildVersion must be greater than the latest published build")
    assert(compare_versions(version["version"], newest["version"]) >= 0,
           "new version must not be older than the latest published version")

    versions.unshift(version)
    replace_beta(app, prerelease)
    write_atomically(source)
    true
  end

  private

  def load_source
    source = JSON.parse(
      read_utf8(@source_path),
      object_class: StrictSourceJSONObject,
      allow_duplicate_key: false
    )
    assert(source.is_a?(Hash), "source JSON must contain an object")
    assert(source["version"] == 2, "refusing to update an unsupported source schema")
    apps = source["apps"]
    assert(apps.is_a?(Array) && apps.length == 1, "source must contain exactly one app")
    source
  rescue JSON::ParserError => error
    message = error.message.match?(/duplicate (?:JSON )?key/i) ? "duplicate JSON key" : error.message
    raise SourceUpdateError, "invalid source JSON: #{message}"
  end

  def load_project_metadata
    project = YAML.safe_load(
      read_utf8(@project_path),
      permitted_classes: [],
      permitted_symbols: [],
      aliases: false
    )
    assert(project.is_a?(Hash), "project.yml must contain an object")

    target = project.dig("targets", APP_TARGET)
    settings = target&.dig("settings", "base")
    assert(settings.is_a?(Hash), "project.yml is missing #{APP_TARGET} settings")

    bundle_identifier = required_string(settings, "PRODUCT_BUNDLE_IDENTIFIER")
    version = required_string(settings, "MARKETING_VERSION")
    build = required_string(settings, "CURRENT_PROJECT_VERSION")
    minimum_os = required_string(project.dig("options", "deploymentTarget") || {}, "iOS")

    assert(version.match?(/\A\d+\.\d+\.\d+\z/), "MARKETING_VERSION must use x.y.z format")
    assert(build.match?(/\A[1-9]\d*\z/), "CURRENT_PROJECT_VERSION must be a positive integer")

    {
      bundle_identifier: bundle_identifier,
      version: version,
      build: build,
      minimum_os: minimum_os
    }
  rescue Psych::Exception => error
    raise SourceUpdateError, "invalid project.yml: #{error.message}"
  end

  def build_version(source, metadata)
    assert(source.dig("apps", 0, "bundleIdentifier") == metadata[:bundle_identifier],
           "source bundleIdentifier does not match the project")
    assert(File.file?(@ipa_path), "IPA file not found: #{@ipa_path}")
    assert(@description.is_a?(String) && !@description.strip.empty?,
           "version description must be non-empty")
    assert(@description == @description.strip,
           "version description must not have leading or trailing whitespace")

    release_date = parse_date(@date)
    tag_pattern = /\Av#{Regexp.escape(metadata[:version])}(?:-(?:alpha|beta|rc)\.[1-9]\d*)?\z/
    assert(@tag.match?(tag_pattern), "release tag does not match MARKETING_VERSION")
    prerelease = @tag != "v#{metadata[:version]}"

    version = {
      "version" => metadata[:version],
      "buildVersion" => metadata[:build],
      # LiveContainer currently decodes the build from this compatibility key.
      "buildNumber" => metadata[:build],
      "date" => release_date,
      "localizedDescription" => @description,
      "downloadURL" => "https://github.com/#{REPOSITORY}/releases/download/#{@tag}/#{ASSET_NAME}",
      "size" => File.size(@ipa_path),
      "sha256" => Digest::SHA256.file(@ipa_path).hexdigest,
      "minOSVersion" => metadata[:minimum_os]
    }
    [version, prerelease]
  end

  def verify_existing_version(existing, expected)
    immutable_keys = %w[
      version buildVersion buildNumber downloadURL size sha256 minOSVersion
    ]
    mismatches = immutable_keys.reject { |key| existing[key] == expected[key] }
    assert(mismatches.empty?,
           "published version already exists with different immutable fields: #{mismatches.join(", ")}")
  end

  def replace_beta(app, prerelease)
    assert([true, false].include?(app["beta"]), "source app beta must be a boolean")
    app.delete("beta")
    app["beta"] = prerelease
  end

  def positive_build(version, label)
    build = version["buildVersion"]
    assert(build.is_a?(String) && build.match?(/\A[1-9]\d*\z/),
           "#{label} has an invalid buildVersion")
    build.to_i
  end

  def compare_versions(left, right)
    assert(right.is_a?(String) && right.match?(/\A\d+\.\d+\.\d+\z/),
           "latest source version is invalid")
    left.split(".").map(&:to_i) <=> right.split(".").map(&:to_i)
  end

  def parse_date(value)
    assert(value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/),
           "release date must use YYYY-MM-DD format")
    date = Date.iso8601(value)
    assert(date.iso8601 == value, "release date must be canonical")
    value
  rescue Date::Error
    raise SourceUpdateError, "release date is not a valid calendar date"
  end

  def required_string(object, key)
    value = object[key]&.to_s
    assert(value && !value.empty?, "project.yml is missing #{key}")
    value
  end

  def read_utf8(path)
    text = File.binread(path).force_encoding(Encoding::UTF_8)
    assert(text.valid_encoding?, "#{path} is not valid UTF-8")
    text
  rescue Errno::ENOENT
    raise SourceUpdateError, "file not found: #{path}"
  rescue Errno::EACCES
    raise SourceUpdateError, "file is not readable: #{path}"
  end

  def write_atomically(source)
    directory = File.dirname(@source_path)
    mode = File.stat(@source_path).mode
    temporary = Tempfile.new([".sidestore-source", ".json"], directory)
    temporary.binmode
    temporary.write(JSON.pretty_generate(source))
    temporary.write("\n")
    temporary.flush
    temporary.fsync
    temporary.chmod(mode)
    temporary.close
    File.rename(temporary.path, @source_path)
  ensure
    temporary&.close!
  end

  def assert(condition, message)
    raise SourceUpdateError, message unless condition
  end
end

if $PROGRAM_NAME == __FILE__
  repository_root = File.expand_path("..", __dir__)
  options = {
    source_path: File.join(repository_root, "sidestore-source.json"),
    project_path: File.join(repository_root, "project.yml")
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} --ipa PATH --tag TAG --date DATE --description TEXT"
    opts.on("--source PATH", "Source JSON (default: repository sidestore-source.json)") do |path|
      options[:source_path] = path
    end
    opts.on("--project PATH", "XcodeGen project.yml (default: repository project.yml)") do |path|
      options[:project_path] = path
    end
    opts.on("--ipa PATH", "Published IPA whose size and SHA-256 will be recorded") do |path|
      options[:ipa_path] = path
    end
    opts.on("--tag TAG", "Exact GitHub Release tag") { |tag| options[:tag] = tag }
    opts.on("--date DATE", "Published date in YYYY-MM-DD format") { |date| options[:date] = date }
    opts.on("--description TEXT", "Localized release description") do |description|
      options[:description] = description
    end
    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit 0
    end
  end

  begin
    parser.parse!
    raise OptionParser::InvalidArgument, "unexpected arguments: #{ARGV.join(" ")}" unless ARGV.empty?
    %i[ipa_path tag date description].each do |key|
      raise OptionParser::MissingArgument, "--#{key.to_s.tr("_", "-")}" unless options[key]
    end

    updater = SideStoreSourceUpdater.new(**options)
    changed = updater.update!
    puts changed ? "SideStore source updated: #{File.expand_path(options[:source_path])}" :
      "SideStore source already contains this release"
  rescue OptionParser::ParseError => error
    warn error.message
    warn parser
    exit 2
  rescue SourceUpdateError => error
    warn "SideStore source update failed: #{error.message}"
    exit 1
  end
end
