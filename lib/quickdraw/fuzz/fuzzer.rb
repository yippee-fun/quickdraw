# frozen_string_literal: true

# Fuzzes a property until the deadline, in a process a Session forked. Runs
# the property's saved cases and the corpus first, then cases made by changing
# corpus entries (see Mutator), and fresh ones now and then, keeping those
# that reach new edges (see Edges). Shrinks a case that fails in a way it
# hasn't seen and reports it, then carries on.
#
# Writes to `channel`, for the Session: [:fuzzing, key, methods traced] once
# it starts, [:progress, cases, new features, corpus size] every INTERVAL (so the
# session knows it isn't hanging), [:finding, Finding], and [:done].
# Writes each case's choices to `last_case` before running it, where the
# session finds the case that crashed or hung the process.
class Quickdraw::Fuzz::Fuzzer
	INTERVAL = 0.2

	# One case in this many is fresh rather than made from the corpus.
	FRESH = 10

	# `skip` has cases that crashed or hung earlier processes, not to run again.
	def initialize(channel, last_case, deadline:, seed:, skip: [])
		@channel = channel
		@last_case = last_case
		@deadline = deadline
		@random = Random.new(seed)
		@mutator = Quickdraw::Fuzz::Mutator.new(@random)
		@edges = Quickdraw::Fuzz::Edges.new
		@skip = skip.to_h { |choices| [choices, true] }
		@entries = []
		@seen = {}
		@signatures = {}
		@cases = 0
		@ran = 0
		@discarded = 0
		@reported_cases = 0
		@new_features = []
	end

	# Fuzzes `property`. Nil, since what it finds is reported as it's found.
	def call(property)
		@property = property
		@corpus = Quickdraw::Fuzz::Corpus.new(Quickdraw::Fuzz::Corpus.directory(property.key))
		traced = @edges.trace
		@channel.write([:fuzzing, property.key, traced])
		@next_progress = @next_sync = now + INTERVAL

		replay(property.saved_cases)
		read_corpus
		run(Quickdraw::Choices::EMPTY) if @entries.empty?

		until now > @deadline
			sync

			if @entries.empty? || @random.rand(FRESH) == 0
				run(Quickdraw::Choices::EMPTY, @random)
			else
				run(@mutator.call(pick, pick), @random)
			end
		end

		progress
		@channel.write([:done])

		# As a property does, once the session has what was found.
		if @ran == 0 && @discarded > 0
			raise Quickdraw::Property::Unsatisfiable, "Filters discarded all of its cases. Generate fewer values to discard."
		end

		nil
	end

	# Runs a case, keeping it in the corpus if it reached new edges or counts
	# (features), unless it came from there. A case that fails is found, not kept.
	private def run(prefix, random = nil, from_corpus: false)
		run = execute(prefix, random)
		features = @edges.take
		return unless run

		if run.failure
			found(run)
		elsif new_features?(features)
			@entries << Quickdraw::Fuzz::Mutator::Entry.new(choices: run.choices, limits: run.limits, spans: run.spans)
			@corpus.add(run.choices) unless from_corpus
		end
	end

	# Discards cases that crashed or hung earlier processes once they're drawn,
	# so they aren't run again however they're made.
	private def execute(prefix, random = nil)
		@cases += 1

		run = @property.execute(prefix, random) do |choices|
			choices.discard! if @skip.key?(choices.values)
			record(choices.values)
		end

		run ? (@ran += 1) : (@discarded += 1)
		run
	end

	# Reports the case as it was found, in case shrinking it crashes or hangs
	# the process, then again once shrunk.
	private def found(run)
		signature = run.failure.signature
		return if @signatures.key?(signature)

		@signatures[signature] = true
		cases = @cases
		report(run, cases:, shrinks: 0)
		shrinker = Quickdraw::Property::Shrinker.new(run) { |choices| shrink_attempt(choices) }
		minimal = shrinker.call
		report(minimal, original: run, cases:, shrinks: shrinker.shrinks) if shrinker.shrinks > 0
	end

	private def shrink_attempt(choices)
		run = execute(choices)
		@edges.take
		run
	end

	private def report(run, cases:, shrinks:, original: nil)
		finding = Quickdraw::Fuzz::Finding.new(
			kind: Quickdraw::Fuzz::Finding.kind(run.failure),
			key: @property.key,
			choices: run.choices,
			input: @property.inspect_values(run.choices),
			original: original && @property.inspect_values(original.choices),
			failure: run.failure,
			cases:,
			shrinks:,
		)

		@channel.write([:finding, finding])
	end

	# Until the deadline, which a large corpus could take past.
	private def replay(cases, from_corpus: false)
		cases.each do |choices|
			break if now > @deadline

			run(choices, from_corpus:)
		end
	end

	private def new_features?(features)
		fresh = features.reject { |feature| @seen.key?(feature) }
		return false if fresh.empty?

		fresh.each { |feature| @seen[feature] = true }
		@new_features.concat(fresh)
		true
	end

	# Recent entries more often, since they reached the newest code.
	private def pick
		@entries[@entries.size - 1 - (@random.rand * @random.rand * @entries.size).floor]
	end

	private def read_corpus
		replay(@corpus.unread, from_corpus: true)
	end

	# Every INTERVAL between cases: reads what other workers added to the
	# corpus, and traces methods loaded since.
	private def sync
		return if now < @next_sync

		@next_sync = now + INTERVAL
		read_corpus
		# Before tracing, which can take a while after files load, so the
		# session waits its whole timeout.
		progress
		@edges.trace
	end

	# Every INTERVAL, before a case, so the session knows it isn't hanging.
	private def heartbeat
		return if now < @next_progress

		@next_progress = now + INTERVAL
		progress
	end

	private def progress
		@channel.write([:progress, @cases - @reported_cases, @new_features, @entries.size])
		@reported_cases = @cases
		@new_features = []
	end

	# With how many cases have run, and the choices' length, in place, so it
	# costs one write.
	private def record(choices)
		heartbeat
		data = choices.pack("w*")
		@last_case.pwrite([@cases, data.bytesize].pack("Q>N") << data, 0)
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
