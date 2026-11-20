# frozen_string_literal: true

# Runs tests against mutants in parallel. One loader boots config, and each of
# its workers loads test files, then forks to run each file's tests once
# unmutated, tracing which lines of the mutated methods each test runs (see
# Tracer). Then each worker takes mutants one at a time and forks a process
# for each (see Worker#mutate). Workers only load files, so every fork starts
# from the same state, a mutant never outlives its tests, and no file changes.
class Quickdraw::Mutation::Runner
	# A test's result unmutated. `duration` is in seconds, and `lines` is what
	# it ran of each subject, as { subject id => [lines] }. `exempt` is whether
	# it's marked `mutation: false`.
	Baseline = Data.define(:path, :index, :name, :line, :status, :duration, :lines, :exempt)

	# What a mutant runs: `tests` (Baselines) in order, until one fails, for up to `seconds`.
	Job = Data.define(:mutant, :tests, :seconds)

	# With `matrix`, each mutant runs all its tests, and #call yields which
	# killed it (see Worker#mutate_every_test).
	def initialize(test_files, processes:, seed:, matrix: false)
		@pool = Quickdraw::WorkerPool.new(test_files, processes:, seed:)
		@matrix = matrix
		@traced = {}
		@lock = Thread::Mutex.new
	end

	# Ids of the subjects some worker found and traced.
	attr_reader :traced

	# See WorkerPool#start.
	def start = @pool.start

	def stop = @pool.stop

	# Loads and runs every test in `paths` unmutated, tracing `subjects`, spread
	# across the workers. Returns the Baselines, and the paths whose tests
	# couldn't run because they failed to load, crashed their process or
	# timed out.
	def baseline(paths, subjects)
		queue = Thread::Queue.new(paths).close

		results = @pool.in_slots do |slot|
			baselines = []
			failed = []

			while (path = queue.pop)
				tests = slot.load(path)
				traced, results = (run_baseline(slot, path, subjects) if tests)
				next failed << path unless results

				@lock.synchronize { traced.each { |id| @traced[id] = true } }

				results.each_with_index do |result, index|
					test = tests.fetch(index)

					baselines << Baseline.new(
						path:,
						index:,
						name: Quickdraw::Filter.name_of(test),
						line: test["line"],
						status: Quickdraw::Outcome.status(result),
						duration: result["duration"] / 1_000_000_000.0,
						lines: result["lines"],
						exempt: test["mutation"] == false,
					)
				end
			end

			[baselines, failed]
		rescue Quickdraw::WorkerPool::Gone
			[baselines, failed]
		end

		[results.flat_map(&:first), results.flat_map(&:last)]
	end

	# Runs each Job, yielding it, its outcome (see #mutate) and, with
	# `matrix`, its row, as it finishes. The outcome is ["lost"] if the
	# worker running it exited.
	def call(jobs)
		queue = Thread::Queue.new(jobs).close
		finished = Thread::Queue.new

		threads = @pool.slots.map do |slot|
			Thread.new do
				while (job = queue.pop)
					outcome, row = mutate(slot, job)
					finished << [job, outcome, row]
					break if outcome in ["lost"]
				end
			ensure
				finished << :done
			end
		end

		done = 0

		while done < threads.size
			case finished.pop
			in :done then done += 1
			in [job, outcome, row] then yield job, outcome, row
			end
		end

		threads.each(&:join)
	end

	# The ids of the subjects traced, and each test's result, in order (see
	# Worker#baseline). Nil if the tests crashed their process or timed out.
	private def run_baseline(slot, path, subjects)
		slot.write([:baseline, path, subjects])

		case slot.expect(:baseline)
		in [:baseline, _path, traced, results] then [traced, results]
		in [:baseline, _path] then nil
		end
	end

	# The outcome, as Worker#mutate gives it, but ["unloaded", path] rather
	# than ["survived"] if a test file that ran the mutant unmutated, in
	# another worker, failed to load in this one, so its tests didn't run.
	# Then the row, with `matrix`, which isn't complete if that happened.
	private def mutate(slot, job)
		tests, unloaded = job.tests.partition { |test| slot.load(test.path) }
		return [["unloaded", unloaded.first.path], nil] if tests.empty?

		slot.write([:mutant, job.mutant, tests.map { |test| [test.path, test.index] }, job.seconds, @matrix])
		_, _id, outcome, row = slot.expect(:mutant)
		row = row.merge("complete" => false) if row && unloaded.any?

		case outcome
		in ["survived"] if unloaded.any? then [["unloaded", unloaded.first.path], row]
		else [outcome, row]
		end
	rescue Quickdraw::WorkerPool::Gone
		[["lost"], nil]
	end
end
