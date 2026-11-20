# frozen_string_literal: true

# One JSON object per line, for tools: a "start" event, a "test" event per
# test, a "load_error" event per file that couldn't load, and a "finish" event.
# A test's "output" is what it printed, for failures and errors, and "leaks"
# lists state it left behind.
class Quickdraw::Reporters::JSON
	include Quickdraw::Reporters::Formatting

	def initialize(io: $stdout)
		@io = io
	end

	def start(processes:, worker_choice:, seed:, paths:, estimate: nil)
		# Lazily, so json never reaches the loader, which forks before this runs.
		require "json"

		emit("event" => "start", "seed" => seed, "workers" => processes, "worker_choice" => worker_choice)
	end

	def result(path, test, result)
		emit(
			"event" => "test",
			"path" => path,
			"line" => test["line"],
			"name" => name_of(test),
			"status" => Quickdraw::Outcome.status(result),
			"skip_reason" => result.dig("skipped", "reason"),
			"duration" => result["duration"],
			"assertions" => result["assertions"],
			"counts" => result["counts"]&.transform_values { |count, seconds| { "count" => count, "seconds" => seconds } },
			"failures" => result["failures"].map { |failure| failure.merge("message" => plain(failure["message"]), "path" => relative(failure["path"])) },
			"errors" => result["errors"].map { |error| serialize_error(error) },
			"output" => result["output"]&.then { |output| plain(output) },
			"leaks" => result["leaks"],
			"passed_on_retry" => result["passed_on_retry"],
		)
	end

	def load_failed(path, error)
		emit("event" => "load_error", "path" => path, "error" => serialize_error(error))
	end

	def finished_file(_path) = nil
	def shows_loading_output? = false
	def pause = nil
	def resume = nil

	def finish(outcome)
		emit(
			"event" => "finish",
			"passed" => outcome.passed?,
			"interrupted" => outcome.interrupted,
			"tests" => outcome.tests,
			"assertions" => outcome.assertions,
			"failed" => outcome.failed,
			"flaky" => outcome.flaky,
			"skipped" => outcome.skipped,
			"pending" => outcome.pending,
			"errored" => outcome.errored,
			"load_errors" => outcome.load_errors,
			"not_run" => outcome.not_run,
			"unloaded_files" => outcome.unloaded_files,
			"without_assertions" => outcome.without_assertions,
			"duration" => outcome.duration,
			"coverage" => outcome.coverage&.then do |coverage|
				{ "lines" => coverage.lines.to_h, "branches" => coverage.branches.to_h, "methods" => coverage.methods.to_h }
			end,
		)
	end

	private def serialize_error(error)
		{
			"name" => error["name"],
			"message" => plain(error["message"]),
			"backtrace" => user_backtrace(error["backtrace"]).map { |frame| relative(frame) },
			"details" => error["details"]&.then { |details| relative_paths(plain(details)) },
		}.compact
	end

	private def emit(event)
		@io.puts ::JSON.generate(event)
	end
end
