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
	PROFILE_LIMIT = 10
	COVERAGE_LIMIT = 20
	OUTPUT_LINES = 20
	LEAK_LIMIT = 20

	def initialize(io: $stdout, backtrace: false)
		@io = io
		@backtrace = backtrace
		@problems = []
		@leaks = []
		@profile = Quickdraw::Profile.new
	end

	def start(processes:, worker_choice:, seed:, estimate: nil)
		@processes = processes
		@seed = seed
	end

	def result(path, test, result)
		@problems << [path, test, result] if result["errors"].any? || result["failures"].any?
		@leaks << [path, test, result["leaks"]] if result["leaks"]
		@profile.record(result)
	end

	def load_failed(path, error)
		@problems << [path, nil, { "errors" => [error], "failures" => [] }]
	end

	def tick(_progress) = nil
	def live? = false
	def pause = nil
	def resume = nil

	def finish(outcome)
		print_profile if @profile.any?
		print_coverage(outcome.coverage) if outcome.coverage
		@problems.first(FULL_PROBLEMS).each { |problem| print_problem(*problem) }

		if (rest = @problems.drop(FULL_PROBLEMS)).any?
			@io.puts "#{pluralize(rest.size, 'more problem')}:"
			rest.each { |path, test, result| @io.puts "- #{heading(path, test, result)}" }
			@io.puts
		end

		print_leaks if @leaks.any?

		@io.puts "Workers exited with a failure status (e.g. from an at_exit hook)." if outcome.processes_failed && @problems.empty?
		if outcome.interrupted
			@io.puts "Interrupted (Ctrl-C). Tests that were running or hadn't started weren't run."
		elsif outcome.stopped_early && (outcome.not_run + outcome.unloaded_files) > 0
			@io.puts "Stopped after the first problem (--fail-fast)."
		end
		@io.puts "No tests matched the given lines, --name or --exclude." if outcome.nothing_matched

		counts = [
			pluralize(outcome.tests, "test"),
			"#{outcome.passed} passed",
			("#{outcome.failed} failed" if outcome.failed > 0),
			("#{outcome.flaky} flaky#{' (allowed)' if outcome.allow_flaky}" if outcome.flaky > 0),
			("#{outcome.skipped} skipped" if outcome.skipped > 0),
			("#{outcome.pending} pending" if outcome.pending > 0),
			("#{outcome.errored + outcome.load_errors} errored" if outcome.errored + outcome.load_errors > 0),
			("#{outcome.not_run} not run" if outcome.not_run > 0),
			("#{pluralize(outcome.unloaded_files, 'file')} not loaded" if outcome.unloaded_files > 0),
		].compact.join(", ")

		@io.puts "#{outcome.passed? ? 'PASSED' : 'FAILED'}: #{counts} in #{format('%.2f', outcome.duration)}s (seed #{@seed})"
		@io.puts "Rerun the failures with: #{Quickdraw::Reporters.command} --failed" if @problems.any? && outcome.recorded
	end

	# Uncovered lines as path:ranges, which is what an agent writing tests needs.
	private def print_coverage(coverage)
		percent = -> (count) { "#{count.percent}%" }
		@io.puts "Coverage: #{percent.(coverage.lines)} of lines, #{percent.(coverage.branches)} of branches, #{percent.(coverage.methods)} of methods (#{Quickdraw::CoverageReport::JSON_PATH} has it all)."

		if (changed = coverage.changed)
			count, uncovered = changed
			@io.puts "Changed lines: #{count.covered} of #{count.total} covered."
			uncovered.each { |path, lines| @io.puts "- Uncovered changed lines: #{path}:#{Quickdraw::CoverageReport.ranges(lines)}" }
		end

		least = coverage.least_covered(COVERAGE_LIMIT)

		if least.any?
			@io.puts "Least covered files, with their uncovered lines:"
			least.each { |file| @io.puts "- #{file.path} (#{percent.(file.lines)}): #{Quickdraw::CoverageReport.ranges(file.uncovered)}" }
		end

		never_loaded = coverage.never_loaded
		@io.puts "Never loaded by a test: #{never_loaded.join(', ')}" if never_loaded.any?
		@io.puts
	end

	private def print_profile
		@io.puts "Where test time goes (share of the time sampled, share with the method innermost, tests it ran in):"

		@profile.top(PROFILE_LIMIT).each do |method|
			@io.puts "- #{(method.share * 100).round}%, #{(method.self_share * 100).round}% self, #{pluralize(method.tests, 'test')}: #{method.label} (#{[relative(method.path), method.line].compact.join(':')})"
		end

		@io.puts
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

		if (output = result["output"])
			lines = compact(plain(output)).lines(chomp: true)
			shown = lines.last(OUTPUT_LINES)
			@io.puts (lines.size > shown.size) ? "  Output (last #{shown.size} of #{lines.size} lines):" : "  Output:"
			shown.each { |line| @io.puts "    #{line}" }
		end

		if result["passed_on_retry"]
			@io.puts "  #{flaky_explanation(result)}#{" Find which with: #{bisect_command(path, test)}" if result['in_history']}"
		end

		@io.puts "  Rerun: #{rerun_command(path, test)}"
		@io.puts
	end

	private def print_leaks
		@io.puts "Tests that left state behind, which can make later tests fail:"

		@leaks.first(LEAK_LIMIT).each do |path, test, leaks|
			leaks.each { |leak| @io.puts "- #{path}:#{test['line']} #{name_of(test)}: #{leak['message']}" }
		end

		@io.puts "- and #{pluralize(@leaks.size - LEAK_LIMIT, 'more test')}" if @leaks.size > LEAK_LIMIT
		@io.puts
	end

	private def heading(path, test, result)
		kind = case Quickdraw::Outcome.status(result)
		in "flaky" then "FLAKY"
		in "errored" then "ERROR"
		in "failed" then "FAILED"
		end

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
