#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "set"

abort "usage: #{$PROGRAM_NAME} PLAN_TSV [RESULTS_TSV]" unless (1..2).cover?(ARGV.length)

plan_path, results_path = ARGV
plan = CSV.read(plan_path, headers: true, col_sep: "\t")
expected_headers = %w[ordinal profile_id comparison variant replicate scenario experiment]
abort "Unexpected profile plan headers" unless plan.headers == expected_headers
abort "Profile plan must contain exactly 8 rows" unless plan.length == 8

ordinals = plan.map { |row| Integer(row.fetch("ordinal"), 10) }
abort "Profile plan ordinals must be 1 through 8" unless ordinals == (1..8).to_a

profile_ids = plan.map { |row| row.fetch("profile_id") }
abort "Profile IDs must be unique" unless profile_ids.uniq.length == profile_ids.length
abort "Profile IDs must be lowercase ASCII slugs" unless profile_ids.all? { |id| id.match?(/\A[a-z0-9-]+\z/) }

expected_experiments = {
  ["gallery-cover", "control"] => ["nested-comments", "control"],
  ["gallery-cover", "candidate"] => ["nested-comments", "skip-empty-image-gallery-cover"],
  ["comments-container", "control"] => ["mixed-nested-comments", "skip-empty-image-gallery-cover"],
  ["comments-container", "candidate"] => ["mixed-nested-comments", "lazy-comments-container"],
}

expected_experiments.each do |(comparison, variant), (scenario, experiment)|
  rows = plan.select do |row|
    row.fetch("comparison") == comparison && row.fetch("variant") == variant
  end
  abort "#{comparison}/#{variant} must have two replicates" unless rows.length == 2
  abort "#{comparison}/#{variant} must contain replicates 1 and 2" unless
    rows.map { |row| row.fetch("replicate") }.sort == %w[1 2]
  abort "#{comparison}/#{variant} has an unexpected scenario or experiment" unless
    rows.all? do |row|
      row.fetch("scenario") == scenario && row.fetch("experiment") == experiment
    end
end

%w[gallery-cover comments-container].each do |comparison|
  comparison_rows = plan.select { |row| row.fetch("comparison") == comparison }
  control_ordinals = comparison_rows.filter_map do |row|
    Integer(row.fetch("ordinal"), 10) if row.fetch("variant") == "control"
  end
  candidate_ordinals = comparison_rows.filter_map do |row|
    Integer(row.fetch("ordinal"), 10) if row.fetch("variant") == "candidate"
  end
  abort "#{comparison} control and candidate must have the same mean run position" unless
    control_ordinals.sum == candidate_ordinals.sum

  replicate_order = {}
  %w[1 2].each do |replicate|
    rows = plan.select do |row|
      row.fetch("comparison") == comparison && row.fetch("replicate") == replicate
    end
    variants = rows.map do |row|
      row.fetch("variant")
    end
    abort "#{comparison} replicate #{replicate} must pair control and candidate" unless
      variants.sort == %w[candidate control]
    control = rows.find { |row| row.fetch("variant") == "control" }
    candidate = rows.find { |row| row.fetch("variant") == "candidate" }
    replicate_order[replicate] =
      Integer(control.fetch("ordinal"), 10) < Integer(candidate.fetch("ordinal"), 10)
  end
  abort "#{comparison} must reverse control/candidate order in replicate 2" unless
    replicate_order.fetch("1") != replicate_order.fetch("2")
end

if results_path
  results = CSV.read(results_path, headers: true, col_sep: "\t")
  abort "Unexpected profile results headers" unless results.headers == %w[profile_id status]
  result_ids = results.map { |row| row.fetch("profile_id") }
  abort "Profile results do not match the complete plan" unless
    result_ids.length == profile_ids.length && result_ids.to_set == profile_ids.to_set
  abort "At least one profile recording failed" unless
    results.all? { |row| row.fetch("status") == "success" }
end

puts profile_ids
