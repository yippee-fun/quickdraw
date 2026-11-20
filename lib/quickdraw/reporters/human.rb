# frozen_string_literal: true

# For people at a terminal: problems with diffs and rerun commands as they
# happen, beneath which a live block shows what's running, then a summary.
class Quickdraw::Reporters::Human
	include Quickdraw::Reporters::Formatting

	# Below this much total test time, shares and hints are mostly noise.
	HINT_THRESHOLD = 1.0
	SLOWEST_LIMIT = 10
	SET_ASIDE_LIMIT = 20
	LEAK_LIMIT = 20
	PROFILE_LIMIT = 20
	COVERAGE_LIMIT = 10
	# Seconds between redraws of the live block.
	LIVE_INTERVAL = 0.08
	# Running files listed in the live block.
	RUNNING_SHOWN = 4
	SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"].freeze
	# Lines shown either side of a failing line.
	CODE_FRAME_CONTEXT = 1
	# The summary's labels, right-aligned to the longest, "Test files".
	LABEL_WIDTH = 10

	# `live` shows a block of what's running, redrawn in place, on a terminal.
	# It's off when tests print straight to the terminal, which would garble it.
	def initialize(io: $stdout, backtrace: false, timings: false, live: true)
		@io = io
		@backtrace = backtrace
		@show_timings = timings
		@timings = Quickdraw::Timings.new
		@profile = Quickdraw::Profile.new
		@color = io.tty? && !ENV.key?("NO_COLOR")
		@live = live && io.tty?
		@problems = []
		@set_aside = []
		@leaks = []
		# The worst that happened in each file with a problem.
		@file_statuses = {}
		@statuses = Hash.new(0)
		@live_widths = []
		@drawn_at = 0.0
		@held = []
	end

	def start(processes:, worker_choice:, seed:, estimate: nil)
		@worker_choice = worker_choice
		@processes = processes
		@seed = seed
		@estimate = estimate
		@started_at = now
	end

	def result(path, test, result)
		@timings.record(path, test, result)
		@profile.record(result)
		status = Quickdraw::Outcome.status(result)
		@statuses[status] += 1

		case status
		in "failed" | "errored"
			@file_statuses[path] = "failed"
			problem(path, test, result)
		in "flaky"
			@file_statuses[path] ||= "flaky"
			problem(path, test, result)
		in "skipped" | "pending" then @set_aside << [path, test, result["skipped"]]
		in "passed" then nil
		end

		@leaks << [path, test, result["leaks"]] if result["leaks"]
	end

	def load_failed(path, error)
		@file_statuses[path] = "failed to load"
		problem(path, nil, { "errors" => [error], "failures" => [] })
	end

	# `progress` gives where the run is (see Reporters::Progress).
	def tick(progress)
		@progress = progress
		draw_live
	end

	def live? = @live

	# What loading a test file printed, above the live block rather than over it.
	def printed(output)
		above_live do
			@io.print output
			@io.puts unless output.end_with?("\n")
		end
	end

	# While a test is in a debugger, which has the terminal, until #resume.
	def pause
		clear_live
		@paused = true
	end

	# The live block comes back with the next tick, so stepping through a
	# debugger, which gives the terminal back between steps, doesn't flicker.
	def resume
		@paused = false
		held, @held = @held, []
		held.each { |print| above_live(&print) }
	end

	def finish(outcome)
		clear_live

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
		row "Test files", files_line(outcome)
		row "Tests", tests_line(outcome)
		row "Assertions", delimit(outcome.assertions)
		print_timing_summary(outcome) unless outcome.interrupted
		row "Seed", "#{@seed} #{dim("· #{Quickdraw::Reporters.command} --seed #{@seed}")}"
		print_hints(outcome) unless outcome.interrupted
		@io.puts
		@io.puts verdict(outcome)
	end

	# The badge, then how to rerun what failed. --failed reads history, so it's
	# suggested only to runs that record it.
	private def verdict(outcome)
		if outcome.interrupted
			label("INTERRUPTED", 43)
		elsif outcome.passed?
			label("PASSED", 42)
		elsif @problems.any? && outcome.recorded
			"#{label('FAILED', 41)} #{dim("↻ #{Quickdraw::Reporters.command} --failed")}"
		else
			label("FAILED", 41)
		end
	end

	# A line of the summary, its label right-aligned in a column.
	private def row(label, text)
		@io.puts row_text(label, text)
	end

	private def row_text(label, text)
		" #{dim(label.rjust(LABEL_WIDTH))}  #{text}"
	end

	# A file fails if a test in it failed or errored, or it failed to load. One
	# with only flaky tests is flaky, whether or not they're allowed.
	private def files_line(outcome)
		statuses = @file_statuses.values.tally
		failed = statuses.fetch("failed", 0)
		flaky = statuses.fetch("flaky", 0)
		failed_to_load = statuses.fetch("failed to load", 0)
		unfinished = outcome.unfinished_files.to_i
		passed = outcome.files - failed - flaky - failed_to_load - unfinished - outcome.unloaded_files

		[
			(red("#{failed} failed") if failed > 0),
			(red("#{failed_to_load} failed to load") if failed_to_load > 0),
			(yellow("#{flaky} flaky") if flaky > 0),
			(green("#{passed} passed") if passed > 0),
			(yellow("#{unfinished} not finished") if unfinished > 0),
			(yellow("#{outcome.unloaded_files} not loaded") if outcome.unloaded_files > 0),
		].compact.join(dim(" · ")) + dim(" (#{outcome.files})")
	end

	# Each count in the colour of what it means, then the total. Files that
	# failed to load are counted in the Test files row.
	private def tests_line(outcome)
		counts = [
			(red("#{outcome.failed} failed") if outcome.failed > 0),
			(yellow("#{outcome.flaky} flaky#{' (allowed)' if outcome.allow_flaky}") if outcome.flaky > 0),
			(red("#{outcome.errored} errored") if outcome.errored > 0),
			(green("#{outcome.passed} passed") if outcome.passed > 0),
			(dim("#{outcome.skipped} skipped") if outcome.skipped > 0),
			(dim("#{outcome.pending} pending") if outcome.pending > 0),
			(yellow("#{outcome.not_run} not run") if outcome.not_run > 0),
			(yellow("#{outcome.without_assertions} without assertions") if outcome.without_assertions > 0),
		].compact

		counts = ["none ran"] if counts.empty?
		counts.join(dim(" · ")) + dim(" (#{outcome.tests})")
	end

	# The tests' total time against the last run of the same tests, when it's a
	# real difference. Total test time, unlike the run's, doesn't depend on how
	# many workers ran or how long booting took.
	private def comparison(outcome)
		estimate = @estimate
		return unless estimate && estimate.tests == outcome.tests && estimate.test_time > 0 && !outcome.interrupted

		test_time = @timings.test_time
		change = (test_time / estimate.test_time) - 1
		return if change.abs < 0.1 || (test_time - estimate.test_time).abs < 0.05

		if change.negative?
			" #{dim('·')} #{green("tests #{percent(-change)} faster than the last run")}"
		else
			" #{dim('·')} #{yellow("tests #{percent(change)} slower than the last run")}"
		end
	end

	# Shares that are too small to matter are left out.
	private def print_timing_summary(outcome)
		timings = @timings
		elapsed = outcome.duration
		utilization = busy(outcome) if timings.count > 0
		split = " (#{phase_breakdown(timings)})" if timings.count > 0 && (timings.setup_and_teardown_share >= 0.1 || timings.outside_phases_time / timings.count >= 0.001)

		shares = if timings.count > 0
			[
				"#{seconds(timings.test_time)} of test time#{split}",
				("#{percent(timings.waiting_share)} waiting" if timings.waiting_share >= 0.1),
				("#{percent(timings.gc_share)} in GC" if timings.gc_share >= 0.05),
			].compact
		else
			[]
		end

		row "Duration", [format("%.2fs", elapsed), *shares.map { |share| dim(share) }].join(dim(" · ")) + comparison(outcome).to_s

		added = outcome.workers_added.to_i
		workers = (added > 0) ? "#{@processes + added} #{dim("(#{@processes} #{@worker_choice}, #{added} added as tests waited)")}" : "#{@processes} #{dim("(#{@worker_choice})")}"
		row "Workers", "#{workers}#{dim(" · busy #{percent(utilization)}") if utilization}"

		return if timings.count == 0

		per_test = [
			"#{delimit(timings.allocations_per_test)} allocations",
			*timings.counts_per_test.map { |name, count, time| "#{format('%.1f', count)} #{name}#{" (#{seconds(time)})" if time > 0}" },
		]
		row "Per test", per_test.join(dim(" · "))
	end

	# The share of the workers' time spent running tests, counting workers added
	# while running from when they were added.
	private def busy(outcome)
		worker_time = outcome.worker_time.to_f
		return @timings.utilization(elapsed: outcome.duration, processes: @processes) unless worker_time > 0

		(@timings.test_time / worker_time).clamp(0.0, 1.0)
	end

	# Below the rows, under their values.
	private def print_hints(outcome)
		timings = @timings
		elapsed = outcome.duration
		return if timings.count == 0 || timings.test_time < HINT_THRESHOLD

		utilization = busy(outcome)

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

		# Short runs too, since a slow test is often what limits them.
		if @processes > 1 && slowest && slowest.duration >= elapsed * 0.5
			hints << "#{location(slowest)} took #{seconds(slowest.duration)}, " \
				"#{percent(slowest.duration / elapsed)} of the run. Splitting it up would let workers share it."
		elsif @processes > 1 && elapsed >= 2 && utilization < 0.6
			hints << "Workers spent #{percent(1 - utilization)} of the run not running tests " \
				"(booting, loading files or waiting for work)."
		end

		indent = " " * (LABEL_WIDTH + 3)
		hints.each { |hint| @io.puts "#{indent}#{yellow('!')} #{hint}" }
		@io.puts "#{indent}#{dim('Run with --timings to see the slowest tests and files.')}" if hints.any? && !@show_timings
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
			kind = skipped["pending"] ? "○ pending" : "↷ skipped"
			reason = " — #{skipped['reason']}" if skipped["reason"]
			@io.puts "#{dim(kind)}  #{name_of(test)}#{dim("#{reason}  #{path}:#{test['line']}")}"
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
			@io.puts "#{badge(result)} #{bold(test['description'] || "line #{test['line']}")}  #{dim([test['class_name'], "#{path}:#{test['line']}"].compact.join(' · '))}"
		else
			@io.puts "#{badge(result)} #{bold(path)} could not be loaded"
		end

		result["failures"].each do |failure|
			failure_path = relative(failure["path"])
			@io.puts
			@io.puts "  #{cyan("#{failure_path}:#{failure['line']}")}" unless failure_path == path
			print_code_frame(failure_path, failure["line"])
			@io.puts
			@io.puts indent(clean(failure["message"]).chomp, 4)
		end

		result["errors"].each { |error| print_error(error) }

		if (output = result["output"])
			@io.puts
			@io.puts "  #{dim('Output')}"
			@io.puts indent(clean(output).chomp, 4)
		end

		if result["passed_on_retry"]
			@io.puts
			@io.puts "  #{yellow(flaky_explanation(result))}"
			@io.puts "  #{dim("⌕ #{bisect_command(path, test)}")}" if result["in_history"]
		end

		@io.puts
		@io.puts "  #{dim("↻ #{rerun_command(path, test)}")}"
	end

	# The message, then the code where it was raised, then the rest of the backtrace.
	private def print_error(error)
		first_line, *rest = clean(error["message"]).lines(chomp: true)
		@io.puts
		@io.puts "  #{red("#{error['name']}:")} #{first_line}"
		rest.each { |line| @io.puts "  #{line}" }

		# Only the test's own frames: when Quickdraw raised, they say nothing more.
		frames = error["backtrace"]
		frames = frames.reject { |frame| frame.start_with?(LIBRARY) }.take_while { |frame| !frame.start_with?(EXECUTABLES) } unless @backtrace
		frames = frames.map { |frame| relative(frame.scrub) }

		# The first frame of the project's own code, which a gem's error was raised from.
		shown = frames.find do |frame|
			frame_path, = frame_location(frame)
			frame_path && !frame_path.start_with?("/", "vendor/") && source_lines(frame_path)
		end

		if shown
			frame_path, line = frame_location(shown)
			@io.puts
			@io.puts "  #{cyan("#{frame_path}:#{line}")} #{dim(shown[/:in [`'](.*)'\z/, 1]&.then { |name| "in #{name}" }.to_s)}"
			print_code_frame(frame_path, line)
			frames -= [shown]
		end

		if frames.any?
			@io.puts
			frames.each { |frame| @io.puts "  #{dim(frame)}" }
		end

		if (details = error["details"])
			@io.puts
			@io.puts indent(relative_paths(clean(details)), 4)
		end
	end

	# The line, with the lines around it, numbered, and indented as little as
	# they allow.
	private def print_code_frame(path, line)
		lines = source_lines(path)
		return @io.puts "  #{dim("#{path}:#{line}")}" unless lines && line.between?(1, lines.size)

		first = [line - CODE_FRAME_CONTEXT, 1].max
		last = [line + CODE_FRAME_CONTEXT, lines.size].min
		numbers = (first..last)
		code = numbers.to_h { |number| [number, lines[number - 1].gsub("\t", "  ")] }
		margin = code.values.reject { |text| text.strip.empty? }.map { |text| text[/\A */].size }.min || 0
		width = numbers.last.to_s.size

		numbers.each do |number|
			text = code[number][margin..].to_s

			if number == line
				@io.puts "  #{red("▸ #{number.to_s.rjust(width)} │")} #{text}"
			else
				@io.puts "  #{dim("  #{number.to_s.rjust(width)} │ #{text}")}"
			end
		end
	end

	private def badge(result)
		case Quickdraw::Outcome.status(result)
		in "flaky" then label("FLAKY", 43)
		in "errored" then label("ERROR", 41)
		in "failed" then label("FAIL", 41)
		end
	end

	# Dark text on a coloured background, or just the text without colour.
	private def label(text, background)
		@color ? "\e[1;30;#{background}m #{text} \e[0m" : text
	end

	private def marker(result)
		result["passed_on_retry"] ? yellow("~") : red("✗")
	end

	# Printed as soon as it happens, above the live block, so there's something
	# to look at while the rest of the run finishes.
	private def problem(path, test, result)
		@problems << [path, test, result]
		above_live { print_problem(path, test, result) }
	end

	# Prints above the live block, or once a debugger is done with the terminal.
	private def above_live(&print)
		return @held << print if @paused

		clear_live
		print.call
		@io.flush
		draw_live(force: true)
	end

	# One line per problem, so they're all in view at the end however much the
	# run printed after them.
	private def print_recap
		_rows, columns = terminal_size
		title = " #{pluralize(@problems.size, 'problem')} "
		side = [([columns || 60, 72].min - title.size) / 2, 3].max
		@io.puts
		@io.puts "#{dim('⎯' * side)}#{bold(title)}#{dim('⎯' * side)}"

		@problems.each do |path, test, result|
			@io.puts test ? "  #{marker(result)} #{path}:#{test['line']} #{name_of(test)}#{dim(' (flaky)') if result['passed_on_retry']}" : "  #{marker(result)} #{path} could not be loaded"
		end
	end

	# Below everything printed so far: the files being run, then how many files
	# and tests are done. Every number is a count, never an estimate, so the
	# total number of tests only shows once every file has loaded. Redrawn in
	# place by moving the cursor up over it, so lines are cut to the terminal's
	# width, as a wrapped line would throw the count off.
	private def draw_live(force: false)
		return unless @live && @progress && !@paused

		time = now
		return unless force || time - @drawn_at >= LIVE_INTERVAL

		rows, columns = terminal_size
		# Gone, rather than left as it was, if the terminal gets too small.
		return clear_live unless rows && columns && rows >= 6 && columns >= 30

		unless @cursor_hidden
			# Or the terminal keeps no cursor if this process dies mid-run.
			at_exit { clear_live } unless @cleared_at_exit
			@cleared_at_exit = true
			@io.print "\e[?25l"
			@cursor_hidden = true
		end

		@drawn_at = time
		# Shorter than the terminal, or drawing it would scroll the top off.
		lines = live_lines(@progress.call, time, running_shown: [RUNNING_SHOWN, rows - 6].min, columns:).map { |line| fit(line, columns) }
		@io.print "#{erase_live(columns)}#{lines.map { |line| "#{line}\n" }.join}"
		@live_widths = lines.map { |line| columns_of(line.gsub(ANSI, "")) }
		@io.flush
	end

	private def live_lines(progress, time, running_shown:, columns:)
		frame = yellow(SPINNER[((time - @started_at) / LIVE_INTERVAL).floor % SPINNER.size])
		running = progress.running.sort_by(&:first)
		shown = running.first([running_shown, 0].max)
		counts = shown.map { |_path, done, total| "#{done}/#{total}" }
		# Paths are cut from the left to leave room for the counts.
		room = columns - 6 - (counts.map(&:size).max || 0)
		paths = shown.map { |path, _done, _total| (path.size > room) ? "…#{path[-(room - 1)..]}" : path }
		width = paths.map(&:size).max || 0

		lines = paths.zip(counts).map do |path, count|
			directory, slash, name = path.rpartition("/")
			" #{frame} #{dim("#{directory}#{slash}")}#{bold(name)}#{' ' * (width - path.size)}  #{dim(count)}"
		end

		lines << dim("   and #{pluralize(running.size - shown.size, 'more file')}") if running.size > shown.size
		lines << "" if lines.any?

		tests = [
			(green("#{@statuses['passed']} passed") if @statuses["passed"] > 0),
			(red("#{@statuses['failed']} failed") if @statuses["failed"] > 0),
			(yellow("#{@statuses['flaky']} flaky") if @statuses["flaky"] > 0),
			(red("#{@statuses['errored']} errored") if @statuses["errored"] > 0),
			(dim("#{@statuses['skipped'] + @statuses['pending']} skipped") if @statuses["skipped"] + @statuses["pending"] > 0),
		].compact

		tests = [dim("0 passed")] if tests.empty?
		total = dim(" (#{delimit(progress.tests)})") if progress.tests

		failed_to_load = @file_statuses.count { |_path, status| status == "failed to load" }
		lines << row_text("Test files", "#{progress.files_done} #{dim("of #{progress.files} done")}#{red(" · #{failed_to_load} failed to load") if failed_to_load > 0}")
		lines << row_text("Tests", tests.join(dim(" · ")) + total.to_s)
		lines << row_text("Duration", format("%.1fs", time - @started_at))
	end

	# Moves the cursor up over the live block and clears from there down. Its
	# height is counted at the terminal's width now, since a terminal that's
	# been made narrower wraps the block's lines.
	private def erase_live(columns = terminal_size&.last)
		height = @live_widths.sum { |width| columns ? [(width.to_f / columns).ceil, 1].max : 1 }
		(height > 0) ? "\e[#{height}A\e[J" : ""
	end

	private def clear_live
		return unless @cursor_hidden

		@io.print "#{erase_live}\e[?25h"
		@io.flush
		@live_widths = []
		@cursor_hidden = false
	end

	# Wide characters, such as CJK and emoji, which take two columns.
	WIDE = /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦\u{1F300}-\u{1FAFF}\u{20000}-\u{3FFFD}]/

	# Truncated to the terminal's width, counting wide characters as two
	# columns, since a wrapped line would scroll.
	private def fit(line, width)
		visible = line.gsub(ANSI, "")
		return line if columns_of(visible) < width

		taken = 0
		visible.each_char.take_while { |char| (taken += columns_of(char)) < width }.join
	end

	private def columns_of(text)
		text.size + text.scan(WIDE).size
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
	private def cyan(text) = style(text, 36)
	private def bold(text) = style(text, 1)
	private def dim(text) = style(text, 2)

	private def style(text, code)
		@color ? "\e[#{code}m#{text}\e[0m" : text
	end
end
