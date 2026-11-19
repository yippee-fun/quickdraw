# frozen_string_literal: true

# Runs a property (see Quickdraw::Test#check): generates cases until one fails,
# then shrinks its choices to the simplest that fail the same way. That case is
# saved, and replayed first next time until it passes.
#
# Runs in workers alongside user code, so it must only use core Ruby.
class Quickdraw::Property
	SHRINK_ATTEMPTS = 2_000
	SHRINK_SECONDS = 10
	# Filters may discard this many cases for each that runs, after a grace.
	DISCARDS = 10
	INSPECT_LIMIT = 2_000

	class Unsatisfiable < StandardError; end

	# A case that failed: its failed assertions and errors, as a runner gets them.
	Failure = Data.define(:failures, :errors) do
		# Shrinking keeps to cases that fail at the same place, so it can't slip
		# to a different bug.
		def signature
			if (error = errors.first)
				[error["name"], error["backtrace"].first]
			else
				[failures.first["path"], failures.first["line"]]
			end
		end
	end

	# Stands in for the test's runner while a case runs.
	class Recorder
		def initialize
			@failures = []
			@errors = []
		end

		def success!(_description) = nil

		def failure!(failure)
			@failures << failure
			nil
		end

		def error!(error)
			@errors << error
			nil
		end

		def failure(error = nil)
			@errors << Quickdraw.serialize_error(error) if error
			Failure.new(failures: @failures, errors: @errors) if @errors.any? || @failures.any?
		end
	end

	Run = Data.define(:choices, :spans, :failure)

	Counterexample = Data.define(:failure, :input, :original, :cases, :shrinks) do
		def report(runner)
			first_error, *other_errors = failure.errors

			if first_error
				failure.failures.each { |it| runner.failure!(it) }
				runner.error!(first_error.merge("message" => "#{Quickdraw.utf8(first_error['message'])}\n\n#{description}"))
				other_errors.each { |it| runner.error!(it) }
			else
				first = failure.failures.first
				messages = failure.failures.map { |it| Quickdraw.utf8(it["message"]) }.join("\n\n")
				runner.failure!(first.merge("message" => "#{description}\n\n#{messages}"))
			end
		end

		def description
			found = cases ? "found after #{cases} #{(cases == 1) ? 'case' : 'cases'}" : "saved from an earlier run"
			shrunk = ", shrunk #{shrinks} #{(shrinks == 1) ? 'time' : 'times'}" if shrinks > 0
			text = "\e[34mCounterexample (#{found}#{shrunk}):\e[0m\n\n#{input}"
			text += "\n\n\e[34mShrunk from:\e[0m\n\n#{original}" if original && original != input
			text
		end
	end

	# Where failing cases are saved, one file per property.
	@directory = File.join(Quickdraw::ROOT, ".quickdraw/properties")

	def self.directory = @directory

	def self.directory=(path)
		@directory = path
	end

	# `key` names the property, for its saved case. The block runs a case with
	# the generated values, returning its Failure, if it failed.
	def initialize(generators, cases:, seconds:, key:, &body)
		raise ::ArgumentError, "A property needs at least one generator." if generators.empty?
		raise ::ArgumentError, "A property needs a block." unless body

		@generators = generators
		@cases = cases
		@seconds = seconds
		@path = File.join(self.class.directory, Quickdraw.stable_hash(key).to_s(16))
		@body = body
		# From the test's seed, so --seed repeats the same cases.
		@random = Random.new(Kernel.rand(1 << 64))
	end

	# A Counterexample, or nil if every case passed.
	def check
		replay || explore
	end

	private def replay
		return unless (choices = saved_choices)

		run = execute(choices)

		if run&.failure
			counterexample(run, cases: nil)
		else
			forget
			nil
		end
	end

	private def explore
		deadline = @seconds && (now + @seconds)
		passed = 0
		discarded = 0

		while passed < @cases && !(deadline && now > deadline)
			if (run = execute(Quickdraw::Choices::EMPTY, @random))
				return counterexample(run, cases: passed + 1) if run.failure

				passed += 1
			elsif (discarded += 1) > DISCARDS * (passed + 10)
				unsatisfiable(discarded, passed)
			end
		end

		unsatisfiable(discarded, passed) if passed == 0 && discarded > 0

		nil
	end

	private def unsatisfiable(discarded, passed)
		raise Unsatisfiable, "Filters discarded #{discarded} cases while #{passed} ran. Generate fewer values to discard."
	end

	private def execute(prefix, random = nil)
		choices = Quickdraw::Choices.new(prefix, random)
		values = @generators.map { |generator| choices.draw(generator) }
		Run.new(choices: choices.values, spans: choices.spans, failure: @body.call(values))
	rescue Quickdraw::Choices::Discard
		nil
	end

	private def counterexample(run, cases:)
		minimal = shrink(run)
		save(minimal.choices)

		Counterexample.new(
			failure: minimal.failure,
			input: inspect_values(minimal.choices),
			original: (inspect_values(run.choices) if cases),
			cases:,
			shrinks: @shrinks,
		)
	end

	private def shrink(run)
		@best = run
		@signature = run.failure.signature
		@tried = {}
		@attempts = 0
		@shrinks = 0
		@deadline = now + SHRINK_SECONDS

		loop do
			before = @best.choices
			delete_spans
			zero_spans
			minimize_choices
			lower_and_delete if @best.choices == before
			break if @best.choices == before || exhausted?
		end

		@best
	end

	# Deletes each span, largest first, such as an array's items.
	private def delete_spans
		index = 0

		while !exhausted? && (span = spans[index])
			index += 1 unless improve?(delete(@best.choices, span))
		end
	end

	# Replaces each span's choices with zeros: the simplest value in its place.
	private def zero_spans
		index = 0

		while !exhausted? && (span = spans[index])
			choices = @best.choices
			improve?(choices.dup.fill(0, span)) if choices[span].any?(&:positive?)
			index += 1
		end
	end

	# Lowers each choice as far as it can, by binary search.
	private def minimize_choices
		index = 0

		while !exhausted? && index < @best.choices.size
			choice = @best.choices[index]

			if choice > 0 && !improve?(replace(index, 0))
				low = 0
				high = choice

				while high - low > 1
					middle = (low + high) / 2

					if improve?(replace(index, middle))
						high = middle
					else
						low = middle
					end
				end
			end

			index += 1
		end
	end

	# Lowers a choice by one while deleting a span after it, for when the choice
	# is how many values follow, as with a length chosen in flat_map. Only when
	# the other passes are stuck, as it tries many cases.
	private def lower_and_delete
		index = 0

		while !exhausted? && index < @best.choices.size
			lowered = @best.choices[index] > 0 && spans.sort_by(&:begin).any? do |span|
				span.begin > index && improve?(delete(replace(index, @best.choices[index] - 1), span))
			end

			index += 1 unless lowered
		end
	end

	private def delete(choices, span)
		choices.take(span.begin) + choices.drop(span.end)
	end

	private def spans
		@best.spans.uniq.sort_by! { |span| [-span.size, span.begin] }
	end

	private def replace(index, choice)
		choices = @best.choices.dup
		choices[index] = choice
		choices
	end

	# Runs the choices, keeping them if they fail as the best case did and are
	# simpler: fewer, or else smaller at the first that differs.
	private def improve?(choices)
		return false if exhausted? || @tried.key?(choices)

		@tried[choices] = true
		@attempts += 1
		run = execute(choices)

		return false unless run&.failure && run.failure.signature == @signature
		return false unless simpler?(run.choices, @best.choices)

		@best = run
		@shrinks += 1
		true
	end

	private def simpler?(choices, than)
		case choices.size <=> than.size
		in -1 then true
		in 0 then (choices <=> than) == -1
		in 1 then false
		end
	end

	private def exhausted?
		@attempts >= SHRINK_ATTEMPTS || now > @deadline
	end

	# The values the choices make, inspected afresh: the test may have changed
	# the ones it was given.
	private def inspect_values(choices)
		replay = Quickdraw::Choices.new(choices)
		text = @generators.map { |generator| Quickdraw.utf8(replay.draw(generator).inspect) }.join(", ")
		(text.size > INSPECT_LIMIT) ? "#{text[0, INSPECT_LIMIT]}…" : text
	end

	# Saved as text, one choice per line, so reading a file can't run code.
	private def saved_choices
		choices = File.read(@path).split.map { |line| Integer(line, 10) }
		return choices if choices.size <= Quickdraw::Choices::LIMIT && choices.none?(&:negative?)

		forget
		nil
	rescue ArgumentError
		forget
		nil
	rescue SystemCallError
		nil
	end

	# A case that can't be saved, as in a read-only checkout, is still reported.
	private def save(choices)
		make_directory(File.dirname(@path))
		temporary = "#{@path}.#{Process.pid}"
		File.write(temporary, choices.join("\n"))
		File.rename(temporary, @path)
	rescue SystemCallError
		nil
	end

	# Another run may have deleted it already.
	private def forget
		File.delete(@path)
	rescue SystemCallError
		nil
	end

	private def make_directory(path)
		return if Dir.exist?(path)

		make_directory(File.dirname(path))
		Dir.mkdir(path)
	rescue Errno::EEXIST
		nil
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
