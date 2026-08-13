#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "optparse"
require "uri"
require "yaml"

class ValidationError < StandardError; end

class StrictJSONObject < Hash
  def []=(key, value)
    raise JSON::ParserError, "duplicate JSON key: #{key}" if key?(key)

    super
  end
end

class SideStoreSourceValidator
  REPOSITORY = "Minaduki-Shigure/tieba-plus-plus-swift"
  APP_TARGET = "TiebaPlusPlus"
  APP_NAME = "Tieba++"
  ASSET_NAME = "TiebaPlusPlus-SideStore.ipa"
  SOURCE_NAME = "Tieba++"
  TINT_COLOR = "#125DBE"

  SOURCE_KEYS = %w[
    version name identifier sourceURL subtitle description iconURL headerURL
    website tintColor featuredApps apps news
  ].freeze
  SOURCE_REQUIRED_KEYS = (SOURCE_KEYS - ["headerURL"]).freeze

  APP_KEYS = %w[
    name bundleIdentifier developerName subtitle localizedDescription iconURL
    tintColor category beta screenshotURLs versions appPermissions
  ].freeze
  APP_REQUIRED_KEYS = (APP_KEYS - ["screenshotURLs"]).freeze

  VERSION_KEYS = %w[
    version buildVersion buildNumber date localizedDescription downloadURL size
    sha256 minOSVersion maxOSVersion
  ].freeze
  VERSION_REQUIRED_KEYS = (VERSION_KEYS - ["maxOSVersion"]).freeze

  PERMISSION_KEYS = %w[entitlements privacy].freeze

  def initialize(source_path:, project_path:, ipa_path: nil)
    @source_path = source_path
    @project_path = project_path
    @ipa_path = ipa_path
  end

  def validate!
    project = load_project
    source = load_source
    metadata = project_metadata(project)

    validate_source(source, metadata)
    validate_ipa(source.dig("apps", 0, "versions", 0)) if @ipa_path
  end

  private

  def load_project
    content = read_utf8(@project_path)
    project = YAML.safe_load(
      content,
      permitted_classes: [],
      permitted_symbols: [],
      aliases: false
    )
    assert(project.is_a?(Hash), "project.yml must contain a YAML object")
    project
  rescue Psych::Exception => error
    raise ValidationError, "invalid project.yml: #{error.message}"
  end

  def load_source
    source = JSON.parse(read_utf8(@source_path), object_class: StrictJSONObject)
    assert(source.is_a?(Hash), "source JSON must contain an object")
    source
  rescue JSON::ParserError => error
    raise ValidationError, "invalid source JSON: #{error.message}"
  end

  def read_utf8(path)
    bytes = File.binread(path)
    text = bytes.force_encoding(Encoding::UTF_8)
    assert(text.valid_encoding?, "#{path} is not valid UTF-8")
    text
  rescue Errno::ENOENT
    raise ValidationError, "file not found: #{path}"
  rescue Errno::EACCES
    raise ValidationError, "file is not readable: #{path}"
  end

  def project_metadata(project)
    target = project.dig("targets", APP_TARGET)
    assert(target.is_a?(Hash), "project.yml is missing target #{APP_TARGET}")

    target_settings = target.dig("settings", "base")
    info_properties = target.dig("info", "properties")
    global_settings = project.dig("settings", "base")
    assert(target_settings.is_a?(Hash), "#{APP_TARGET} is missing settings.base")
    assert(info_properties.is_a?(Hash), "#{APP_TARGET} is missing info.properties")
    assert(global_settings.is_a?(Hash), "project.yml is missing settings.base")

    bundle_identifier = required_project_string(target_settings, "PRODUCT_BUNDLE_IDENTIFIER")
    marketing_version = required_project_string(target_settings, "MARKETING_VERSION")
    build_version = required_project_string(target_settings, "CURRENT_PROJECT_VERSION")
    option_minimum = required_project_string(project.dig("options", "deploymentTarget") || {}, "iOS")
    setting_minimum = required_project_string(global_settings, "IPHONEOS_DEPLOYMENT_TARGET")

    assert(option_minimum == setting_minimum,
           "project deployment targets disagree: #{option_minimum.inspect} and #{setting_minimum.inspect}")
    assert(info_properties["CFBundleShortVersionString"] == "$(MARKETING_VERSION)",
           "CFBundleShortVersionString must reference MARKETING_VERSION")
    assert(info_properties["CFBundleVersion"] == "$(CURRENT_PROJECT_VERSION)",
           "CFBundleVersion must reference CURRENT_PROJECT_VERSION")
    assert(marketing_version.match?(/\A\d+\.\d+\.\d+\z/),
           "MARKETING_VERSION must use x.y.z format")
    assert(build_version.match?(/\A[1-9]\d*\z/),
           "CURRENT_PROJECT_VERSION must be a positive decimal integer")

    entitlement_settings = values_for_key(target, "CODE_SIGN_ENTITLEMENTS").reject do |value|
      value.nil? || value.to_s.empty?
    end
    assert(entitlement_settings.empty?,
           "CODE_SIGN_ENTITLEMENTS is configured; update this validator to derive declared entitlements")

    privacy = info_properties.each_with_object({}) do |(key, value), result|
      next unless key.end_with?("UsageDescription")

      assert(value.is_a?(String) && !value.strip.empty?, "#{key} must have a non-empty string value")
      result[key] = value
    end

    {
      bundle_identifier: bundle_identifier,
      marketing_version: marketing_version,
      build_version: build_version,
      minimum_os: option_minimum,
      privacy: privacy
    }
  end

  def required_project_string(object, key)
    value = object[key]
    assert(!value.nil?, "project.yml is missing #{key}")
    value = value.to_s
    assert(!value.empty?, "project.yml has an empty #{key}")
    value
  end

  def values_for_key(value, expected_key)
    case value
    when Hash
      own = value.key?(expected_key) ? [value[expected_key]] : []
      own + value.values.flat_map { |child| values_for_key(child, expected_key) }
    when Array
      value.flat_map { |child| values_for_key(child, expected_key) }
    else
      []
    end
  end

  def validate_source(source, metadata)
    validate_keys(source, "source", SOURCE_KEYS, SOURCE_REQUIRED_KEYS)
    assert(source["version"] == 2, "source.version must be integer 2")
    assert(source["name"] == SOURCE_NAME, "source.name must be #{SOURCE_NAME.inspect}")
    assert(source["identifier"] == metadata[:bundle_identifier],
           "source.identifier must match PRODUCT_BUNDLE_IDENTIFIER")
    require_nonempty_strings(source, "source", %w[subtitle description])

    raw_source_url = "https://raw.githubusercontent.com/#{REPOSITORY}/main/sidestore-source.json"
    icon_url = "https://raw.githubusercontent.com/#{REPOSITORY}/main/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    website_url = "https://github.com/#{REPOSITORY}"
    validate_https_url(source["sourceURL"], "source.sourceURL", expected: raw_source_url)
    validate_https_url(source["iconURL"], "source.iconURL", expected: icon_url)
    validate_https_url(source["website"], "source.website", expected: website_url)
    validate_https_url(source["headerURL"], "source.headerURL") if source.key?("headerURL")
    assert(source["tintColor"] == TINT_COLOR, "source.tintColor must be #{TINT_COLOR}")

    apps = source["apps"]
    assert(apps.is_a?(Array) && apps.length == 1, "source.apps must contain exactly one app")
    assert(source["featuredApps"] == [metadata[:bundle_identifier]],
           "source.featuredApps must contain exactly the app bundle identifier")
    assert(source["news"] == [], "source.news must currently be an empty array")

    validate_app(apps.first, metadata, icon_url)
  end

  def validate_app(app, metadata, icon_url)
    validate_keys(app, "source.apps[0]", APP_KEYS, APP_REQUIRED_KEYS)
    assert(app["name"] == APP_NAME, "source.apps[0].name must be #{APP_NAME.inspect}")
    assert(app["bundleIdentifier"] == metadata[:bundle_identifier],
           "source app bundleIdentifier must match PRODUCT_BUNDLE_IDENTIFIER")
    require_nonempty_strings(
      app,
      "source.apps[0]",
      %w[developerName subtitle localizedDescription]
    )
    validate_https_url(app["iconURL"], "source.apps[0].iconURL", expected: icon_url)
    assert(app["tintColor"] == TINT_COLOR, "source app tintColor must be #{TINT_COLOR}")
    assert(app["category"] == "social", "source app category must be \"social\"")
    assert([true, false].include?(app["beta"]), "source app beta must be a boolean")

    if app.key?("screenshotURLs")
      screenshots = app["screenshotURLs"]
      assert(screenshots.is_a?(Array), "source app screenshotURLs must be an array")
      screenshots.each_with_index do |url, index|
        validate_https_url(url, "source.apps[0].screenshotURLs[#{index}]")
      end
    end

    validate_permissions(app["appPermissions"], metadata)
    validate_versions(app["versions"], metadata, beta: app["beta"])
  end

  def validate_permissions(permissions, metadata)
    validate_keys(
      permissions,
      "source.apps[0].appPermissions",
      PERMISSION_KEYS,
      PERMISSION_KEYS
    )
    assert(permissions["entitlements"] == [],
           "source app entitlements must be [] when CODE_SIGN_ENTITLEMENTS is not configured")
    assert(permissions["privacy"].is_a?(Hash), "source app privacy permissions must be an object")
    assert(permissions["privacy"] == metadata[:privacy],
           "source app privacy permissions must exactly match project.yml UsageDescription entries")
  end

  def validate_versions(versions, metadata, beta:)
    assert(versions.is_a?(Array) && !versions.empty?, "source app versions must be a non-empty array")

    parsed_versions = versions.each_with_index.map do |version, index|
      validate_version(version, index, metadata, beta: beta)
    end

    first = versions.first
    assert(first["version"] == metadata[:marketing_version],
           "latest source version must match MARKETING_VERSION")
    assert(first["buildVersion"] == metadata[:build_version],
           "latest source buildVersion must match CURRENT_PROJECT_VERSION")
    assert(first["buildNumber"] == metadata[:build_version],
           "latest source buildNumber must match CURRENT_PROJECT_VERSION")
    assert(first["minOSVersion"] == metadata[:minimum_os],
           "latest source minOSVersion must match the project deployment target")
    assert(parsed_versions.first[:prerelease] == beta,
           "source app beta must match the latest release channel")

    pairs = versions.map { |version| [version["version"], version["buildVersion"]] }
    assert(pairs.uniq.length == pairs.length, "source versions must have unique version/buildVersion pairs")

    parsed_versions.each_cons(2) do |newer, older|
      assert(newer[:date] >= older[:date], "source versions must be ordered newest first by date")
      assert((newer[:semantic] <=> older[:semantic]) >= 0,
             "source versions must be ordered newest first by version")
      assert(newer[:build] > older[:build],
             "source build versions must be strictly descending")
    end
  end

  def validate_version(version, index, metadata, beta:)
    path = "source.apps[0].versions[#{index}]"
    validate_keys(version, path, VERSION_KEYS, VERSION_REQUIRED_KEYS)
    require_nonempty_strings(version, path, %w[version buildVersion buildNumber localizedDescription])

    version_string = version["version"]
    assert(version_string.match?(/\A\d+\.\d+\.\d+\z/), "#{path}.version must use x.y.z format")
    semantic = version_string.split(".").map(&:to_i)

    build_version = version["buildVersion"]
    build_number = version["buildNumber"]
    assert(build_version.match?(/\A[1-9]\d*\z/), "#{path}.buildVersion must be a positive integer string")
    assert(build_number == build_version, "#{path}.buildNumber must equal buildVersion")

    date = parse_date(version["date"], "#{path}.date")
    assert(version["size"].is_a?(Integer) && version["size"].positive?,
           "#{path}.size must be a positive integer byte count")
    assert(version["sha256"].is_a?(String) && version["sha256"].match?(/\A[0-9a-f]{64}\z/),
           "#{path}.sha256 must be 64 lowercase hexadecimal characters")

    validate_os_version(version["minOSVersion"], "#{path}.minOSVersion")
    if version.key?("maxOSVersion")
      minimum = validate_os_version(version["minOSVersion"], "#{path}.minOSVersion")
      maximum = validate_os_version(version["maxOSVersion"], "#{path}.maxOSVersion")
      assert((maximum <=> minimum) >= 0, "#{path}.maxOSVersion must not be lower than minOSVersion")
    end

    prerelease = validate_release_url(version["downloadURL"], path, version_string)

    { date: date, semantic: semantic, build: build_version.to_i, prerelease: prerelease }
  end

  def validate_release_url(value, path, version)
    uri = validate_https_url(value, "#{path}.downloadURL")
    assert(uri.host == "github.com", "#{path}.downloadURL must be hosted on github.com")
    assert(uri.query.nil? && uri.fragment.nil?, "#{path}.downloadURL must not contain a query or fragment")

    segments = uri.path.split("/", -1)
    expected_prefix = ["", *REPOSITORY.split("/"), "releases", "download"]
    assert(segments.first(expected_prefix.length) == expected_prefix,
           "#{path}.downloadURL must point to this repository's GitHub Release")
    assert(segments.length == expected_prefix.length + 2,
           "#{path}.downloadURL has an unexpected release asset path")

    tag = segments[-2]
    asset = segments[-1]
    stable_tag = "v#{version}"
    tag_pattern = /\A#{Regexp.escape(stable_tag)}(?:-(?:alpha|beta|rc)\.[1-9]\d*)?\z/
    assert(tag.match?(tag_pattern), "#{path}.downloadURL tag does not match version #{version}")
    assert(asset == ASSET_NAME, "#{path}.downloadURL asset must be #{ASSET_NAME}")
    tag != stable_tag
  end

  def validate_ipa(version)
    assert(version.is_a?(Hash), "cannot validate IPA without a latest source version")
    path = File.expand_path(@ipa_path)
    assert(File.file?(path), "IPA file not found: #{path}")

    actual_size = File.size(path)
    actual_sha256 = Digest::SHA256.file(path).hexdigest
    assert(actual_size == version["size"],
           "IPA size mismatch: source has #{version["size"]}, file has #{actual_size}")
    assert(actual_sha256 == version["sha256"],
           "IPA SHA-256 mismatch: source has #{version["sha256"]}, file has #{actual_sha256}")
  end

  def validate_keys(value, path, allowed, required)
    assert(value.is_a?(Hash), "#{path} must be an object")
    missing = required - value.keys
    unknown = value.keys - allowed
    assert(missing.empty?, "#{path} is missing keys: #{missing.join(", ")}")
    assert(unknown.empty?, "#{path} has unsupported keys: #{unknown.join(", ")}")
  end

  def require_nonempty_strings(object, path, keys)
    keys.each do |key|
      value = object[key]
      assert(value.is_a?(String) && !value.strip.empty?, "#{path}.#{key} must be a non-empty string")
      assert(value == value.strip, "#{path}.#{key} must not have leading or trailing whitespace")
    end
  end

  def validate_https_url(value, path, expected: nil)
    assert(value.is_a?(String) && !value.empty?, "#{path} must be a non-empty URL string")
    uri = URI.parse(value)
    assert(uri.scheme == "https" && !uri.host.nil?, "#{path} must be an absolute HTTPS URL")
    assert(uri.userinfo.nil?, "#{path} must not contain user information")
    assert(value == expected, "#{path} must be #{expected}") if expected
    uri
  rescue URI::InvalidURIError => error
    raise ValidationError, "#{path} is not a valid URL: #{error.message}"
  end

  def parse_date(value, path)
    assert(value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/),
           "#{path} must use YYYY-MM-DD format")
    date = Date.iso8601(value)
    assert(date.iso8601 == value, "#{path} is not a canonical date")
    date
  rescue Date::Error
    raise ValidationError, "#{path} is not a valid calendar date"
  end

  def validate_os_version(value, path)
    assert(value.is_a?(String) && value.match?(/\A\d+(?:\.\d+){1,2}\z/),
           "#{path} must contain two or three numeric components")
    value.split(".").map(&:to_i)
  end

  def assert(condition, message)
    raise ValidationError, message unless condition
  end
end

repository_root = File.expand_path("..", __dir__)
options = {
  source_path: File.join(repository_root, "sidestore-source.json"),
  project_path: File.join(repository_root, "project.yml"),
  ipa_path: nil
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} [--source PATH] [--project PATH] [--ipa PATH]"
  opts.on("--source PATH", "Source JSON (default: repository sidestore-source.json)") do |path|
    options[:source_path] = File.expand_path(path)
  end
  opts.on("--project PATH", "XcodeGen project.yml (default: repository project.yml)") do |path|
    options[:project_path] = File.expand_path(path)
  end
  opts.on("--ipa PATH", "Compare source size and SHA-256 with a local IPA") do |path|
    options[:ipa_path] = path
  end
  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit 0
  end
end

begin
  parser.parse!
  raise OptionParser::InvalidArgument, "unexpected arguments: #{ARGV.join(" ")}" unless ARGV.empty?

  validator = SideStoreSourceValidator.new(
    source_path: options[:source_path],
    project_path: options[:project_path],
    ipa_path: options[:ipa_path]
  )
  validator.validate!
  puts "SideStore source is valid: #{options[:source_path]}"
  puts "IPA size and SHA-256 match: #{File.expand_path(options[:ipa_path])}" if options[:ipa_path]
rescue OptionParser::ParseError => error
  warn error.message
  warn parser
  exit 2
rescue ValidationError => error
  warn "SideStore source validation failed: #{error.message}"
  exit 1
end
