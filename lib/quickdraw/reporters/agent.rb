# frozen_string_literal: true

# For AI coding agents. No colour, progress or timing breakdown. Each problem
# shows the source line it failed on, so the agent needn't open the file, and a
# command to rerun it. The first few problems are shown in full and the rest
# one line each, since agents pay for every line they read. The result comes
# last, where truncated output keeps it.
class Quickdraw::Reporters::Agent
	include Quickdraw::Reporters::Formatting

	FULL_PROBLEMS = 10
	BACKTRACE_LIMIT = 8

	def initialize(io: $stdout, backtrace: false)
		@io = io
		@backtrace = backtrace
		@problems = []
	end

	def start(processes:, worker_choice:, seed:)
		@processes = processes
		@seed = seed
	end

	def result(path, test, result)
		@problems << [path, test, result] if result["errors"].any? || result["failures"].any?
	end

	def load_failed(path, error)
		@problems << [path, nil, { "errors" => [error], "failures" => [] }]
	end

	def finish(outcome)
		@problems.first(FULL_PROBLEMS).each { |problem| print_problem(*problem) }

		if (rest = @problems.drop(FULL_PROBLEMS)).any?
			@io.puts "#{pluralize(rest.size, 'more problem')}:"
			rest.each { |path, test, result| @io.puts "- #{heading(path, test, result)}" }
			@io.puts
		end

		@io.puts "Workers exited with a failure status (e.g. from an at_exit hook)." if outcome.processes_failed && @problems.empty?
		@io.puts "Stopped after the first problem (--fail-fast)." if outcome.stopped_early && (outcome.not_run + outcome.unloaded_files) > 0
		@io.puts "No tests matched the given lines, --name or --exclude." if outcome.nothing_matched

		counts = [
			pluralize(outcome.tests, "test"),
			"#{outcome.passed} passed",
			("#{outcome.failed} failed" if outcome.failed > 0),
			("#{outcome.skipped} skipped" if outcome.skipped > 0),
			("#{outcome.pending} pending" if outcome.pending > 0),
			("#{outcome.errored + outcome.load_errors} errored" if outcome.errored + outcome.load_errors > 0),
			("#{outcome.not_run} not run" if outcome.not_run > 0),
			("#{pluralize(outcome.unloaded_files, 'file')} not loaded" if outcome.unloaded_files > 0),
		].compact.join(", ")

		@io.puts "#{outcome.passed? ? 'PASSED' : 'FAILED'}: #{counts} in #{format('%.2f', outcome.duration)}s (seed #{@seed})"
		@io.puts "Rerun the failures with: #{Quickdraw::Reporters.command} --failed" if @problems.any?
	end

	private def print_problem(path, test, result)
		@io.puts heading(path, test, result)

		result["failures"].each do |failure|
			@io.puts "  #{source(relative(failure['path']), failure['line'])}"
			@io.puts indent(compact(plain(failure["message"])), 2)
		end

		result["errors"].each do |error|
			@io.puts "  #{error['name']}: #{compact(plain(error['message']))}"
			frames = @backtrace ? error["backtrace"] : user_backtrace(error["backtrace"])
			frames = frames.map { |frame| relative(frame) }

			if (location = frames.first && frame_location(frames.first))
				@io.puts "  #{source(*location)}"
			end

			frames.first(BACKTRACE_LIMIT).each { |frame| @io.puts "    #{frame}" }
			@io.puts indent(compact(relative_paths(plain(error["details"]))), 2) if error["details"]
		end

		@io.puts "  Rerun: #{rerun_command(path, test)}"
		@io.puts
	end

	private def heading(path, test, result)
		kind = result["errors"].any? ? "ERROR" : "FAILED"
		test ? "#{kind} #{path}:#{test['line']} #{name_of(test)}" : "#{kind} #{path} could not be loaded"
	end

	# "path:line: code", or just "path:line" if the line can't be read.
	private def source(path, line)
		(code = source_line(path, line)) ? "#{path}:#{line}: #{code}" : "#{path}:#{line}"
	end

	# Without the blank lines that make messages readable in a terminal.
	private def compact(text)
		text.lines(chomp: true).reject(&:empty?).join("\n")
	end
end
