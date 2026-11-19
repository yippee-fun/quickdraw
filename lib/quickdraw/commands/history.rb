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
		return no_history unless File.exist?(Quickdraw::CLI::HISTORY_PATH)

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

	private def print_runs(runs)
		now = Time.now
		ages = runs.map { |run| ago(now - run.finished_at) }
		width = ages.map(&:size).max

		@io.puts bold("Recent runs")

		runs.zip(ages) do |run, age|
			details = [
				pluralize(run.tests, "test"),
				(red("#{run.failed} failed") if run.failed > 0),
				(red("#{run.errored} errored") if run.errored > 0),
				seconds(run.duration),
				dim(["#{pluralize(run.processes, 'worker')} (#{run.worker_choice})", "seed #{run.seed}", revision(run)].compact.join(" · ")),
			]

			@io.puts "  #{run.passed ? green('✓') : red('✗')} #{dim(age.rjust(width))}  #{details.compact.join(' · ')}"
		end
	end

	private def print_slowest(tests)
		return if tests.empty?

		@io.puts
		@io.puts bold("Slowest tests")
		tests.each { |test| @io.puts "  #{seconds(test.average_duration).rjust(8)}  #{location(test)}" }
	end

	private def print_flaky(tests)
		return if tests.empty?

		counts = tests.map { |test| "failed #{test.failures} of #{test.runs}" }
		width = counts.map(&:size).max

		@io.puts
		@io.puts "#{bold('Flaky tests')} #{dim('· passed and failed on the same code')}"
		tests.zip(counts) { |test, count| @io.puts "  #{yellow(count.ljust(width))}  #{location(test)}" }
	end

	private def location(test)
		"#{test.path}:#{test.line} #{name_of({ 'class_name' => test.class_name, 'description' => test.description })}"
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
