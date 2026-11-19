# frozen_string_literal: true

# Runs tests against mutants in parallel. One loader boots config, and each of
# its workers loads test files, then forks to run each file's tests once
# unmutated, tracing which lines of the mutated methods each test runs (see
# Tracer). Then each worker takes mutants one at a time and forks a process
# for each (see Worker#mutate). Workers only load files, so every fork starts
# from the same state, a mutant never outlives its tests, and no file changes.
class Quickdraw::Mutation::Runner
	# How often to check that a worker is still alive while waiting for it.
	LIVENESS_INTERVAL = 0.5

	# A test's result unmutated. `duration` is in seconds, and `lines` is what
	# it ran of each subject, as { subject id => [lines] }.
	Baseline = Data.define(:path, :index, :name, :line, :status, :duration, :lines)

	# What a mutant runs: `tests` (Baselines) in order, until one fails, for up to `seconds`.
	Job = Data.define(:mutant, :tests, :seconds)

	# A worker exited, or its pipe closed.
	class Gone < StandardError; end

	def initialize(test_files, processes:, seed:)
		@test_files = test_files
		@processes = processes
		@seed = seed
		@traced = {}
		@lock = Thread::Mutex.new
	end

	# Ids of the subjects some worker found and traced.
	attr_reader :traced

	# Boots config and starts the workers. Returns the groups config defines,
	# as [name, patterns, gemfile], whose tests need loaders of their own.
	# Raises Replay::BootFailed if config raises.
	def start
		pairs = Array.new(@processes) { Quickdraw::Channel.pair }
		channels = pairs.map(&:first)
		worker_channels = pairs.map(&:last)
		control, @control = IO.pipe
		report, report_writer = IO.pipe

		@loader = Quickdraw::Loader.start(worker_channels, @test_files, @seed, quiet: true, control:, report: report_writer) do
			channels.each(&:close)
			@control.close
			report.close
		end

		worker_channels.each(&:close)
		control.close
		report_writer.close
		@slots = channels.map { |channel| Slot.new(channel, self) }

		groups = case read_report(report)
		in [:booted, groups, *] then groups
		in [:failed, error] then raise Quickdraw::Replay::BootFailed.new(error)
		in nil then raise Quickdraw::Replay::BootFailed.new({ "name" => "Quickdraw::LoaderCrashed", "message" => "The process that loads config exited while booting." })
		end

		@control.puts("start #{@processes}")
		groups
	end

	# Loads and runs every test in `paths` unmutated, tracing `subjects`, spread
	# across the workers. Returns the Baselines, and the paths whose tests
	# couldn't run because they failed to load, crashed their process or
	# timed out.
	def baseline(paths, subjects)
		queue = Thread::Queue.new(paths).close

		results = in_slots do |slot|
			baselines = []
			failed = []

			while (path = queue.pop)
				tests = slot.load(path)
				traced, results = (slot.baseline(path, subjects) if tests)
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
					)
				end
			end

			[baselines, failed]
		rescue Gone
			[baselines, failed]
		end

		[results.flat_map(&:first), results.flat_map(&:last)]
	end

	# Runs each Job, yielding it and its outcome (see Slot#mutate) as it
	# finishes, or ["lost"] if the worker running it exited.
	def call(jobs)
		queue = Thread::Queue.new(jobs).close
		finished = Thread::Queue.new

		threads = @slots.map do |slot|
			Thread.new do
				while (job = queue.pop)
					outcome = slot.mutate(job)
					finished << [job, outcome]
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
			in [job, outcome] then yield job, outcome
			end
		end

		threads.each(&:join)
	end

	def stop
		@control&.close
		@slots&.each(&:close)
		Process.wait(@loader) if @loader && !loader_exited?
	rescue Errno::ECHILD
		nil
	end

	def loader_exited?
		@lock.synchronize do
			@loader_status ||= Process.wait2(@loader, Process::WNOHANG)&.last
		end
	end

	# Runs the block in a thread for each worker, and returns what each returned.
	private def in_slots(&)
		@slots.map { |slot| Thread.new(slot, &) }.map(&:value)
	end

	# Waits for the loader's report, or for it to exit without one.
	private def read_report(report)
		until report.wait_readable(LIVENESS_INTERVAL)
			return if loader_exited?
		end

		header = report.read(4)
		data = report.read(header.unpack1("N")) if header&.bytesize == 4
		Marshal.load(data) if data
	ensure
		report.close
	end

	# A worker, and the test files it has loaded.
	class Slot
		def initialize(channel, runner)
			@channel = channel
			@runner = runner
			@pid = nil
			@files = {}
			@gone = false
		end

		# The file's tests, as Worker#describe gives them, or nil if it failed to load.
		def load(path)
			return @files[path] if @files.key?(path)

			@channel.write([:load, path])

			@files[path] = case expect(:loaded, :load_failed)
			in [:loaded, _path, tests, _duration] then tests
			in [:load_failed, *] then nil
			end
		end

		# The ids of the subjects traced, and each test's result, in order (see
		# Worker#baseline). Nil if the tests crashed their process or timed out.
		def baseline(path, subjects)
			@channel.write([:baseline, path, subjects])

			case expect(:baseline)
			in [:baseline, _path, traced, results] then [traced, results]
			in [:baseline, _path] then nil
			end
		end

		# The outcome, as Worker#mutate gives it, but ["unloaded", path] rather
		# than ["survived"] if a test file that ran the mutant unmutated, in
		# another worker, failed to load in this one, so its tests didn't run.
		def mutate(job)
			tests, unloaded = job.tests.partition { |test| load(test.path) }
			return ["unloaded", unloaded.first.path] if tests.empty?

			@channel.write([:mutant, job.mutant, tests.map { |test| [test.path, test.index] }, job.seconds])

			case expect(:mutant).last
			in ["survived"] if unloaded.any? then ["unloaded", unloaded.first.path]
			in outcome then outcome
			end
		rescue Gone
			["lost"]
		end

		def close
			@channel.close
		end

		# Reads until a message of one of `types`. Raises Gone once the worker
		# has, whether its pipe closed or, since a process it started can hold
		# that open, its process is no longer running.
		private def expect(*types)
			raise Gone if @gone

			loop do
				unless @channel.reader.wait_readable(LIVENESS_INTERVAL)
					# Until the worker reports its pid, it's alive if the loader is.
					next if @pid ? alive?(@pid) : !@runner.loader_exited?

					gone!
				end

				message = @channel.read or gone!
				@pid = message.last if message.first in :pid | :ready
				return message if types.include?(message.first)
			end
		rescue IOError
			gone!
		end

		private def gone!
			@gone = true
			raise Gone
		end

		private def alive?(pid)
			Process.kill(0, pid)
			true
		rescue Errno::ESRCH
			false
		end
	end
end
