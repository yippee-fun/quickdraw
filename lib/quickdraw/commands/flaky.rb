# frozen_string_literal: true

# Runs the tests several times, each with a new seed and so a new order, and
# lists those that passed in some runs and failed in others. Runs are
# recorded in the run history, so `bisect` can replay a failing one.
class Quickdraw::Commands::Flaky
	include Quickdraw::Commands::Output

	DEFAULT_RUNS = 10
	FAILED = ["failed", "errored", "crashed", "flaky"].freeze
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

			if status.signaled?
				warn "Run #{run + 1} was killed by SIG#{Signal.signame(status.termsig)}."
				return 128 + status.termsig
			end

			# A usage error, or Ctrl-C.
			return status.exitstatus if status.exitstatus in 2 | 130

			recorded = read_history { |history| history.outcomes(scan:, after: outcomes.last&.fetch(:run_id) || 0).map(&:to_h) }
			return 1 if String === recorded

			if recorded.nil? || recorded.empty?
				warn "Run #{run + 1} ran no tests, or its results weren’t recorded in the run history, so there’s nothing to compare."
				return 1
			end

			outcomes.concat(recorded)
			@io.puts "  #{status.success? ? green('✓') : red('✗')} run #{(run + 1).to_s.rjust(runs.to_s.size)} of #{runs}  #{dim("seed #{seed}")}"
		end

		report(runs, outcomes)
	end

	# Removes --runs N or --runs=N from the arguments, or prints why it can't.
	private def take_runs
		options = @args.take_while { |argument| argument != "--" }
		index = options.index { |argument| argument.match?(/\A--runs(?:=|\z)/) } or return DEFAULT_RUNS

		value = case @args.delete_at(index)
		in "--runs" then @args.delete_at(index)
		in argument then argument.delete_prefix("--runs=")
		end

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
			# Before any --, after which everything is a path. Without retries, so each
			# run counts a test once.
			Quickdraw::CLI.new(@args.dup.insert(@args.index("--") || @args.size, "--seed", seed.to_s, "--retry", "0")).call
		end

		# So Ctrl-C only stops the run, which exits with 130.
		previous = trap("INT", "IGNORE")
		status = Process.wait2(pid).last
		trap("INT", previous)
		status
	end

	private def report(runs, outcomes)
		flaky = outcomes.group_by { |outcome| outcome[:test_id] }.filter_map do |_test_id, results|
			statuses = results.map { |result| result[:status] }.select { |status| COUNTED.include?(status) }
			failed = results.select { |result| FAILED.include?(result[:status]) }
			test = results.first.values_at(:path, :line, :class_name, :description, :variant)
			[test, failed.size, statuses.size, failed.map { |result| result[:seed] }] if failed.any? && failed.size < statuses.size
		end

		if flaky.empty?
			@io.puts
			@io.puts "#{label('PASSED', 42)} No flaky tests in #{runs} runs"
			return 0
		end

		flaky.sort_by { |_test, failures, *| -failures }.each do |(path, line, class_name, description, variant), failures, total, seeds|
			indent = beside_label("FLAKY")
			@io.puts
			@io.puts "#{label('FLAKY', 43)} #{test_heading(path, line, class_name, description, variant)}"
			@io.puts "#{indent}#{yellow("failed #{failures} of #{total} runs")} #{dim("· #{seeds.uniq.one? ? 'seed' : 'seeds'} #{seeds.uniq.join(', ')}")}"
			@io.puts "#{indent}#{dim("⌕ #{Quickdraw::Reporters.command} bisect #{path}:#{line}")}"
		end

		@io.puts
		@io.puts "#{label('FAILED', 41)} #{flaky.size} flaky #{flaky.one? ? 'test' : 'tests'} in #{runs} runs"
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
