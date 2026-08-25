#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "optparse"

module ReleaseSourceHandoff
  class HandoffError < StandardError; end

  class Repository
    RELEASE_TAG_PATTERN = /\Av[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta|rc)\.[1-9][0-9]*)?\z/
    SOURCE_PATH = "sidestore-source.json"

    def initialize(path:, remote: "origin", branch: "main", stderr: $stderr)
      @path = File.expand_path(path)
      @remote = remote
      @branch = branch
      @stderr = stderr

      assert(File.directory?(@path), "repository does not exist: #{@path}")
      assert(@remote.match?(/\A[A-Za-z0-9._-]+\z/), "invalid remote name: #{@remote.inspect}")
      git!("rev-parse", "--git-dir")
      git!("remote", "get-url", @remote)
      git!("check-ref-format", "refs/heads/#{@branch}")
    end

    def prepare!(release_sha:, release_tag:)
      ensure_clean!
      release_commit = verify_release_tag!(release_sha: release_sha, release_tag: release_tag)
      fetch_main!
      main_commit = resolve_commit(remote_main_ref)
      head_commit = resolve_commit("HEAD")

      assert(
        head_commit == main_commit,
        "checkout HEAD #{head_commit} does not match #{remote_main_ref} #{main_commit}"
      )

      result = if main_commit == release_commit
        raise HandoffError,
              "release #{release_commit} is already on main without a separate source handoff"
      elsif ancestor?(main_commit, release_commit)
        assert(
          path_unchanged?(main_commit, release_commit, SOURCE_PATH),
          "release preparation must not modify #{SOURCE_PATH} before its IPA is published"
        )
        git!("merge", "--ff-only", release_commit)
        assert(resolve_commit("HEAD") == release_commit, "fast-forward did not reach #{release_commit}")
        :fast_forwarded_to_release
      elsif ancestor?(release_commit, main_commit)
        assert(
          !path_unchanged?(release_commit, main_commit, SOURCE_PATH),
          "main contains release #{release_commit} without a source publication commit"
        )
        :release_already_in_main
      else
        raise HandoffError,
              "#{remote_main_ref} #{main_commit} and release #{release_commit} have diverged"
      end

      ensure_clean!
      result
    end

    def publish!(release_sha:, release_tag:, attempts: 3)
      assert(attempts.is_a?(Integer) && attempts.positive?, "attempts must be a positive integer")
      ensure_clean!
      release_commit = verify_release_tag!(release_sha: release_sha, release_tag: release_tag)
      local_commit = resolve_commit("HEAD")
      assert(
        ancestor?(release_commit, local_commit),
        "local publication commit #{local_commit} does not contain release #{release_commit}"
      )
      assert(
        !path_unchanged?(release_commit, local_commit, SOURCE_PATH),
        "local publication must update #{SOURCE_PATH} after release #{release_commit}"
      )

      last_push_error = nil
      1.upto(attempts) do |attempt|
        verify_release_tag!(release_sha: release_commit, release_tag: release_tag)
        fetch_main!
        remote_commit = resolve_commit(remote_main_ref)

        if ancestor?(local_commit, remote_commit)
          assert(
            path_unchanged?(local_commit, remote_commit, SOURCE_PATH),
            "#{remote_main_ref} changed #{SOURCE_PATH} after publication #{local_commit}"
          )
          return :already_published
        end

        unless ancestor?(remote_commit, local_commit)
          raise HandoffError,
                "#{remote_main_ref} #{remote_commit} diverged from publication #{local_commit}"
        end

        _, error, status = git(
          "push",
          @remote,
          "#{local_commit}:refs/heads/#{@branch}"
        )
        if status.success?
          fetch_main!
          published_commit = resolve_commit(remote_main_ref)
          assert(
            ancestor?(local_commit, published_commit),
            "#{remote_main_ref} does not contain publication #{local_commit} after push"
          )
          assert(
            path_unchanged?(local_commit, published_commit, SOURCE_PATH),
            "#{remote_main_ref} changed #{SOURCE_PATH} while publishing #{local_commit}"
          )
          return :pushed
        end

        last_push_error = error.strip
        @stderr.puts(
          "Source push attempt #{attempt} failed; refreshing #{@remote}/#{@branch} before retry."
        )
      end

      detail = last_push_error.nil? || last_push_error.empty? ? "unknown git push failure" : last_push_error
      raise HandoffError, "unable to publish source after #{attempts} attempts: #{detail}"
    end

    private

    def remote_main_ref
      "refs/remotes/#{@remote}/#{@branch}"
    end

    def fetch_main!
      git!(
        "fetch",
        "--no-tags",
        @remote,
        "refs/heads/#{@branch}:#{remote_main_ref}"
      )
    end

    def verify_release_tag!(release_sha:, release_tag:)
      assert(
        release_sha.is_a?(String) && release_sha.match?(/\A[0-9a-f]{40}\z/),
        "release SHA must be exactly 40 lowercase hexadecimal characters"
      )
      assert(
        release_tag.is_a?(String) && release_tag.match?(RELEASE_TAG_PATTERN),
        "unsupported release tag: #{release_tag.inspect}"
      )

      tag_ref = "refs/tags/#{release_tag}"
      git!("fetch", "--no-tags", @remote, "#{tag_ref}:#{tag_ref}")
      tag_commit = resolve_commit(tag_ref)
      assert(
        tag_commit == release_sha,
        "#{tag_ref} resolves to #{tag_commit} instead of tested release #{release_sha}"
      )
      tag_commit
    end

    def resolve_commit(revision)
      git!("rev-parse", "--verify", "#{revision}^{commit}").strip
    end

    def ancestor?(ancestor, descendant)
      _, error, status = git("merge-base", "--is-ancestor", ancestor, descendant)
      return true if status.success?
      return false if status.exitstatus == 1

      raise HandoffError, "git merge-base failed: #{error.strip}"
    end

    def path_unchanged?(left, right, path)
      _, error, status = git("diff", "--quiet", left, right, "--", path)
      return true if status.success?
      return false if status.exitstatus == 1

      raise HandoffError, "git diff failed for #{path}: #{error.strip}"
    end

    def ensure_clean!
      status = git!("status", "--porcelain=v1", "--untracked-files=all")
      assert(status.empty?, "repository has uncommitted changes")
    end

    def git!(*arguments)
      output, error, status = git(*arguments)
      return output if status.success?

      detail = error.strip.empty? ? output.strip : error.strip
      raise HandoffError, "git #{arguments.join(" ")} failed: #{detail}"
    end

    def git(*arguments)
      Open3.capture3("git", "-C", @path, *arguments)
    end

    def assert(condition, message)
      raise HandoffError, message unless condition
    end
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  options = {
    path: ".",
    remote: "origin",
    branch: "main",
    attempts: 3
  }

  parser = OptionParser.new do |opts|
    opts.banner =
      "Usage: #{File.basename($PROGRAM_NAME)} COMMAND --release-sha SHA --release-tag TAG [options]"
    opts.separator "Commands: prepare, publish"
    opts.on("--repository PATH", "Git checkout to prepare or publish") { |path| options[:path] = path }
    opts.on("--release-sha SHA", "Tested release commit") { |sha| options[:release_sha] = sha }
    opts.on("--release-tag TAG", "Exact tested release tag") { |tag| options[:release_tag] = tag }
    opts.on("--remote NAME", "Git remote (default: origin)") { |name| options[:remote] = name }
    opts.on("--branch NAME", "Publication branch (default: main)") { |name| options[:branch] = name }
    opts.on("--attempts COUNT", Integer, "Push attempts (publish only; default: 3)") do |count|
      options[:attempts] = count
    end
    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit 0
    end
  end

  begin
    parser.parse!
    raise OptionParser::InvalidArgument, "unexpected arguments: #{ARGV.join(" ")}" unless ARGV.empty?
    raise OptionParser::MissingArgument, "COMMAND must be prepare or publish" unless %w[prepare publish].include?(command)
    raise OptionParser::MissingArgument, "--release-sha" unless options[:release_sha]
    raise OptionParser::MissingArgument, "--release-tag" unless options[:release_tag]

    repository = ReleaseSourceHandoff::Repository.new(
      path: options[:path],
      remote: options[:remote],
      branch: options[:branch]
    )
    result = case command
    when "prepare"
      repository.prepare!(release_sha: options[:release_sha], release_tag: options[:release_tag])
    when "publish"
      repository.publish!(
        release_sha: options[:release_sha],
        release_tag: options[:release_tag],
        attempts: options[:attempts]
      )
    end
    puts "Release source handoff: #{result}"
  rescue OptionParser::ParseError => error
    warn error.message
    warn parser
    exit 2
  rescue ReleaseSourceHandoff::HandoffError => error
    warn "Release source handoff failed: #{error.message}"
    exit 1
  end
end
