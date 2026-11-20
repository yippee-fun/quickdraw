# frozen_string_literal: true

# Decides when to add workers during a run, for tests that leave CPU idle
# because they mostly wait (on IO, sleep or the network). WorkerTuner chooses
# how many workers a run starts with; this corrects it while the run goes,
# such as on a suite's first run, before history shows how much it waits.
#
# Workers are only added while the machine has idle CPU (see IdleCPU), the
# run's tests use less than `cores` of it by their own CPU time, and spend
# most of their time off the CPU. So a CPU-bound suite doesn't get more
# workers than it started with, even when other processes slow its tests,
# and a suite sharing the machine with busy processes doesn't add to them.
# Each decision waits for workers added before it to start, and for a
# reading of idle CPU taken since.
class Quickdraw::Elastic
	CPU = Quickdraw::STATS.index("cpu")

	# How often to decide, in seconds.
	INTERVAL = 0.25

	# CPU left idle for everything else, in CPUs.
	RESERVE = 1.0

	# The least CPU a test is taken to use per second, so a suite of tests that
	# only sleep doesn't get a worker per test.
	MINIMUM_CPU_SHARE = 0.05

	# Tests that use more of a CPU than this while they run may be waiting for
	# a CPU rather than on IO, when other processes compete for it.
	MAXIMUM_CPU_SHARE = 0.5

	# Each worker added must have at least this much work waiting, in seconds
	# of tests.
	WORK_PER_WORKER = 0.25

	# Below this share of memory available, no more workers start.
	MEMORY_FLOOR = 0.2

	# `cores` is how many CPUs the run's tests should keep busy at most, and
	# `cpus` how many the machine has, which `idle_cpu` measures. `platform`
	# tells how much memory is available.
	def initialize(cores:, cpus:, idle_cpu:, platform: Quickdraw::Platform)
		@cores = cores
		@cpus = cpus
		@idle_cpu = idle_cpu
		@platform = platform
		@due_at = now
		@settled = false
		@tests = 0
		@test_time = 0.0
		forget
	end

	def due? = now >= @due_at

	# A test's result, with times in seconds.
	def record(result)
		@cpu += result["stats"][CPU]
		@wall += result["duration"]
		@results += 1
		@tests += 1
		@test_time += result["duration"]
	end

	# How many workers to add, of `workers` now, `starting` of which aren't
	# ready yet and `busy` of which are loading files or running tests, with
	# `waiting` tests not yet started.
	def wanted(workers:, starting:, busy:, waiting:)
		@due_at = now + INTERVAL

		if starting > 0
			@settled = false
			return 0
		end

		unless @settled
			@idle_cpu.reset
			forget
			@settled = true
			return 0
		end

		idle = @idle_cpu.sample or return 0
		return 0 if @results < workers || @wall <= 0

		share = [@cpu / @wall, MINIMUM_CPU_SHARE].max
		used = busy * share
		forget

		# A worker with nothing to do means there's no work for another.
		return 0 if busy < workers || share > MAXIMUM_CPU_SHARE

		spare = [@cores - used, (idle * @cpus) - RESERVE].min
		count = [(spare / share).floor, (waiting * average / WORK_PER_WORKER).floor - workers].min
		return 0 unless count > 0 && enough_memory?

		@settled = false
		count
	end

	def stop
		@idle_cpu.stop
	end

	private def average = @test_time / @tests

	private def enough_memory?
		available = @platform.available_memory
		available.nil? || available >= MEMORY_FLOOR
	end

	# Results so far, so the next decision measures the workers it has then.
	private def forget
		@cpu = 0.0
		@wall = 0.0
		@results = 0
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
