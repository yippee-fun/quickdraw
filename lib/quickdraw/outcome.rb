# frozen_string_literal: true

# The tally of a run, kept by the coordinator and handed to reporters when it
# finishes. Whether the run passed is decided here, not by any reporter.
class Quickdraw::Outcome
	# A test result's status: errored, failed, pending, skipped or passed.
	def self.status(result)
		if result["errors"].any?
			"errored"
		elsif result["failures"].any?
			"failed"
		elsif (skipped = result["skipped"])
			skipped["pending"] ? "pending" : "skipped"
		else
			"passed"
		end
	end

	def initialize
		@tests = 0
		@assertions = 0
		@failed = 0
		@errored = 0
		@skipped = 0
		@pending = 0
		@load_errors = 0
		@without_assertions = 0
		@not_run = 0
		@unloaded_files = 0
		@processes_failed = false
		@stopped_early = false
		@nothing_matched = false
		@interrupted = false
	end

	attr_reader :tests, :assertions, :failed, :errored, :skipped, :pending, :load_errors, :without_assertions
	# `not_run` counts tests in loaded files. Files never loaded (e.g. after
	# --fail-fast stopped the run) are counted in `unloaded_files`, since their
	# tests are unknown.
	attr_accessor :not_run, :unloaded_files, :processes_failed, :stopped_early, :nothing_matched, :interrupted, :duration

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

		case self.class.status(result)
		in "errored" then @errored += 1
		in "failed" then @failed += 1
		in "skipped" then @skipped += 1
		in "pending" then @pending += 1
		in "passed" then @without_assertions += 1 if result["assertions"] == 0
		end
	end

	def load_failed
		@load_errors += 1
	end

	def passed
		@tests - @failed - @errored - @skipped - @pending
	end

	def passed?
		@failed == 0 && @errored == 0 && @load_errors == 0 && @not_run == 0 && @unloaded_files == 0 &&
			!@processes_failed && !@nothing_matched && !@interrupted
	end
end
