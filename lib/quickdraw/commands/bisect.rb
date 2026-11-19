# frozen_string_literal: true

# Finds the tests a failure depends on: those its worker ran before it, in the
# last run where it failed. Replays them before it in halves until the
# fewest that still make it fail are left.
class Quickdraw::Commands::Bisect
	include Quickdraw::Commands::Output

	FAILED = ["failed", "errored", "crashed"].freeze

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

		order = failure_order(match[:path].delete_prefix("./"), Integer(match[:line], 10))

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
		@io.puts "#{location(test)} failed after #{pluralize(before.size, 'test')} in its worker (seed #{seed})."

		replay = Quickdraw::Replay.new([test, *before].map(&:path).uniq, seed:, slot:, attempts: (2 * before.size.bit_length) + 2)

		if failed?(replay, [], test)
			@io.puts "It fails on its own too, so it doesn’t depend on the tests before it."
			return 1
		end

		unless failed?(replay, before, test)
			@io.puts "It passed when replayed after the same tests, so it may depend on timing, or on what other workers do at the same time."
			return 1
		end

		suspects = before

		while suspects.size > 1
			first, second = suspects.each_slice((suspects.size / 2.0).ceil).to_a

			suspects = if failed?(replay, first, test) then first
			elsif failed?(replay, second, test) then second
			else break
			end
		end

		@io.puts
		@io.puts bold(suspects.one? ? "It fails after:" : "It fails after these, together:")
		suspects.each { |suspect| @io.puts "  #{red('✗')} #{location(suspect)}" }
		@io.puts dim("Found in #{pluralize(replay.attempts, 'replay')}.")
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
		Quickdraw::Replay::Step.new(
			path: File.expand_path(test[:path]),
			line: test[:line],
			name: Quickdraw::Filter.name_of({ "class_name" => test[:class_name], "description" => test[:description] }),
		)
	end

	private def location(step)
		"#{step.path.delete_prefix("#{Dir.pwd}/")}:#{step.line} #{step.name}"
	end

	private def pluralize(count, noun)
		"#{count} #{noun}#{'s' unless count == 1}"
	end
end
