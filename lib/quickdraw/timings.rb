# frozen_string_literal: true

# Aggregates per-test timing results across the whole run. Results arrive with
# times already converted to seconds. Each test's record is only kept with
# `each_test`, for #slowest_tests; otherwise only the slowest is.
class Quickdraw::Timings
	CPU = Quickdraw::STATS.index("cpu")
	GC_TIME = Quickdraw::STATS.index("gc")
	ALLOCATIONS = Quickdraw::STATS.index("allocations")

	Test = Data.define(:duration, :path, :test, :stats) do
		def wall(phase) = stats[Quickdraw::PHASES.index(phase)]
	end

	attr_reader :count, :test_time, :slowest

	def initialize(each_test:)
		@tests = [] if each_test
		@count = 0
		# Total time spent in tests, summed across workers.
		@test_time = 0.0
		@slowest = nil
		@files = Hash.new { |hash, key| hash[key] = [0.0, 0] }
		@totals = Array.new(Quickdraw::STATS.size, 0)
		@counts = Hash.new { |hash, key| hash[key] = [0, 0.0] }
	end

	def record(path, test, result)
		duration = result["duration"] or return
		stats = result["stats"]

		@count += 1
		@test_time += duration
		slowest = @slowest.nil? || duration > @slowest.duration
		timed = Test.new(duration:, path:, test:, stats:) if slowest || @tests
		@slowest = timed if slowest
		@tests << timed if @tests

		file = @files[path]
		file[0] += duration
		file[1] += 1

		stats.each_with_index { |value, index| @totals[index] += value }

		result["counts"]&.each do |name, (count, seconds)|
			total = @counts[name]
			total[0] += count
			total[1] += seconds
		end
	end

	# From Quickdraw::Counters: [name, count per test, seconds per test], most
	# frequent first.
	def counts_per_test
		@counts
			.map { |name, (count, seconds)| [name, count.fdiv(@count), seconds / @count] }
			.sort_by { |_name, count, _seconds| -count }
	end

	def phase_share(phase)
		share(@totals[Quickdraw::PHASES.index(phase)], phases_time)
	end

	# Time outside the measured phases: around hooks, plus a few microseconds of
	# Quickdraw's own overhead per test.
	def outside_phases_time
		[test_time - phases_time, 0.0].max
	end

	def setup_and_teardown_share
		phase_share("setup") + phase_share("teardown")
	end

	# Time not spent on the CPU: IO, network, sleep, waiting on locks. Clamped
	# over the whole run rather than per test, because clamping very short tests
	# turns clock noise into phantom waiting.
	def waiting_share
		share([test_time - @totals[CPU], 0.0].max, test_time)
	end

	def gc_share
		share(@totals[GC_TIME], test_time)
	end

	def allocations_per_test
		(@count > 0) ? @totals[ALLOCATIONS] / @count : 0
	end

	# How much of the available worker time was spent running tests.
	def utilization(elapsed:, processes:)
		share(test_time, elapsed * processes)
	end

	def slowest_tests(limit)
		raise "Timings only keeps each test with each_test: true." unless @tests

		@tests.max_by(limit, &:duration)
	end

	# [path, total duration, test count]
	def slowest_files(limit)
		@files.max_by(limit) { |_path, (duration, _count)| duration }.map { |path, (duration, count)| [path, duration, count] }
	end

	private def phases_time
		Quickdraw::PHASES.sum { |phase| @totals[Quickdraw::PHASES.index(phase)] }
	end

	private def share(part, whole)
		(whole > 0) ? (part / whole).clamp(0.0, 1.0) : 0.0
	end
end
