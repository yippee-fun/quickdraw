# frozen_string_literal: true

# The tally of a run, kept by the coordinator and handed to reporters when it
# finishes. Whether the run passed is decided here, not by any reporter.
class Quickdraw::Outcome
	def initialize
		@tests = 0
		@assertions = 0
		@failed = 0
		@errored = 0
		@load_errors = 0
		@without_assertions = 0
		@not_run = 0
		@unloaded_files = 0
		@processes_failed = false
		@stopped_early = false
		@nothing_matched = false
	end

	attr_reader :tests, :assertions, :failed, :errored, :load_errors, :without_assertions
	# `not_run` counts tests in loaded files. Files never loaded (e.g. after
	# --fail-fast stopped the run) are counted in `unloaded_files`, since their
	# tests are unknown.
	attr_accessor :not_run, :unloaded_files, :processes_failed, :stopped_early, :nothing_matched, :duration

	def record(result)
		@tests += 1
		@assertions += result["assertions"]

		if result["errors"].any?
			@errored += 1
		elsif result["failures"].any?
			@failed += 1
		elsif result["assertions"] == 0
			@without_assertions += 1
		end
	end

	def load_failed
		@load_errors += 1
	end

	def passed
		@tests - @failed - @errored
	end

	def passed?
		@failed == 0 && @errored == 0 && @load_errors == 0 && @not_run == 0 && @unloaded_files == 0 &&
			!@processes_failed && !@nothing_matched
	end
end
