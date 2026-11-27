# frozen_string_literal: true

# Runs a property (see Quickdraw::Test#check): generates cases until one fails,
# then shrinks its choices to the simplest that fail the same way. That case is
# saved, and replayed first next time until it passes. Fuzzing (see
# Quickdraw::Fuzz) saves what it finds here too, so a property can have several.
#
# Runs in workers alongside user code, so it must only use core Ruby.
class Quickdraw::Property
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

		def success!(description)
			@after&.success!(description)
			nil
		end

		def failure!(failure)
			@after ? @after.failure!(failure) : @failures << failure
			nil
		end

		def error!(error)
			@after ? @after.error!(error) : @errors << error
			nil
		end

		# Once its case has ended, it passes what threads the case started
		# record on to `after`.
		def close(after)
			@after = after
		end

		def failure(error = nil)
			@errors << Quickdraw.serialize_error(error) if error
			Failure.new(failures: @failures, errors: @errors) if @errors.any? || @failures.any?
		end
	end

	Run = Data.define(:choices, :limits, :spans, :failure)

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

	# Shrinks a failing Run to the simplest choices that fail the same way:
	# fewer, or else smaller at the first that differs. It works on choices
	# rather than values, so a value shrinks however it was built: it deletes and
	# zeroes spans, lowers each choice by binary search, lowers a length while
	# deleting what it would have generated, deletes runs of adjacent spans
	# together, and swaps adjacent spans into order. The block runs choices,
	# returning their Run, or nil if they were discarded.
	class Shrinker
		ATTEMPTS = 2_000
		SECONDS = 10
		RUN = 4

		def initialize(run, attempts: ATTEMPTS, seconds: SECONDS, &execute)
			raise ::ArgumentError, "Only a failing run can be shrunk." unless run.failure

			@best = run
			@signature = run.failure.signature
			@execute = execute
			@tried = {}
			@attempts = 0
			@attempt_limit = attempts
			@deadline = now + seconds
			@shrinks = 0
		end

		# How many times a simpler case was found.
		attr_reader :shrinks

		# The simplest Run found.
		def call
			loop do
				before = @best.choices
				delete_spans
				zero_spans
				minimize_choices
				lower_and_delete if @best.choices == before
				delete_runs if @best.choices == before
				sort_spans if @best.choices == before
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

					# A nondeterministic generator can shorten the best case's choices.
					while high - low > 1 && index < @best.choices.size
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

		# Deletes runs of up to RUN adjacent spans, for values that only fail
		# without each other, such as a key, colon and value a parser needs
		# together. Only when the other passes are stuck, as it tries many cases.
		# Stops at the first that's simpler, since the spans then change.
		private def delete_runs
			starts = @best.spans.group_by(&:begin)

			@best.spans.uniq.sort_by(&:begin).any? do |first|
				run_ends(first, starts).any? { |finish| exhausted? || improve?(@best.choices.take(first.begin) + @best.choices.drop(finish)) }
			end
		end

		# Swaps adjacent spans whose choices are out of order, so values that must
		# go together but aren't adjacent, such as the 1s in [1, 3, 1], come
		# together for delete_runs. Stops at the first that's simpler.
		private def sort_spans
			starts = @best.spans.group_by(&:begin)

			@best.spans.uniq.sort_by(&:begin).any? do |first|
				starts[first.end]&.any? { |second| exhausted? || improve?(swap(first, second)) }
			end
		end

		# Where runs of two or more adjacent spans from `first` end.
		private def run_ends(first, starts)
			ends = []
			finish = first.end

			(RUN - 1).times do
				following = starts[finish]&.max_by(&:size) or break
				ends << (finish = following.end)
			end

			ends
		end

		private def delete(choices, span)
			choices.take(span.begin) + choices.drop(span.end)
		end

		private def swap(first, second)
			choices = @best.choices
			choices.take(first.begin) + choices[second] + choices[first] + choices.drop(second.end)
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
		# simpler.
		private def improve?(choices)
			return false if exhausted? || @tried.key?(choices)

			@tried[choices] = true
			@attempts += 1
			run = @execute.call(choices)

			return false unless run&.failure && run.failure.signature == @signature
			return false unless Shrinker.simpler?(run.choices, @best.choices)

			@best = run
			@shrinks += 1
			true
		end

		# Shorter, or the same length and lexicographically smaller.
		def self.simpler?(choices, than)
			case choices.size <=> than.size
			in -1 then true
			in 0 then (choices <=> than) == -1
			in 1 then false
			end
		end

		private def exhausted?
			@attempts >= @attempt_limit || now > @deadline
		end

		private def now
			Process.clock_gettime(Process::CLOCK_MONOTONIC)
		end
	end

	# How many times as many cases each property checks as it asks for, from
	# --cases-scale, or nil.
	singleton_class.attr_accessor :scale

	# Where failing cases are saved, one file per property.
	@directory = File.join(Quickdraw::ROOT, ".quickdraw/properties")

	def self.directory = @directory

	def self.directory=(path)
		@directory = path
	end

	# The file of the property named `key`'s saved cases.
	def self.path(key)
		File.join(directory, Quickdraw.stable_hash(key).to_s(16))
	end

	# The saved cases in the file at `path`, or none if it can't be read.
	# They're text, one choice per line and a blank line between cases, so
	# reading a file can't run code. Raises ArgumentError if it isn't valid.
	def self.saved(path)
		cases = File.read(path).split(/\n\s*\n/).map { |text| text.split.map { |line| Integer(line, 10) } }

		unless cases.all? { |choices| choices.size <= Quickdraw::Choices::LIMIT && choices.none?(&:negative?) }
			raise ::ArgumentError, "#{path} has invalid choices."
		end

		cases
	rescue SystemCallError
		[]
	end

	# A case that can't be saved, as in a read-only checkout, is still reported.
	# Cases without choices can't be told apart from the separators, and a
	# property that makes none fails every time anyway.
	def self.save(path, cases)
		make_directory(File.dirname(path))
		temporary = "#{path}.#{Process.pid}"
		File.write(temporary, cases.reject(&:empty?).uniq.map { |choices| choices.join("\n") }.join("\n\n"))
		File.rename(temporary, path)
	rescue SystemCallError
		nil
	end

	# Adds a failing case to the property's saved cases, after those already there.
	def self.remember(key, choices)
		path = path(key)
		cases = begin
			saved(path)
		rescue ::ArgumentError
			[]
		end

		return if cases.include?(choices)

		save(path, [*cases, choices])
		label(path, key)
	end

	# Writes the key of the property a file or directory of cases is for, next
	# to it at `path`.key, so `quickdraw fuzz --forget` can find a test's.
	def self.label(path, key)
		File.write("#{path}.key", key) unless File.exist?("#{path}.key")
	rescue SystemCallError
		nil
	end

	# The path of the test file a label at `path`.key names, or nil without one.
	def self.labelled(path)
		File.read("#{path}.key").split("\0").first
	rescue SystemCallError
		nil
	end

	private_class_method def self.make_directory(path)
		return if Dir.exist?(path)

		make_directory(File.dirname(path))
		Dir.mkdir(path)
	rescue Errno::EEXIST
		nil
	end

	# `key` names the property, for its saved cases. The block runs a case with
	# the generated values, returning its Failure, if it failed.
	def initialize(generators, cases:, seconds:, key:, &body)
		raise ::ArgumentError, "A property needs at least one generator." if generators.empty?
		raise ::ArgumentError, "A property needs a block." unless body

		@generators = generators
		@cases = self.class.scale ? [(cases * self.class.scale).ceil, 1].max : cases
		@seconds = seconds
		@key = key
		@path = self.class.path(key)
		@body = body
		# From the test's seed, so --seed repeats the same cases.
		@random = Random.new(Kernel.rand(1 << 64))
	end

	attr_reader :key

	# A Counterexample, or nil if every case passed.
	def check
		replay || explore
	end

	# Runs the case that `prefix` starts, with further choices from `random`, or
	# the simplest without it. A Run, or nil if the case was discarded. Yields
	# the Choices made before running the case, which may crash the process.
	def execute(prefix, random = nil)
		choices = Quickdraw::Choices.new(prefix, random)
		values = @generators.map { |generator| choices.draw(generator) }
		yield choices if block_given?
		Run.new(choices: choices.values, limits: choices.limits, spans: choices.spans, failure: @body.call(values))
	rescue Quickdraw::Choices::Discard
		nil
	ensure
		Quickdraw::Leaks::ThreadStarts.prune
	end

	# The cases saved from earlier runs, oldest first.
	def saved_cases
		self.class.saved(@path)
	rescue ::ArgumentError
		forget
		[]
	end

	# The values the choices make, inspected afresh: the test may have changed
	# the ones it was given.
	def inspect_values(choices)
		replay = Quickdraw::Choices.new(choices)
		text = @generators.map { |generator| Quickdraw.utf8(replay.draw(generator).inspect) }.join(", ")
		(text.size > INSPECT_LIMIT) ? "#{text[0, INSPECT_LIMIT]}…" : text
	end

	# Replays each saved case, forgetting those that pass, until one fails.
	private def replay
		saved = saved_cases

		saved.each_with_index do |choices, index|
			run = execute(choices)
			return counterexample(run, cases: nil, unreplayed: saved.drop(index + 1)) if run&.failure
		end

		forget if saved.any?
		nil
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

	private def counterexample(run, cases:, unreplayed: [])
		shrinker = Shrinker.new(run) { |choices| execute(choices) }
		minimal = shrinker.call
		self.class.save(@path, [minimal.choices, *unreplayed])
		self.class.label(@path, @key)

		Counterexample.new(
			failure: minimal.failure,
			input: inspect_values(minimal.choices),
			original: (inspect_values(run.choices) if cases),
			cases:,
			shrinks: shrinker.shrinks,
		)
	end

	# Another run may have deleted it already.
	private def forget
		File.delete(@path)
		File.delete("#{@path}.key")
	rescue SystemCallError
		nil
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
