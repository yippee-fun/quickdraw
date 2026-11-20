# frozen_string_literal: true

# For people, in a terminal or a CI log: a line for each test file as it
# finishes, then each problem in full, then a summary. The output scrolls,
# and reads the same anywhere. When `live`, a status line with a spinner
# sits under the file lines while the run goes, and is gone at the end.
class Quickdraw::Reporters::Human
	include Quickdraw::Reporters::Formatting

	# Below this much total test time, shares and hints are mostly noise.
	HINT_THRESHOLD = 1.0
	SLOWEST_LIMIT = 10
	LEAK_LIMIT = 20
	PROFILE_LIMIT = 20
	COVERAGE_LIMIT = 10
	# Lines shown either side of a failing line.
	CODE_FRAME_CONTEXT = 1
	# The labels of --timings' rows, right-aligned to the longest.
	LABEL_WIDTH = 10
	# Paths longer than this aren't padded to line up with the rest.
	PATH_WIDTH = 60
	# Skip reasons, and pending tests, named in the summary.
	NOTE_LIMIT = 3
	# Characters of a skip reason shown in the summary.
	REASON_WIDTH = 60

	# A test file's results so far: how many, the time they took, and how many
	# had each status.
	FileTally = Struct.new(:tests, :duration, :statuses) do
		def initialize = super(0, 0.0, Hash.new(0))
	end

	# `command` runs the run's tests again, such as `qt browser`.
	def initialize(io: $stdout, backtrace: false, timings: false, live: false, command: Quickdraw::Reporters.command)
		@io = io
		@command = command
		@backtrace = backtrace
		@show_timings = timings
		@timings = Quickdraw::Timings.new
		@profile = Quickdraw::Profile.new
		@color = io.tty? && !ENV.key?("NO_COLOR")
		@status_line = Quickdraw::Reporters::StatusLine.new(io:, live:, color: @color)
		@problems = []
		# By path, then variant (see Reporters).
		@tallies = Hash.new { |paths, path| paths[path] = Hash.new { |variants, variant| variants[variant] = FileTally.new } }
		@set_aside = []
		@leaks = []
		# The worst that happened in each file with a problem, by path with variant.
		@file_statuses = {}
		@path_width = 0
	end

	# Before config boots, which can take a while, so the spinner shows it's going.
	def booting
		@status_line.start
	end

	def start(processes:, worker_choice:, seed:, paths:, estimate: nil, capture: true)
		@worker_choice = worker_choice
		@processes = processes
		@seed = seed
		@estimate = estimate
		@status_line.files = paths.size
		@path_width = [paths.map(&:size).max || 0, PATH_WIDTH].min
		# As config may have said, tests print to the terminal, under which the status line would be lost.
		@status_line.stop unless capture
	end

	def result(path, test, result)
		@timings.record(path, test, result)
		@profile.record(result)
		status = result["quarantined"] ? "quarantined" : Quickdraw::Outcome.status(result)
		tally = @tallies[path][test["variant"]]
		tally.tests += 1
		tally.duration += result["duration"].to_f
		tally.statuses[status] += 1
		@status_line.test_done(status)

		case status
		in "failed" | "errored"
			@file_statuses[with_variant(path, test["variant"])] = "failed"
			@problems << [path, test, result]
		in "flaky" | "quarantined"
			@file_statuses[with_variant(path, test["variant"])] ||= "flaky"
			@problems << [path, test, result]
		in "skipped" | "pending" then @set_aside << [path, test, result["skipped"]]
		in "passed" then nil
		end

		@leaks << [path, test, result["leaks"]] if result["leaks"]
	end

	def finished_file(path, variant)
		@status_line.file_done
		@status_line.above { print_file(path, variant) }
	end

	# A file with no tests to run, as none matched a filter, gets no line, but counts as done.
	def nothing_to_run(_path, _variant)
		@status_line.file_done
		@status_line.redraw
	end

	def load_failed(path, error, variant)
		@file_statuses[with_variant(path, variant)] = "failed to load"
		@problems << [path, nil, { "errors" => [error], "failures" => [], "variant" => variant }]
		@status_line.file_done
		@status_line.above { @io.puts "#{red('✗')} #{path_column(with_variant(path, variant))}  #{red('could not be loaded')}" }
	end

	def shows_loading_output? = true

	# What loading a test file printed, whole, so it isn't mixed into a line.
	def printed(output)
		@status_line.above do
			@io.print output
			@io.puts unless output.end_with?("\n")
		end
	end

	def pause
		@status_line.pause
	end

	def resume
		@status_line.resume
	end

	def finish(outcome)
		@status_line.stop

		# Each in full, after the file lines, which stay short.
		@problems.each { |path, test, result| print_problem(path, test, result) }

		if @show_timings
			print_slowest
			print_timing_summary(outcome) unless outcome.interrupted
			print_hints(outcome) unless outcome.interrupted
		end

		print_profile if @profile.any?
		print_leaks if @leaks.any?
		print_coverage(outcome.coverage) if outcome.coverage
		print_summary(outcome)
	end

	private def print_file(path, variant)
		tally = @tallies.fetch(path).fetch(variant)
		label = with_variant(path, variant)

		mark = case @file_statuses[label]
			in "failed" then red("✗")
			in "flaky" then yellow("~")
			in nil then green("✓")
		end

		statuses = tally.statuses
		details = [
			dim("#{pluralize(tally.tests, 'test')} · #{seconds(tally.duration)}"),
			(red("#{statuses['failed']} failed") if statuses["failed"] > 0),
			(red("#{statuses['errored']} errored") if statuses["errored"] > 0),
			(yellow("#{statuses['flaky']} flaky") if statuses["flaky"] > 0),
			(yellow("#{statuses['quarantined']} quarantined") if statuses["quarantined"] > 0),
			(dim("#{statuses['skipped']} skipped") if statuses["skipped"] > 0),
			(dim("#{statuses['pending']} pending") if statuses["pending"] > 0),
		].compact

		@io.puts "#{mark} #{path_column(label)}  #{details.join(dim(' · '))}"
	end

	# The directory dimmed, padded so details line up for paths that fit.
	private def path_column(path)
		directory, slash, name = path.rpartition("/")
		"#{dim("#{directory}#{slash}")}#{name}#{' ' * [@path_width - path.size, 0].max}"
	end

	private def print_problem(path, test, result)
		@io.puts

		if test
			@io.puts "#{badge(result)} #{bold(test['description'] || "line #{test['line']}")}  #{dim([test['class_name'], "#{path}:#{test['line']}", test['variant']].compact.join(' · '))}"
		else
			@io.puts "#{badge(result)} #{bold(with_variant(path, result['variant']))} could not be loaded"
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
			@io.puts "  #{dim("⌕ #{bisect_command(path, test)}")}" if bisect?(result)
		end

		if result["quarantined"]
			@io.puts
			@io.puts "  #{yellow(QUARANTINED)}"
		end

		@io.puts
		@io.puts "  #{dim("↻ #{rerun_command(path, test, problem_variant(test, result))}")}"
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
		return label("QUARANTINED", 43) if result["quarantined"]

		case Quickdraw::Outcome.status(result)
		in "flaky" then label("FLAKY", 43)
		in "errored" then label("ERROR", 41)
		in "failed" then label("FAIL", 41)
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

	# Shares that are too small to matter are left out.
	private def print_timing_summary(outcome)
		@io.puts
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

	# A line of --timings' rows, its label right-aligned in a column.
	private def row(label, text)
		@io.puts " #{dim(label.rjust(LABEL_WIDTH))}  #{text}"
	end

	# Around hooks run outside the measured phases. Below about 1ms per test, the
	# time outside phases is Quickdraw's own overhead, so it isn't shown.
	private def phase_breakdown(timings)
		parts = Quickdraw::PHASES.map { |phase| "#{phase} #{percent(timings.phase_share(phase))}" }
		around = timings.outside_phases_time
		parts << "plus #{seconds(around)} in around hooks" if around / timings.count >= 0.001
		parts.join(", ")
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

		# The summary says when the slowest test bounds the run.
		if @processes > 1 && elapsed >= 2 && utilization < 0.6 && !run_bound_by_slowest(outcome)
			hints << "Workers spent #{percent(1 - utilization)} of the run not running tests " \
				"(booting, loading files or waiting for work)."
		end

		indent = " " * (LABEL_WIDTH + 3)
		hints.each { |hint| @io.puts "#{indent}#{yellow('!')} #{hint}" }
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

	# The verdict and the counts, then each problem, then how to rerun them,
	# then anything else worth knowing, a line each.
	private def print_summary(outcome)
		@io.puts
		@io.puts "#{verdict(outcome)}  #{counts(outcome)}"

		if @problems.any?
			@io.puts
			@problems.each { |path, test, result| @io.puts "  #{recap(path, test, result)}" }
		end

		print_notes([
			(["Rerun failures", "#{@command} --failed"] if @problems.any? && outcome.recorded),
			(["Same order", "#{@command} --seed #{@seed}"] unless outcome.passed?),
		].compact) { |label| dim(label) }
		print_notes(notes(outcome)) { |label| yellow(label) }
	end

	private def verdict(outcome)
		if outcome.interrupted then label("INTERRUPTED", 43)
		elsif outcome.passed? then label("PASSED", 42)
		else label("FAILED", 41)
		end
	end

	# How many tests and assertions, each count in the colour of what it means,
	# then how long the run took.
	private def counts(outcome)
		failed_to_load = @file_statuses.count { |_path, status| status == "failed to load" }

		[
			pluralize(outcome.tests, "test"),
			"#{delimit(outcome.assertions)} #{(outcome.assertions == 1) ? 'assertion' : 'assertions'}",
			(red("#{outcome.failed} failed") if outcome.failed > 0),
			(yellow("#{outcome.flaky} flaky#{' (allowed)' if outcome.allow_flaky}") if outcome.flaky > 0),
			(yellow("#{outcome.quarantined} quarantined") if outcome.quarantined > 0),
			(dim("#{outcome.skipped} skipped") if outcome.skipped > 0),
			(dim("#{outcome.pending} pending") if outcome.pending > 0),
			(red("#{outcome.errored} errored") if outcome.errored > 0),
			(red("#{pluralize(failed_to_load, 'file')} failed to load") if failed_to_load > 0),
			(yellow("#{outcome.not_run} not run") if outcome.not_run > 0),
			(yellow("#{pluralize(outcome.unloaded_files, 'file')} not loaded") if outcome.unloaded_files > 0),
			format("%.2fs", outcome.duration),
		].compact.join(dim(" · "))
	end

	private def recap(path, test, result)
		return "#{red('✗')} #{with_variant(path, result['variant'])} could not be loaded" unless test

		"#{marker(result)} #{path}:#{test['line']} #{name_of(test)}#{dim(' (quarantined)') if result['quarantined']}#{dim(' (flaky)') if result['passed_on_retry'] && !result['quarantined']}"
	end

	private def marker(result)
		(result["passed_on_retry"] || result["quarantined"]) ? yellow("~") : red("✗")
	end

	# [label, text] pairs, under each other, their labels lined up.
	private def print_notes(notes)
		return if notes.empty?

		width = notes.map { |label, _text| label.size }.max
		@io.puts
		notes.each { |label, text| @io.puts "  #{yield(label.ljust(width))}  #{text}" }
	end

	private def notes(outcome)
		notes = []
		notes << ["Interrupted", "Tests that were running or hadn’t started count as not run."] if outcome.interrupted
		notes << ["Fail fast", "Stopped after the first problem."] if !outcome.interrupted && outcome.stopped_early && (outcome.not_run + outcome.unloaded_files) > 0
		notes << ["No match", "No tests matched the given lines, --name or --exclude."] if outcome.nothing_matched
		notes << ["Exit status", "A worker or the loader exited with a failure status, e.g. from an at_exit hook."] if outcome.processes_failed && @problems.empty?

		skipped = @set_aside.reject { |_path, _test, skipped| skipped["pending"] }
		notes << ["Skipped", skip_reasons(skipped)] if skipped.any?

		pending = @set_aside.select { |_path, _test, skipped| skipped["pending"] }
		notes << ["Pending", listed(pending.map { |path, test, _skipped| "#{path}:#{test['line']} #{name_of(test)}" })] if pending.any?
		notes << ["Left out", left_out(outcome)] if outcome.browser_files_left_out > 0

		if (slowest = run_bound_by_slowest(outcome))
			notes << ["Slow", "#{location(slowest)} took #{seconds(slowest.duration)}, #{percent(slowest.duration / outcome.duration)} of the run."]
		end

		notes
	end

	# The most common reasons first, with how many tests gave each.
	private def skip_reasons(skipped)
		reasons = skipped.map { |_path, _test, skipped| reason(skipped["reason"]) }
		listed(reasons.tally.sort_by { |reason, count| [-count, reason] }.map { |reason, count| "#{reason} (#{count})" }, separator: " · ")
	end

	private def reason(text)
		first_line = plain(text.to_s).lines.first.to_s.strip
		first_line.empty? ? "no reason given" : truncate(first_line, REASON_WIDTH)
	end

	private def listed(items, separator: ", ")
		shown = items.first(NOTE_LIMIT).join(separator)
		(items.size > NOTE_LIMIT) ? "#{shown}#{separator}and #{items.size - NOTE_LIMIT} more" : shown
	end

	private def truncate(text, width)
		(text.size > width) ? "#{text[0, width - 1]}…" : text
	end

	# The slowest test, if it took at least half the run, so splitting it up
	# would shorten the run.
	private def run_bound_by_slowest(outcome)
		return if outcome.interrupted || @processes <= 1 || @timings.count == 0

		slowest = @timings.slowest_tests(1).first
		slowest if slowest.duration >= HINT_THRESHOLD && slowest.duration >= outcome.duration * 0.5
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

	private def clean(text)
		@color ? Quickdraw.utf8(text) : plain(text)
	end

	# Dark text on a coloured background, or just the text without colour.
	private def label(text, background)
		@color ? "\e[1;30;#{background}m #{text} \e[0m" : text
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
