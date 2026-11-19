# frozen_string_literal: true

# Recent runs, and the slowest and flakiest tests, from the run history.
class Quickdraw::Commands::History
	include Quickdraw::Commands::Output
	include Quickdraw::Reporters::Formatting

	RECENT_RUNS = 10
	SLOWEST_TESTS = 10
	FLAKY_WINDOW = 50

	def initialize(args, io: $stdout)
		@args = args
		@io = io
	end

	def call
		unless @args.empty?
			warn "Usage: #{Quickdraw::Reporters.command} history"
			return 2
		end

		# Opening the history creates it.
		return no_history unless Quickdraw::History.exist?(Quickdraw::CLI::HISTORY_PATH)

		history = Quickdraw::History.new(Quickdraw::CLI::HISTORY_PATH, read_only: true)
		runs = history.runs(limit: RECENT_RUNS)
		return no_history if runs.empty?

		print_runs(runs)
		print_slowest(history.slowest_tests(limit: SLOWEST_TESTS))
		print_flaky(history.flaky_tests(within: FLAKY_WINDOW))
		0
	rescue Quickdraw::History::Error => error
		warn "Couldn’t read the run history: #{error.message}"
		1
	ensure
		history&.close
	end

	private def no_history
		@io.puts "No run history yet. It’s recorded in #{Quickdraw::CLI::HISTORY_PATH} each time tests run."
		1
	end

	# In columns: when, how many tests, what went wrong, how long, then details.
	private def print_runs(runs)
		now = Time.now

		rows = runs.map do |run|
			problems = [
				("#{run.failed} failed" if run.failed > 0),
				("#{run.errored} errored" if run.errored > 0),
			].compact.join(" · ")

			[run, ago(now - run.finished_at), pluralize(run.tests, "test"), problems, seconds(run.duration)]
		end

		widths = (1..4).map { |column| rows.map { |row| row[column].size }.max }

		@io.puts bold("Recent runs")

		rows.each do |run, age, tests, problems, duration|
			@io.puts [
				"  #{run.passed ? green('✓') : red('✗')}",
				dim(age.rjust(widths[0])),
				tests.rjust(widths[1]),
				red(problems.ljust(widths[2])),
				duration.rjust(widths[3]),
				dim(["#{pluralize(run.processes, 'worker')} (#{run.worker_choice})", "seed #{run.seed}", revision(run)].compact.join(" · ")),
			].join("  ")
		end
	end

	BAR_WIDTH = 12
	BAR_EIGHTHS = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"].freeze

	# With bars against the slowest, so the shape of the suite shows at a glance.
	private def print_slowest(tests)
		return if tests.empty?

		longest = tests.map(&:average_duration).max
		durations = tests.map { |test| seconds(test.average_duration) }
		width = durations.map(&:size).max

		@io.puts
		@io.puts bold("Slowest tests")

		tests.zip(durations) do |test, duration|
			@io.puts "  #{cyan(bar(test.average_duration / longest).ljust(BAR_WIDTH))}  #{duration.rjust(width)}  #{heading(test)}"
		end
	end

	private def bar(fraction)
		eighths = (fraction * BAR_WIDTH * 8).round
		("█" * (eighths / 8)) + BAR_EIGHTHS[eighths % 8]
	end

	private def print_flaky(tests)
		return if tests.empty?

		counts = tests.map { |test| "failed #{test.failures} of #{test.runs}" }
		width = counts.map(&:size).max

		@io.puts
		@io.puts "#{bold('Flaky tests')} #{dim('· passed and failed on the same code, or passed when retried')}"
		tests.zip(counts) { |test, count| @io.puts "  #{yellow(count.ljust(width))}  #{heading(test)}" }
		@io.puts "  #{dim("⌕ #{Quickdraw::Reporters.command} bisect PATH:LINE finds the tests a flaky test depends on")}"
	end

	private def heading(test)
		test_heading(test.path, test.line, test.class_name, test.description)
	end

	# The short commit and branch, or nil outside a git repository.
	private def revision(run)
		return unless run.git_sha

		branch = run.git_branch unless run.git_branch == "HEAD"
		[run.git_sha[0, 7], branch].compact.join(" ")
	end

	private def ago(elapsed)
		elapsed = elapsed.clamp(0..)

		case elapsed
		in ...60 then "#{elapsed.floor}s ago"
		in ...3600 then "#{(elapsed / 60).floor}m ago"
		in ...86_400 then "#{(elapsed / 3600).floor}h ago"
		else "#{(elapsed / 86_400).floor}d ago"
		end
	end

	private def seconds(value)
		Quickdraw::Timer::Duration.new(value * 1_000_000_000).to_s
	end
end
