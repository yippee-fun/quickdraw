# frozen_string_literal: true

# For people at a terminal: problems with diffs and rerun commands as they
# happen, a progress bar when it's a TTY, then a summary with timing hints.
class Quickdraw::Reporters::Human
	include Quickdraw::Reporters::Formatting

	# Below this much total test time, shares and hints are mostly noise.
	HINT_THRESHOLD = 1.0
	SLOWEST_LIMIT = 10
	SET_ASIDE_LIMIT = 20
	LEAK_LIMIT = 20
	PROFILE_LIMIT = 20
	COVERAGE_LIMIT = 10
	PROGRESS_INTERVAL = 0.1
	BAR_WIDTH = 24

	def initialize(io: $stdout, backtrace: false, timings: false)
		@io = io
		@backtrace = backtrace
		@show_timings = timings
		@timings = Quickdraw::Timings.new
		@profile = Quickdraw::Profile.new
		@color = io.tty? && !ENV.key?("NO_COLOR")
		@live = io.tty?
		@problems = []
		@set_aside = []
		@leaks = []
		@tests = 0
		@last_progress_at = 0.0
	end

	def start(processes:, worker_choice:, seed:, estimate: nil)
		@worker_choice = worker_choice
		@processes = processes
		@seed = seed
		@estimate = estimate
		@started_at = now
	end

	def result(path, test, result)
		@tests += 1
		@timings.record(path, test, result)
		@profile.record(result)

		case Quickdraw::Outcome.status(result)
		in "failed" | "errored" then problem(path, test, result)
		in "skipped" | "pending" then @set_aside << [path, test, result["skipped"]]
		in "passed" then nil
		end

		@leaks << [path, test, result["leaks"]] if result["leaks"]
		progress
	end

	def load_failed(path, error)
		problem(path, nil, { "errors" => [error], "failures" => [] })
	end

	def tick
		progress
	end

	def finish(outcome)
		release_bottom_row

		print_slowest if @show_timings
		print_profile if @profile.any?
		print_set_aside
		print_leaks if @leaks.any?
		print_recap if @problems.any?

		if outcome.processes_failed && @problems.empty?
			@io.puts
			@io.puts "#{red('✗')} A worker or the loader exited with a failure status (e.g. from an at_exit hook)."
		end

		if outcome.interrupted
			@io.puts
			@io.puts "#{yellow('!')} Interrupted. Tests that were running or hadn’t started are counted as not run."
		elsif outcome.stopped_early && (outcome.not_run + outcome.unloaded_files) > 0
			@io.puts
			@io.puts "Stopped after the first problem (--fail-fast)."
		end

		if outcome.nothing_matched
			@io.puts
			@io.puts "#{red('✗')} No tests matched the given lines, --name or --exclude."
		end

		print_coverage(outcome.coverage) if outcome.coverage

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
		print_timing_summary(outcome.duration) unless outcome.interrupted
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

		counts = timings.counts_per_test
		unless counts.empty?
			per_test = counts.map { |name, count, time| "#{format('%.1f', count)} #{name}#{" (#{seconds(time)})" if time > 0}" }
			@io.puts dim("Per test #{per_test.join(' · ')}")
		end

		return if timings.test_time < HINT_THRESHOLD

		hints = []

		if timings.setup_and_teardown_share >= 0.5
			hints << "Setup and teardown take #{percent(timings.setup_and_teardown_share)} of test time. " \
				"Look for expensive shared hooks, factories or fixtures#{', or run with --profile to find them' unless @profile.any?}."
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

	# Totals, then the lines most worth testing: changed ones first.
	private def print_coverage(coverage)
		@io.puts
		@io.puts "#{bold('Coverage')} #{[
			"#{coverage_percent(coverage.lines)} of lines",
			("#{coverage_percent(coverage.branches)} of branches" if coverage.branches.total > 0),
			("#{coverage_percent(coverage.methods)} of methods" if coverage.methods.total > 0),
		].compact.join(' · ')}"

		if (changed = coverage.changed)
			count, uncovered = changed
			@io.puts "  Changed lines: #{count.covered} of #{count.total} covered"
			uncovered.each { |path, lines| @io.puts "    #{red('✗')} #{path}:#{Quickdraw::CoverageReport.ranges(lines)}" }
		end

		least = coverage.least_covered(COVERAGE_LIMIT)

		if least.any?
			@io.puts "  Least covered"
			least.each do |file|
				@io.puts "    #{coverage_percent(file.lines).rjust(4)}  #{file.path}  #{dim("missing #{Quickdraw::CoverageReport.ranges(file.uncovered)}")}"
			end
		end

		if (never_loaded = coverage.never_loaded).any?
			shown = never_loaded.first(COVERAGE_LIMIT).join(", ")
			@io.puts "  #{yellow('!')} Never loaded by a test: #{shown}#{" and #{never_loaded.size - COVERAGE_LIMIT} more" if never_loaded.size > COVERAGE_LIMIT}"
		end

		@io.puts dim("  #{Quickdraw::CoverageReport::HTML_PATH} · #{Quickdraw::CoverageReport::LCOV_PATH} · #{Quickdraw::CoverageReport::JSON_PATH}")
	end

	private def coverage_percent(count)
		"#{count.percent}%"
	end

	# A method in many tests with a large share is a cost they share.
	private def print_profile
		@io.puts
		@io.puts "#{bold('Where test time goes')} #{dim("· #{delimit(@profile.samples)} samples from #{pluralize(@profile.tests, 'test')}")}"
		@io.puts dim("   total    self   tests")

		@profile.top(PROFILE_LIMIT).each do |method|
			@io.puts [
				"  #{percent(method.share).rjust(6)}",
				dim(percent(method.self_share).rjust(6)),
				delimit(method.tests).rjust(7),
				"  #{method.label}  #{dim([relative(method.path), method.line].compact.join(':'))}",
			].join(" ")
		end
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

	# Warnings, since a leak only breaks the tests that run after it.
	private def print_leaks
		@io.puts
		@io.puts "#{yellow('!')} #{pluralize(@leaks.size, 'test')} left state behind, which can make later tests fail"

		@leaks.sort_by { |path, test, _| [path, test["line"]] }.first(LEAK_LIMIT).each do |path, test, leaks|
			@io.puts "  #{path}:#{test['line']} #{name_of(test)}"
			leaks.each { |leak| @io.puts "    #{dim(leak['message'])}" }
		end

		@io.puts "  and #{pluralize(@leaks.size - LEAK_LIMIT, 'more test')}" if @leaks.size > LEAK_LIMIT
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

		if (output = result["output"])
			@io.puts
			@io.puts "  #{dim('Output')}"
			@io.puts indent(clean(output).chomp, 4)
		end

		@io.puts
		@io.puts "  #{dim("Rerun: #{rerun_command(path, test)}")}"
	end

	private def backtrace(frames)
		@backtrace ? frames : user_backtrace(frames)
	end

	# Printed as soon as it happens, so there's something to look at while the
	# rest of the run finishes.
	private def problem(path, test, result)
		@problems << [path, test, result]
		print_problem(path, test, result)
		@io.flush
	end

	# One line per problem, so they're all in view at the end however much the
	# run printed after them.
	private def print_recap
		@io.puts
		@io.puts bold(pluralize(@problems.size, "problem"))

		@problems.each do |path, test, _result|
			@io.puts test ? "  #{red('✗')} #{path}:#{test['line']} #{name_of(test)}" : "  #{red('✗')} #{path} could not be loaded"
		end
	end

	# The bar sits on the terminal's bottom row, below a scroll region holding
	# everything else, so what tests print can't collide with it. Each update is
	# one write, which saves the cursor, draws the bar and restores the cursor.
	private def progress
		return unless @live

		time = now
		return if time - @last_progress_at < PROGRESS_INTERVAL

		@last_progress_at = time
		rows, columns = terminal_size
		return release_bottom_row unless rows && rows >= 4 && columns >= 20

		reserve_bottom_row(rows) unless @rows == rows
		@io.print "\e7\e[#{rows};1H\e[2K#{fit(progress_line(time - @started_at), columns)}\e8"
		@io.flush
	end

	# Scrolls up a line if the cursor is on the bottom row, then limits scrolling
	# to the rows above it. Setting the region moves the cursor, hence \e7 and \e8.
	private def reserve_bottom_row(rows)
		unless @rows
			# The terminal keeps the scroll region if this process dies without finishing.
			at_exit { release_bottom_row }
		end

		@io.print "\n\e[1A\e7\e[1;#{rows - 1}r\e8"
		@rows = rows
	end

	private def release_bottom_row
		return unless @rows

		@io.print "\e7\e[#{@rows};1H\e[2K\e[r\e8"
		@io.flush
		@rows = nil
	end

	# Done as a share of the tests the last run had, which can be off when tests
	# were added or removed, so it never quite reaches the end on its own.
	private def progress_line(elapsed)
		parts = []

		if @estimate && @estimate.tests > 0
			total = [@estimate.tests, @tests].max
			fraction = (@tests.to_f / total).clamp(0.0, 0.99)
			parts << "#{bar(fraction)} #{delimit(@tests)}/#{delimit(total)} tests"
			parts << time_left(elapsed, fraction)
		else
			parts << pluralize(@tests, "test")
			parts << dim(duration(elapsed))
		end

		parts << red(pluralize(@problems.size, "problem")) if @problems.any?
		parts.compact.join(" · ")
	end

	# Early on, from how long the last run took; later, from this run's pace.
	private def time_left(elapsed, fraction)
		left = (fraction >= 0.1) ? elapsed * (1 - fraction) / fraction : @estimate.duration - elapsed
		dim("#{duration(left)} left") if left >= 1
	end

	private def bar(fraction)
		filled = (fraction * BAR_WIDTH).round
		"#{green('━' * filled)}#{dim('─' * (BAR_WIDTH - filled))}"
	end

	private def duration(seconds)
		(seconds < 60) ? "#{seconds.round}s" : "#{(seconds / 60).floor}m #{(seconds % 60).round}s"
	end

	# Truncated to the terminal's width, since a wrapped line would scroll.
	private def fit(line, width)
		visible = line.gsub(ANSI, "")
		(visible.size < width) ? line : visible[0, width - 1]
	end

	# [rows, columns], or nil.
	private def terminal_size
		require "io/console"
		@io.winsize
	rescue LoadError, SystemCallError, NoMethodError
		nil
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end

	private def clean(text)
		@color ? text.scrub : plain(text)
	end

	private def red(text) = style(text, 31)
	private def green(text) = style(text, 32)
	private def yellow(text) = style(text, 33)
	private def bold(text) = style(text, 1)
	private def dim(text) = style(text, 2)

	private def style(text, code)
		@color ? "\e[#{code}m#{text}\e[0m" : text
	end
end
