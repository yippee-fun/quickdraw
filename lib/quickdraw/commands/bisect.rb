# frozen_string_literal: true

# Finds the tests a failure depends on: those its worker ran before it, in the
# last run where it failed. Replays them before it in halves until the
# fewest that still make it fail are left.
class Quickdraw::Commands::Bisect
	include Quickdraw::Commands::Output

	FAILED = ["failed", "errored", "crashed", "flaky"].freeze

	def initialize(args, io: $stdout)
		@args = args
		@io = io
	end

	def call
		match = (/\A(?<path>.+):(?<line>\d+)\z/.match(@args.first) if @args.one?)

		unless match
			warn "Usage: #{Quickdraw::Reporters.command} bisect PATH:LINE"
			return 2
		end

		unless Process.respond_to?(:fork)
			warn "bisect needs fork, which this platform doesn’t support."
			return 2
		end

		order = failure_order(File.expand_path(match[:path]).delete_prefix("#{Dir.pwd}/"), Integer(match[:line], 10))

		case order
		in String => message
			warn message
			1
		in nil
			warn "#{@args.first} hasn’t failed in the run history, so there’s nothing to bisect."
			1
		in { test:, before:, seed:, slot: }
			bisect(step(test), before.map { |it| step(it) }, seed:, slot:)
		end
	end

	private def bisect(test, before, seed:, slot:)
		@io.puts "#{label('BISECT', 44)} #{heading(test)}"
		@io.puts "#{beside_label('BISECT')}#{dim("failed after #{pluralize(before.size, 'test')} in its worker · seed #{seed}")}"
		@io.puts

		replay = Quickdraw::Replay.new([test, *before].map(&:path).uniq, seed:, slot:, attempts: (4 * before.size.bit_length) + 2, variant: @tests.fetch(test)[:variant])

		if failed?(replay, [], test)
			@io.puts "#{label('FAILS ALONE', 41)} It fails on its own too, so it doesn’t depend on the tests before it."
			return 1
		end

		if before.empty? || !failed?(replay, before, test)
			@io.puts "#{label('INCONCLUSIVE', 43)} It passed when replayed after the same tests, so it may depend on timing, or on what other workers do at the same time."
			return 1
		end

		suspects = reduce(replay, test, before, before)

		indent = beside_label("FOUND")
		@io.puts "#{label('FOUND', 42)} #{suspects.one? ? 'It fails after this test:' : 'It fails after these tests, together:'}"
		suspects.each { |suspect| @io.puts "#{indent}#{red('✗')} #{heading(suspect)}" }
		@io.puts "#{indent}#{dim("Found in #{pluralize(replay.attempts, 'replay')}.")}"
		0
	rescue Quickdraw::Replay::BootFailed => error
		@io.puts "Couldn’t boot to replay tests: #{error.message}"
		1
	rescue Missing
		@io.puts "Couldn’t find #{location(test)} to replay it. It may have been renamed or moved, or its file may not load."
		1
	ensure
		replay&.stop
	end

	# The fewest of `suspects` that, run in their original order with `kept`,
	# make the test fail. When neither half does alone, tests in both are
	# needed: the second half is reduced with all of the first, then the first
	# with what's left of the second. Out of replays, it stops where it is.
	private def reduce(replay, test, suspects, before, kept = [])
		return suspects if suspects.size <= 1 || replay.attempts_left < 2

		first, second = suspects.each_slice((suspects.size / 2.0).ceil).to_a
		in_order = -> (tests) { before & (kept + tests) }

		if failed?(replay, in_order.(first), test)
			reduce(replay, test, first, before, kept)
		elsif failed?(replay, in_order.(second), test)
			reduce(replay, test, second, before, kept)
		else
			needed_second = reduce(replay, test, second, before, kept + first)
			reduce(replay, test, first, before, kept + needed_second) + needed_second
		end
	end

	# The test couldn't be replayed, so whether it fails can't be known.
	class Missing < StandardError; end

	private def failed?(replay, before, test)
		status = replay.call([*before, test]).last
		raise Missing if status == "missing"

		FAILED.include?(status)
	end

	# Read in a throwaway process, so sqlite3 doesn't reach the processes that
	# replay tests.
	private def failure_order(path, line)
		Quickdraw.isolate do
			history_path = Quickdraw::CLI::HISTORY_PATH
			next "There’s no run history yet, so there’s nothing to bisect." unless Quickdraw::History.exist?(history_path)

			history = Quickdraw::History.new(history_path, read_only: true)
			order = history.failure_order(path, line)
			order && { test: order.test.to_h, before: order.before.map(&:to_h), seed: order.seed, slot: order.slot }
		rescue Quickdraw::History::Error => error
			"Couldn’t read the run history: #{error.message}"
		ensure
			history&.close
		end
	end

	private def step(test)
		@tests ||= {}
		step = Quickdraw::Replay::Step.new(
			path: File.expand_path(test[:path]),
			line: test[:line],
			name: Quickdraw::Filter.name_of({ "class_name" => test[:class_name], "description" => test[:description], "variant" => test[:variant] }),
		)
		@tests[step] = test
		step
	end

	private def location(step)
		"#{step.path.delete_prefix("#{Dir.pwd}/")}:#{step.line} #{step.name}"
	end

	# As test runs show a test.
	private def heading(step)
		test = @tests.fetch(step)
		test_heading(test[:path], test[:line], test[:class_name], test[:description], test[:variant])
	end

	private def pluralize(count, noun)
		"#{count} #{noun}#{'s' unless count == 1}"
	end
end
