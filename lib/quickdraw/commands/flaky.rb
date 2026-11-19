# frozen_string_literal: true

# Runs the tests several times, each with a new seed and so a new order, and
# lists those that passed in some runs and failed in others. Runs are
# recorded in the run history, so `bisect` can replay a failing one.
class Quickdraw::Commands::Flaky
	include Quickdraw::Commands::Output

	DEFAULT_RUNS = 10
	FAILED = ["failed", "errored", "crashed"].freeze
	COUNTED = [*FAILED, "passed"].freeze

	def initialize(args, io: $stdout)
		@args = args.dup
		@io = io
	end

	def call
		runs = take_runs or return 2

		options = @args.take_while { |argument| argument != "--" }

		problem = if !Process.respond_to?(:fork)
			"flaky needs fork, which this platform doesn’t support."
		elsif options.include?("--no-history")
			"flaky records its runs in the run history, so it can’t be used with --no-history."
		elsif options.intersect?(["-f", "--failed"])
			"flaky runs the same tests every time, so it can’t be used with --failed, which changes as tests pass."
		elsif options.intersect?(["-w", "--watch"])
			"flaky can’t be used with --watch."
		end

		if problem
			warn problem
			return 2
		end

		# Identifies this scan's runs, which another run of Quickdraw at the same
		# time mustn't be mixed up with. Read after each run, since history prunes old runs.
		scan = "#{Process.pid}-#{Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)}"
		outcomes = []

		runs.times do |run|
			seed = Random.new_seed % 100_000
			status = run_tests(seed, scan)
			# A usage error, or Ctrl-C.
			return status.exitstatus if status.exitstatus in 2 | 130

			recorded = read_history { |history| history.outcomes(scan:, after: outcomes.last&.fetch(:run_id) || 0).map(&:to_h) }
			return 1 if String === recorded

			if recorded.nil? || recorded.empty?
				warn "Run #{run + 1} ran no tests, or its results weren’t recorded in the run history, so there’s nothing to compare."
				return 1
			end

			outcomes.concat(recorded)
			@io.puts "#{dim("Run #{run + 1} of #{runs} · seed #{seed} ·")} #{status.success? ? green('passed') : red('failed')}"
		end

		report(runs, outcomes)
	end

	# Removes --runs N from the arguments, or prints why it can't.
	private def take_runs
		index = @args.index("--runs") or return DEFAULT_RUNS
		_, value = @args.slice!(index, 2)
		runs = Integer(value.to_s, 10, exception: false)
		return runs if runs&.positive?

		warn "--runs needs a number of runs, as in --runs 20."
		nil
	end

	# What tests print is discarded; problems with the arguments aren't.
	private def run_tests(seed, scan)
		pid = Process.fork do
			$stdout.reopen(File::NULL)
			ENV["QUICKDRAW_SCAN"] = scan
			# Before any --, after which everything is a path.
			Quickdraw::CLI.new(@args.dup.insert(@args.index("--") || @args.size, "--seed", seed.to_s)).call
		end

		Process.wait2(pid).last
	end

	private def report(runs, outcomes)
		flaky = outcomes.group_by { |outcome| outcome[:test_id] }.filter_map do |_test_id, results|
			statuses = results.map { |result| result[:status] }.select { |status| COUNTED.include?(status) }
			failed = results.select { |result| FAILED.include?(result[:status]) }
			test = results.first.values_at(:path, :line, :class_name, :description)
			[test, failed.size, statuses.size, failed.map { |result| result[:seed] }] if failed.any? && failed.size < statuses.size
		end

		@io.puts

		if flaky.empty?
			@io.puts "#{green('✓')} No flaky tests in #{runs} runs."
			return 0
		end

		@io.puts bold("Flaky tests")

		flaky.sort_by { |_test, failures, *| -failures }.each do |(path, line, class_name, description), failures, total, seeds|
			name = Quickdraw::Filter.name_of({ "class_name" => class_name, "description" => description })
			@io.puts "  #{yellow("failed #{failures} of #{total}")}  #{path}:#{line} #{name}"
			@io.puts dim("    Seeds #{seeds.uniq.join(', ')}. Find what it depends on with #{Quickdraw::Reporters.command} bisect #{path}:#{line}")
		end

		1
	end

	# Read in a throwaway process, so sqlite3 doesn't reach the processes that
	# run tests. Returns a String and prints it if the history can't be read.
	private def read_history
		result = Quickdraw.isolate do
			next unless Quickdraw::History.exist?(Quickdraw::CLI::HISTORY_PATH)

			history = Quickdraw::History.new(Quickdraw::CLI::HISTORY_PATH, read_only: true)
			yield history
		rescue Quickdraw::History::Error => error
			"Couldn’t read the run history: #{error.message}"
		ensure
			history&.close
		end

		warn result if String === result
		result
	end
end
