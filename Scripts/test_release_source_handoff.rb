#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"

require_relative "release_source_handoff"

class ReleaseSourceHandoffTest < Minitest::Test
  RELEASE_TAG = "v0.65.0-alpha.1"

  def setup
    @directory = Dir.mktmpdir("release-source-handoff-test")
    @remote_path = File.join(@directory, "origin.git")
    @seed_path = File.join(@directory, "seed")

    run_command("git", "init", "--bare", @remote_path)
    run_command("git", "init", "--initial-branch=main", @seed_path)
    configure_identity(@seed_path)

    write_file(@seed_path, "project.yml", "build: 78\n")
    write_file(@seed_path, "sidestore-source.json", "published-build: 78\n")
    git!(@seed_path, "add", "project.yml", "sidestore-source.json")
    git!(@seed_path, "commit", "-m", "baseline")
    @main_sha = git!(@seed_path, "rev-parse", "HEAD").strip
    git!(@seed_path, "remote", "add", "origin", @remote_path)
    git!(@seed_path, "push", "-u", "origin", "main")
    run_command("git", "--git-dir", @remote_path, "symbolic-ref", "HEAD", "refs/heads/main")

    write_file(@seed_path, "project.yml", "build: 79\n")
    git!(@seed_path, "add", "project.yml")
    git!(@seed_path, "commit", "-m", "prepare release")
    @release_sha = git!(@seed_path, "rev-parse", "HEAD").strip
    git!(@seed_path, "tag", RELEASE_TAG)
    git!(@seed_path, "push", "origin", "refs/tags/#{RELEASE_TAG}")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_fast_forwards_tag_only_release_and_publishes_source_atomically
    checkout = clone_main("source-update")
    handoff = make_handoff(checkout)

    assert_empty git!(checkout, "tag", "--list")
    refute git_revision_exists?(checkout, @release_sha)
    assert_equal :fast_forwarded_to_release, prepare(handoff)
    assert_equal @release_sha, git!(checkout, "rev-parse", "HEAD").strip
    assert_equal RELEASE_TAG, git!(checkout, "tag", "--list").strip
    assert git_revision_exists?(checkout, @release_sha)

    publication_sha = commit_source_update(checkout)
    assert_equal :pushed, publish(handoff)

    assert_equal publication_sha, remote_main_sha
    assert git_ancestor?(@main_sha, @release_sha, repository: @remote_path, bare: true)
    assert git_ancestor?(@release_sha, publication_sha, repository: @remote_path, bare: true)
    assert_equal ["sidestore-source.json"], changed_paths(checkout, publication_sha)
  end

  def test_rejects_main_and_release_divergence_before_preparation
    competing_sha = advance_remote_main("competing-before-prepare")
    checkout = clone_main("source-update")
    handoff = make_handoff(checkout)

    error = assert_raises(ReleaseSourceHandoff::HandoffError) do
      prepare(handoff)
    end

    assert_includes error.message, "have diverged"
    assert_equal competing_sha, remote_main_sha
    assert_equal competing_sha, git!(checkout, "rev-parse", "HEAD").strip
  end

  def test_rejects_concurrent_divergence_without_rebasing_or_pushing
    checkout = clone_main("source-update")
    handoff = make_handoff(checkout)
    prepare(handoff)
    publication_sha = commit_source_update(checkout)
    competing_sha = advance_remote_main("competing-after-prepare")

    error = assert_raises(ReleaseSourceHandoff::HandoffError) do
      publish(handoff)
    end

    assert_includes error.message, "diverged from publication"
    assert_equal competing_sha, remote_main_sha
    assert_equal @release_sha, git!(checkout, "rev-parse", "#{publication_sha}^").strip
  end

  def test_retries_idempotently_after_publication
    checkout = clone_main("source-update")
    handoff = make_handoff(checkout)
    prepare(handoff)
    publication_sha = commit_source_update(checkout)
    assert_equal :pushed, publish(handoff)

    assert_equal :already_published, publish(handoff)
    retry_checkout = clone_main("source-retry")
    retry_handoff = make_handoff(retry_checkout)
    assert_equal :release_already_in_main, prepare(retry_handoff)
    assert_equal publication_sha, git!(retry_checkout, "rev-parse", "HEAD").strip
  end

  def test_rejects_remote_source_rewrite_after_publication
    checkout = clone_main("source-update")
    handoff = make_handoff(checkout)
    prepare(handoff)
    publication_sha = commit_source_update(checkout)
    assert_equal :pushed, publish(handoff)

    competing_sha = advance_remote_main(
      "rewrite-source-after-publication",
      path: "sidestore-source.json",
      content: "published-build: forged\n"
    )

    error = assert_raises(ReleaseSourceHandoff::HandoffError) do
      publish(handoff)
    end

    assert_includes error.message, "changed sidestore-source.json after publication"
    assert_equal competing_sha, remote_main_sha
    assert git_ancestor?(publication_sha, competing_sha, repository: @remote_path, bare: true)
  end

  def test_rejects_revision_expressions_as_release_sha
    checkout = clone_main("invalid-release-sha")
    handoff = make_handoff(checkout)

    error = assert_raises(ReleaseSourceHandoff::HandoffError) do
      handoff.prepare!(release_sha: "#{@release_sha}^", release_tag: RELEASE_TAG)
    end

    assert_includes error.message, "exactly 40 lowercase hexadecimal"
    assert_equal @main_sha, git!(checkout, "rev-parse", "HEAD").strip
  end

  def test_rejects_release_preparation_that_changes_published_source_history
    bad_tag = "v0.65.0-alpha.2"
    write_file(@seed_path, "sidestore-source.json", "tampered-history: true\n")
    git!(@seed_path, "add", "sidestore-source.json")
    git!(@seed_path, "commit", "-m", "tamper with source in release preparation")
    bad_release_sha = git!(@seed_path, "rev-parse", "HEAD").strip
    git!(@seed_path, "tag", bad_tag)
    git!(@seed_path, "push", "origin", "refs/tags/#{bad_tag}")
    checkout = clone_main("source-history-tamper")
    handoff = make_handoff(checkout)

    error = assert_raises(ReleaseSourceHandoff::HandoffError) do
      handoff.prepare!(release_sha: bad_release_sha, release_tag: bad_tag)
    end

    assert_includes error.message, "must not modify sidestore-source.json"
    assert_equal @main_sha, git!(checkout, "rev-parse", "HEAD").strip
    assert_equal @main_sha, remote_main_sha
  end

  def test_rejects_release_commit_pushed_to_main_without_source_handoff
    git!(@seed_path, "push", "origin", "HEAD:main")
    checkout = clone_main("release-on-main-without-source")
    handoff = make_handoff(checkout)

    error = assert_raises(ReleaseSourceHandoff::HandoffError) do
      prepare(handoff)
    end

    assert_includes error.message, "without a separate source handoff"
    assert_equal @release_sha, git!(checkout, "rev-parse", "HEAD").strip
    assert_equal @release_sha, remote_main_sha
  end

  private

  def make_handoff(path)
    ReleaseSourceHandoff::Repository.new(path: path, stderr: StringIO.new)
  end

  def prepare(handoff)
    handoff.prepare!(release_sha: @release_sha, release_tag: RELEASE_TAG)
  end

  def publish(handoff)
    handoff.publish!(release_sha: @release_sha, release_tag: RELEASE_TAG)
  end

  def clone_main(name)
    path = File.join(@directory, name)
    run_command("git", "clone", "--no-local", "--no-tags", @remote_path, path)
    configure_identity(path)
    path
  end

  def advance_remote_main(name, path: "concurrent.txt", content: nil)
    checkout = clone_main(name)
    write_file(checkout, path, content || "#{name}\n")
    git!(checkout, "add", path)
    git!(checkout, "commit", "-m", name)
    sha = git!(checkout, "rev-parse", "HEAD").strip
    git!(checkout, "push", "origin", "HEAD:main")
    sha
  end

  def commit_source_update(repository)
    write_file(repository, "sidestore-source.json", "published-build: 79\n")
    git!(repository, "add", "sidestore-source.json")
    git!(repository, "commit", "-m", "publish release source")
    git!(repository, "rev-parse", "HEAD").strip
  end

  def remote_main_sha
    run_command("git", "--git-dir", @remote_path, "rev-parse", "refs/heads/main").strip
  end

  def changed_paths(repository, commit)
    git!(repository, "diff-tree", "--no-commit-id", "--name-only", "-r", commit)
      .lines.map(&:strip).reject(&:empty?)
  end

  def git_ancestor?(ancestor, descendant, repository:, bare: false)
    arguments = ["git"]
    arguments.concat(bare ? ["--git-dir", repository] : ["-C", repository])
    arguments.concat(["merge-base", "--is-ancestor", ancestor, descendant])
    _, _, status = Open3.capture3(*arguments)
    status.success?
  end

  def git_revision_exists?(repository, revision)
    _, _, status = Open3.capture3(
      "git",
      "-C",
      repository,
      "rev-parse",
      "--verify",
      "#{revision}^{commit}"
    )
    status.success?
  end

  def configure_identity(repository)
    git!(repository, "config", "user.name", "Release Test")
    git!(repository, "config", "user.email", "release-test@example.invalid")
  end

  def write_file(repository, relative_path, content)
    path = File.join(repository, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def git!(repository, *arguments)
    run_command("git", "-C", repository, *arguments)
  end

  def run_command(*arguments)
    output, error, status = Open3.capture3(*arguments)
    assert status.success?, "#{arguments.join(" ")} failed: #{error}#{output}"
    output
  end
end
