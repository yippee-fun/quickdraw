# frozen_string_literal: true

# For AI coding agents, which pay for every line they read. No colour,
# progress or timing breakdown, and problems one line each, grouped by cause,
# so a thousand failures with one cause take one line. The details of any
# problem are a command away (`quickdraw last PATH:LINE`), from the run kept
# in .quickdraw (see LastRun); a run that isn't kept shows its first problem
# in full instead. The result comes last, where truncated output keeps it.
class Quickdraw::Reporters::Agent
	include Quickdraw::Reporters::Formatting

	# Lines of problems and causes listed, after which the rest are counted.
	PROBLEM_LINES = 20
	# Characters of a problem's reason.
	REASON_WIDTH = 120
	BACKTRACE_LIMIT = 8
	PROFILE_LIMIT = 10
	COVERAGE_LIMIT = 20
	OUTPUT_LINES = 20
	LEAK_LIMIT = 5

	# `kept` says, once the run finishes, whether it was kept for `quickdraw
	# last`, which has the details. `replay` is for `quickdraw last`, which
	# has only the results with problems, so not a profile or coverage.
	def initialize(io: $stdout, backtrace: false, kept: nil, replay: false)
		@io = io
		@backtrace = backtrace
		@kept = kept
		@replay = replay
		@problems = []
		@leaks = []
		@profile = Quickdraw::Profile.new
	end

	def start(processes:, worker_choice:, seed:, paths:, estimate: nil, **)
		@processes = processes
		@seed = seed
	end

	def result(path, test, result)
		@problems << [path, test, result] if result["errors"].any? || result["failures"].any?
		@leaks << [path, test, result["leaks"]] if result["leaks"]
		@profile.record(result)
	end

	def load_failed(path, error, variant)
		@problems << [path, nil, { "errors" => [error], "failures" => [], "variant" => variant }]
	end

	def finished_file(_path, _variant) = nil
	def shows_loading_output? = false
	def booting = nil
	def nothing_to_run(_path, _variant) = nil
	def pause = nil
	def resume = nil

	def finish(outcome)
		kept = @kept&.call
		print_profile if @profile.any? && !@replay
		print_coverage(outcome.coverage) if outcome.coverage && !@replay
		print_problem(*@problems.first) if @problems.any? && !kept
		print_causes if @problems.any?
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
			("#{outcome.quarantined} quarantined (flaky recently, so allowed)" if outcome.quarantined > 0),
			("#{outcome.skipped} skipped" if outcome.skipped > 0),
			("#{outcome.pending} pending" if outcome.pending > 0),
			("#{outcome.errored + outcome.load_errors} errored" if outcome.errored + outcome.load_errors > 0),
			("#{outcome.not_run} not run" if outcome.not_run > 0),
			("#{pluralize(outcome.unloaded_files, 'file')} not loaded" if outcome.unloaded_files > 0),
		].compact.join(", ")

		@io.puts "#{outcome.passed? ? 'PASSED' : 'FAILED'}: #{counts} in #{format('%.2f', outcome.duration)}s (seed #{@seed})"
		print_commands(outcome, kept) if @problems.any? || @leaks.any?
	end

	# Each problem and leak in `path`, or at `path:line`, in full. Returns how many.
	def print_details(path, line = nil)
		problems = @problems.select { |problem_path, test, _result| at?(problem_path, test, path, line) }
		leaks = @leaks.select { |leak_path, test, _leaks| at?(leak_path, test, path, line) }
		problems.each { |problem| print_problem(*problem) }
		leaks.each { |leak| print_leak(*leak) }
		problems.size + leaks.size
	end

	private def at?(problem_path, test, path, line)
		problem_path == path && (line.nil? || test&.[]("line") == line)
	end

	# Every problem and leak, one line each.
	def print_list
		@problems.each { |problem| @io.puts summary(*problem) }
		@leaks.each { |leak| print_leak(*leak) }
	end

	# Each cause shared by more than one problem takes one line, with how many
	# and one of them; the rest take a line each. Most shared first.
	private def print_causes
		causes = @problems.group_by { |_path, test, result| [kind(test, result), grouping(full_reason(result))] }.values.sort_by.with_index { |problems, index| [-problems.size, index] }

		causes.first(PROBLEM_LINES).each do |problems|
			path, test, result = problems.first

			if problems.one?
				@io.puts summary(path, test, result)
			else
				@io.puts "#{delimit(problems.size)} × #{kind(test, result)} #{reason(result)}, such as #{location(path, test, result)}"
			end
		end

		if causes.size > PROBLEM_LINES
			rest = causes.drop(PROBLEM_LINES)
			@io.puts "and #{pluralize(rest.size, 'more cause')}, across #{pluralize(rest.sum(&:size), 'problem')}"
		end

		@io.puts
	end

	private def print_commands(outcome, kept)
		command = Quickdraw::Reporters.command

		if kept
			path, test, _result = @problems.first || @leaks.first
			@io.puts "Details: #{command} last #{shell(test ? "#{path}:#{test['line']}" : path)} (or a whole file). All problems: #{command} last --list"
		end

		@io.puts "Rerun the failures with: #{command} --failed" if outcome.recorded && @problems.any?
	end

	# Quoted if it has characters a shell would treat specially.
	private def shell(argument)
		argument.match?(%r{\A[\w./:@%+,=-]+\z}) ? argument : "'#{argument.gsub("'") { "'\\''" }}'"
	end

	private def summary(path, test, result)
		"#{kind(test, result)} #{location(path, test, result)}: #{reason(result)}"
	end

	private def kind(test, result)
		return "ERROR" unless test
		return "QUARANTINED" if result["quarantined"]

		case Quickdraw::Outcome.status(result)
		in "flaky" then "FLAKY"
		in "errored" then "ERROR"
		in "failed" then "FAILED"
		end
	end

	# On one line, whatever the test's name has in it. Without a test, the file
	# couldn't load, in the variant its `result` has.
	private def location(path, test, result)
		test ? "#{path}:#{test['line']} #{name_of(test).gsub(/\s*\n\s*/, ' ')}" : "#{with_variant(path, result['variant'])} could not be loaded"
	end

	private def reason(result)
		text = full_reason(result)
		(text.size > REASON_WIDTH) ? "#{text[0, REASON_WIDTH - 1]}…" : text
	end

	# The gist, on one line: an error's class and the first line of its
	# message, or a failure's first two lines, such as Expected and Actual.
	private def full_reason(result)
		text = if (error = result["errors"].first)
			"#{error['name']}: #{plain(error['message'].to_s).lines.first.to_s.strip}"
		else
			lines = result["failures"].lazy.map { |failure| plain(failure["message"].to_s).lines.map(&:strip).reject(&:empty?) }.find(&:any?)
			lines ? lines.first(2).join(" · ") : "failed, without a message"
		end

		text.squeeze(" ")
	end

	# Objects' addresses, which differ even when the cause is the same.
	private def grouping(reason)
		reason.gsub(/0x\h{8,}/, "0x…")
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

	# A problem in full: the source line it failed on, so the agent needn't open
	# the file, the message, the backtrace, what it printed, and how to rerun it.
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
			@io.puts "  #{flaky_explanation(result)}#{" Find which with: #{bisect_command(path, test)}" if bisect?(result)}"
		end

		@io.puts "  #{QUARANTINED}" if result["quarantined"]

		@io.puts "  Rerun: #{rerun_command(path, test, problem_variant(test, result))}"
		@io.puts
	end

	private def print_leaks
		@io.puts "Tests that left state behind, which can make later tests fail:"

		@leaks.first(LEAK_LIMIT).each { |leak| print_leak(*leak) }
		@io.puts "and #{pluralize(@leaks.size - LEAK_LIMIT, 'more test')}" if @leaks.size > LEAK_LIMIT
		@io.puts
	end

	private def print_leak(path, test, leaks)
		leaks.each { |leak| @io.puts "LEAK #{location(path, test, nil)}: #{leak['message']}" }
	end

	private def heading(path, test, result)
		"#{kind(test, result)} #{location(path, test, result)}"
	end

	# "path:line: code", or just "path:line" if the line can't be read.
	private def source(path, line)
		(code = source_line(path, line)) ? "#{path}:#{line}: #{code}" : "#{path}:#{line}"
	end

	# Without the blank lines that make messages readable in a terminal.
	private def compact(text)
		text.lines(chomp: true).reject(&:empty?).join("\n")
	end

	private def delimit(number)
		number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
	end
end
