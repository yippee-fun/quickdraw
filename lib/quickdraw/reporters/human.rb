# frozen_string_literal: true

# For people at a terminal: live progress, colour when it's a TTY, problems
# with diffs and rerun commands, then a summary with timing hints.
class Quickdraw::Reporters::Human
	include Quickdraw::Reporters::Formatting

	# Below this much total test time, shares and hints are mostly noise.
	HINT_THRESHOLD = 1.0
	SLOWEST_LIMIT = 10
	SET_ASIDE_LIMIT = 20

	def initialize(io: $stdout, backtrace: false, timings: false)
		@io = io
		@backtrace = backtrace
		@show_timings = timings
		@timings = Quickdraw::Timings.new
		@color = io.tty? && !ENV.key?("NO_COLOR")
		@live = io.tty?
		@problems = []
		@set_aside = []
		@tests = 0
		@last_progress_at = 0.0
	end

	def start(processes:, worker_choice:, seed:)
		@worker_choice = worker_choice
		@processes = processes
		@seed = seed
	end

	def result(path, test, result)
		@tests += 1
		@timings.record(path, test, result)
		case Quickdraw::Outcome.status(result)
		in "failed" | "errored" then @problems << [path, test, result]
		in "skipped" | "pending" then @set_aside << [path, test, result["skipped"]]
		in "passed" then nil
		end
		progress
	end

	def load_failed(path, error)
		@problems << [path, nil, { "errors" => [error], "failures" => [] }]
	end

	def finish(outcome)
		@io.print "\r\e[K" if @live

		print_slowest if @show_timings
		print_set_aside
		@problems.each { |problem| print_problem(*problem) }

		if outcome.processes_failed && @problems.empty?
			@io.puts
			@io.puts "#{red('✗')} A worker or the loader exited with a failure status (e.g. from an at_exit hook)."
		end

		if outcome.stopped_early && (outcome.not_run + outcome.unloaded_files) > 0
			@io.puts
			@io.puts "Stopped after the first problem (--fail-fast)."
		end

		if outcome.nothing_matched
			@io.puts
			@io.puts "#{red('✗')} No tests matched the given lines, --name or --exclude."
		end

		@io.puts
		@io.puts [
			pluralize(outcome.tests, "test"),
			pluralize(outcome.assertions, "assertion"),
			("#{outcome.failed} failed" if outcome.failed > 0),
			("#{outcome.skipped} skipped" if outcome.skipped > 0),
			("#{outcome.pending} pending" if outcome.pending > 0),
			("#{outcome.errored + outcome.load_errors} errored" if outcome.errored + outcome.load_errors > 0),
			("#{outcome.not_run} not run" if outcome.not_run > 0),
			("#{pluralize(outcome.unloaded_files, 'file')} not loaded" if outcome.unloaded_files > 0),
			("#{outcome.without_assertions} without assertions" if outcome.without_assertions > 0),
			format("%.2fs", outcome.duration),
		].compact.join(" · ")
		print_timing_summary(outcome.duration)
		@io.puts dim("Seed #{@seed} · #{pluralize(@processes, 'worker')} (#{@worker_choice}) · #{Quickdraw::Reporters.command} --seed #{@seed}")
	end

	private def print_timing_summary(elapsed)
		return if @timings.count == 0

		timings = @timings
		utilization = timings.utilization(elapsed:, processes: @processes)

		@io.puts dim([
			"Test time #{seconds(timings.test_time)}",
			phase_breakdown(timings),
			"waiting #{percent(timings.waiting_share)}",
			"GC #{percent(timings.gc_share)}",
			"#{delimit(timings.allocations_per_test)} allocations per test",
			"workers running tests #{percent(utilization)}",
		].join(" · "))

		return if timings.test_time < HINT_THRESHOLD

		hints = []

		if timings.setup_and_teardown_share >= 0.5
			hints << "Setup and teardown take #{percent(timings.setup_and_teardown_share)} of test time. " \
				"Look for expensive shared hooks, factories or fixtures."
		end

		if timings.waiting_share >= 0.3
			hints << "Tests spend #{percent(timings.waiting_share)} of their time waiting rather than computing " \
				"(IO, network, sleep, locks, or competing for the CPU)."
		end

		if timings.gc_share >= 0.15
			hints << "GC takes #{percent(timings.gc_share)} of test time. Reducing allocations or enlarging the heap may help."
		end

		slowest = timings.slowest_tests(1).first

		if @processes > 1 && slowest && elapsed >= 1 && slowest.duration >= elapsed * 0.5
			hints << "#{location(slowest)} took #{seconds(slowest.duration)}, " \
				"#{percent(slowest.duration / elapsed)} of the run. Splitting it up would let workers share it."
		elsif @processes > 1 && elapsed >= 2 && utilization < 0.6
			hints << "Workers spent #{percent(1 - utilization)} of the run not running tests " \
				"(booting, loading files or waiting for work)."
		end

		hints.each { |hint| @io.puts "#{yellow('!')} #{hint}" }
		@io.puts "  #{dim('Run with --timings to see the slowest tests and files.')}" if hints.any? && !@show_timings
	end

	private def print_slowest
		return if @timings.count == 0

		@io.puts
		@io.puts bold("Slowest tests")

		@timings.slowest_tests(SLOWEST_LIMIT).each do |test|
			total = Quickdraw::PHASES.sum { |phase| test.wall(phase) }
			split = Quickdraw::PHASES.map { |phase| "#{phase} #{percent(test.wall(phase) / total)}" }.join(", ") if total > 0
			@io.puts "  #{seconds(test.duration).rjust(8)}  #{location(test)}  #{dim(split.to_s)}"
		end

		@io.puts
		@io.puts bold("Slowest files")

		@timings.slowest_files(SLOWEST_LIMIT).each do |path, duration, count|
			@io.puts "  #{seconds(duration).rjust(8)}  #{path}  #{dim(pluralize(count, 'test'))}"
		end
	end

	# Around hooks run outside the measured phases. Below about 1ms per test, the
	# time outside phases is Quickdraw's own overhead, so it isn't shown.
	private def phase_breakdown(timings)
		parts = Quickdraw::PHASES.map { |phase| "#{phase} #{percent(timings.phase_share(phase))}" }
		around = timings.outside_phases_time
		parts << "plus #{seconds(around)} in around hooks" if around / timings.count >= 0.001
		parts.join(", ")
	end

	private def location(timed)
		"#{timed.path}:#{timed.test['line']} #{name_of(timed.test)}"
	end

	private def seconds(value)
		Quickdraw::Timer::Duration.new(value * 1_000_000_000).to_s
	end

	private def percent(ratio)
		"#{(ratio * 100).round}%"
	end

	private def delimit(number)
		number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
	end

	# Skipped and pending tests, above the problems so they don't push those out
	# of view. Only listed when there are a few; otherwise the summary counts them.
	private def print_set_aside
		return if @set_aside.empty? || @set_aside.size > SET_ASIDE_LIMIT

		@io.puts

		@set_aside.sort_by { |path, test, _| [path, test["line"]] }.each do |path, test, skipped|
			label = if skipped["pending"]
				"pending"
			elsif (reason = skipped["reason"])
				"skipped: #{reason}"
			else
				"skipped"
			end

			@io.puts dim("○ #{path}:#{test['line']} #{name_of(test)} (#{label})")
		end
	end

	private def print_problem(path, test, result)
		@io.puts

		if test
			@io.puts "#{red('✗')} #{bold("#{path}:#{test['line']}")} #{name_of(test)}"
		else
			@io.puts "#{red('✗')} #{bold(path)} could not be loaded"
		end

		result["failures"].each do |failure|
			path = relative(failure["path"])
			code = source_line(path, failure["line"]) if failure["line"] > 0
			@io.puts "  #{dim("#{path}:#{failure['line']}")}#{"  #{code}" if code}"
			@io.puts
			@io.puts indent(clean(failure["message"]), 4)
		end

		result["errors"].each do |error|
			first_line, *rest = clean(error["message"]).lines(chomp: true)
			@io.puts "  #{red(error['name'])}: #{first_line}"
			rest.each { |line| @io.puts "    #{line}" }
			backtrace(error["backtrace"]).each { |frame| @io.puts "    #{dim(relative(frame))}" }

			if (details = error["details"])
				@io.puts
				@io.puts indent(relative_paths(clean(details)), 4)
			end
		end

		@io.puts
		@io.puts "  #{dim("Rerun: #{rerun_command(path, test)}")}"
	end

	private def backtrace(frames)
		@backtrace ? frames : user_backtrace(frames)
	end

	private def progress
		return unless @live

		time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
		return if time - @last_progress_at < 0.05

		@last_progress_at = time
		@io.print "\r\e[K#{pluralize(@tests, 'test')}#{" · #{red(pluralize(@problems.size, 'problem'))}" if @problems.any?}"
	end

	private def clean(text)
		@color ? text.scrub : plain(text)
	end

	private def red(text) = style(text, 31)
	private def yellow(text) = style(text, 33)
	private def bold(text) = style(text, 1)
	private def dim(text) = style(text, 2)

	private def style(text, code)
		@color ? "\e[#{code}m#{text}\e[0m" : text
	end
end
