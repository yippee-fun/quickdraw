# frozen_string_literal: true

# Failed tests waiting to be retried, first in the worker each failed in, then
# in fresh ones, and what their retries show. The coordinator runs them.
class Quickdraw::Coordinator::Retries
	# Failed tests retried in a run. More failures than this suggest broken code
	# rather than flaky tests, and each retry needs channels.
	LIMIT = 10

	# A failed test waiting to be retried: first in the worker it failed in
	# (`stage` :same), then in fresh ones (:fresh). Its first result is held
	# until a retry passes or none are left. `placement` is [process, slot,
	# sequence] from the run that failed, which bisect replays. `group` is the
	# group whose workers can run it. `attempts` are the retries so far (see
	# Flake.attempt).
	Retry = Struct.new(:file, :index, :result, :placement, :group, :attempts, :refreshing, :stage) do
		def place = (stage == :same) ? "same worker" : "fresh worker"

		def all_attempts
			[Quickdraw::Flake.attempt(result, "first run"), *attempts]
		end

		# Its first result, with every attempt.
		def failure
			result.merge("attempts" => all_attempts)
		end

		# Final, since the loader's exit status now shows a failure. Shown with
		# the first result, so the run's failure is explained.
		def crashed(crash)
			attempts << Quickdraw::Flake.attempt({ "failures" => [], "errors" => [crash], "duration" => nil }, place)
			errors = [*result["errors"], crash.merge("message" => "When retried in a #{place}: #{crash['message']}")]
			result.merge("errors" => errors, "attempts" => all_attempts)
		end
	end

	# `count` is how many times a test is retried in fresh workers. With
	# `fail_fast`, nothing is. `in_history` is whether the run is recorded in
	# history.
	def initialize(count, fail_fast:, in_history:)
		@count = count
		@fail_fast = fail_fast
		@in_history = in_history
		@started = 0
		# Waiting for fresh workers.
		@pending = []
	end

	# Each retry in a fresh worker needs a channel for that worker, and another
	# for the worker that replaces it. Each test's retry in the worker it
	# failed in needs one for that worker's replacement.
	def channels
		return 0 if @fail_fast || @count == 0

		LIMIT * ((@count * 2) + 1)
	end

	# Unless the run is stopping at the first problem.
	def enabled? = @count > 0 && !@fail_fast

	# Holds a failed test's result to retry it, unless so many have failed that
	# the code is probably broken. Returns whether it did.
	def hold(worker, file:, index:, result:, placement:, group:)
		raise "Retries are disabled." unless enabled?
		return false if (@started += 1) > LIMIT

		attempt = Retry.new(file:, index:, result:, placement:, group:, attempts: [], refreshing: false, stage: :same)

		# What a test leaked is still there in its worker, so it wouldn't leak it again.
		if result["errors"].any? { |error| error["name"] == "Quickdraw::Leak" }
			retry_fresh(attempt)
		else
			worker.queued_retries << attempt
		end

		true
	end

	# A retry's result. Returns the test's final result, the first one marked as
	# flaky if a retry passed, with every attempt, or nil to retry it again.
	def retried(attempt, result, stopping:)
		attempt.attempts << Quickdraw::Flake.attempt(result, attempt.place)

		if Quickdraw::Outcome.status(result) == "passed"
			attempt.result.merge(
				"passed_on_retry" => attempt.attempts.size,
				"flake" => flake_kind(attempt.attempts),
				"attempts" => attempt.all_attempts,
				"in_history" => @in_history,
			)
		elsif attempt.attempts.count { |rerun| rerun["in"] == "fresh worker" } < @count && !stopping
			retry_fresh(attempt)
			nil
		else
			attempt.failure
		end
	end

	# A worker's retries that can't run in it any more, for fresh workers.
	def release(worker)
		worker.queued_retries.each { |attempt| retry_fresh(attempt) }
		worker.queued_retries.clear
	end

	# A retry whose worker was abandoned.
	def requeue(attempt)
		@pending << attempt
	end

	# A retry for a fresh worker in `group`.
	def take(group)
		index = @pending.index { |attempt| attempt.group == group } or return
		@pending.delete_at(index)
	end

	# A retry waiting in `group` with no fresh worker on its way, marked as
	# having one.
	def refresh(group)
		attempt = @pending.find { |it| !it.refreshing && it.group == group } or return
		attempt.refreshing = true
		attempt
	end

	def waiting?(group)
		@pending.any? { |attempt| attempt.group == group }
	end

	# Yields those still waiting once the run has stopped.
	def abandon(&)
		@pending.each(&)
		@pending.clear
	end

	private def retry_fresh(attempt)
		attempt.stage = :fresh
		attempt.refreshing = false
		@pending << attempt
	end

	# What a test's retries, the last of which passed, suggest (see Flake).
	private def flake_kind(retries)
		*failed, _passed = retries

		if failed.empty? then (retries.last["in"] == "same worker") ? "nondeterministic" : "unknown"
		elsif failed.any? { |rerun| rerun["in"] == "fresh worker" } then "nondeterministic"
		else "order_dependent"
		end
	end
end
