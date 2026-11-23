# frozen_string_literal: true

# The tally of a run, kept by the coordinator and handed to reporters when it
# finishes. Whether the run passed is decided here, not by any reporter.
class Quickdraw::Outcome
	# A test result's status: flaky (it failed, then passed when retried in a
	# fresh worker), errored, failed, pending, skipped or passed.
	def self.status(result)
		if result["passed_on_retry"]
			"flaky"
		elsif result["errors"].any?
			"errored"
		elsif result["failures"].any?
			"failed"
		elsif (skipped = result["skipped"])
			skipped["pending"] ? "pending" : "skipped"
		else
			"passed"
		end
	end

	# With `allow_flaky`, flaky tests don't fail the run.
	def initialize(allow_flaky: false)
		@allow_flaky = allow_flaky
		@tests = 0
		@assertions = 0
		@flaky = 0
		@quarantined = 0
		@failed = 0
		@errored = 0
		@skipped = 0
		@pending = 0
		@load_errors = 0
		@not_run = 0
		@unloaded_files = 0
		@browser_files_left_out = 0
		@refused = false
		@processes_failed = false
		@worker_errors = []
		@stopped_early = false
		@nothing_matched = false
		@interrupted = false
	end

	attr_reader :tests, :assertions, :flaky, :quarantined, :failed, :errored, :skipped, :pending, :load_errors
	# The errors that stopped workers starting (see Loader#start_worker), as Quickdraw.serialize_error gives them.
	attr_reader :worker_errors
	# Set once config is read (see Coordinator#apply_settings).
	attr_accessor :allow_flaky
	# `not_run` counts tests in loaded files. Files never loaded (e.g. after
	# --fail-fast stopped the run) are counted in `unloaded_files`, since their
	# tests are unknown.
	attr_accessor :not_run, :unloaded_files, :processes_failed, :stopped_early, :nothing_matched, :interrupted, :duration

	# How many test files the run was asked to run, and how many loaded but
	# didn't finish (e.g. after Ctrl-C).
	attr_accessor :files, :unfinished_files

	# Workers added while running (see Elastic), and the seconds every worker
	# was there for, counting added ones from when they were added.
	attr_accessor :workers_added, :worker_time

	# Browser test files a plain run left out (see Coordinator#selected?).
	attr_accessor :browser_files_left_out

	# Whether the run asked for browser tests config doesn't have, so nothing ran.
	attr_accessor :refused

	# A CoverageReport with --coverage, or nil.
	attr_accessor :coverage

	# Whether the run is recorded in history, which --failed and bisect read.
	attr_accessor :recorded

	# 130 is what shells report for a process stopped by Ctrl-C.
	def exit_status
		if @interrupted then 130
		elsif passed? then 0
		else 1
		end
	end

	def record(result)
		@tests += 1
		@assertions += result["assertions"]
		return @quarantined += 1 if result["quarantined"]

		case self.class.status(result)
		in "flaky" then @flaky += 1
		in "errored" then @errored += 1
		in "failed" then @failed += 1
		in "skipped" then @skipped += 1
		in "pending" then @pending += 1
		in "passed" then nil
		end
	end

	def load_failed
		@load_errors += 1
	end

	# What the reporters say when a worker failed to start or a process exited
	# with a failure status: each distinct error that stopped a worker starting,
	# with how many, or the exit status alone if no worker said why (e.g. an
	# at_exit hook failed). Without fork, a worker that fails to start has no
	# process to exit, so its error is the only sign.
	def process_failure
		return unless @processes_failed || @worker_errors.any?

		reasons = @worker_errors.map { |error| "#{error['name']}: #{error['message'].to_s.strip.lines.first.to_s.strip}" }.tally

		if reasons.empty?
			"A worker or the loader exited with a failure status, e.g. from an at_exit hook."
		else
			reasons.map { |reason, count| "#{(count == 1) ? 'A worker' : "#{count} workers"} failed to start: #{reason}" }.join("\n")
		end
	end

	def passed
		@tests - @quarantined - @flaky - @failed - @errored - @skipped - @pending
	end

	def passed?
		@failed == 0 && @errored == 0 && (@flaky == 0 || @allow_flaky) && @load_errors == 0 && @not_run == 0 && @unloaded_files == 0 &&
			!@processes_failed && @worker_errors.empty? && !@nothing_matched && !@interrupted && !@refused
	end
end
