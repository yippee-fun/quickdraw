# frozen_string_literal: true

class ElasticTest < Quickdraw::Test
	# Gives readings in turn, then nil, as if no more time had passed.
	IdleCPU = Struct.new(:readings, :resets) do
		def reset = self.resets += 1
		def sample = readings.shift
		def stop = nil
	end

	Platform = Data.define(:available_memory)

	def elastic(idle: [0.9], memory: 0.5)
		@idle_cpu = IdleCPU.new(idle, 0)
		Quickdraw::Elastic.new(cores: 8, cpus: 12, idle_cpu: @idle_cpu, platform: Platform.new(memory))
	end

	# Tests that each took `wall` seconds, `cpu` of them on the CPU.
	def record(elastic, count, wall:, cpu:)
		stats = Array.new(Quickdraw::STATS.size, 0.0)
		stats[Quickdraw::STATS.index("cpu")] = cpu
		count.times { elastic.record({ "duration" => wall, "stats" => stats }) }
	end

	def wanted(elastic, workers: 8, starting: 0, busy: workers, waiting: 1000)
		elastic.wanted(workers:, starting:, busy:, waiting:)
	end

	# Workers are ready, so readings start again.
	def settle(elastic)
		assert_equal wanted(elastic), 0
	end

	test "adds workers for tests that mostly wait, up to what's waiting, then waits for them to start" do
		elastic = elastic(idle: [0.9, 0.9])
		settle(elastic)
		record(elastic, 8, wall: 0.02, cpu: 0.0001)

		# 1000 tests of 20ms is work for 80 workers of 250ms.
		assert_equal wanted(elastic), 72
		assert_equal wanted(elastic, workers: 80, starting: 72), 0
		assert_equal wanted(elastic, workers: 80), 0
		assert_equal @idle_cpu.resets, 2
	end

	test "adds only as many workers as idle CPU allows, counting each as using some" do
		elastic = elastic(idle: [0.2])
		settle(elastic)
		record(elastic, 8, wall: 0.02, cpu: 0.0001)

		# 2.4 CPUs idle, less one kept for everything else, at 0.05 a worker.
		assert_equal wanted(elastic), 28
	end

	test "doesn't add workers for CPU-bound tests, even with CPUs idle beyond its cores" do
		elastic = elastic(idle: [0.33])
		settle(elastic)
		record(elastic, 8, wall: 0.02, cpu: 0.02)

		assert_equal wanted(elastic), 0
	end

	test "doesn't add workers for tests that use most of a CPU, though other processes slow them and CPUs look idle" do
		elastic = elastic(idle: [0.5])
		settle(elastic)
		record(elastic, 8, wall: 0.02, cpu: 0.012)

		assert_equal wanted(elastic), 0
	end

	test "doesn't add workers while other processes keep the CPU busy, though tests wait for it" do
		elastic = elastic(idle: [0.05])
		settle(elastic)
		record(elastic, 8, wall: 0.02, cpu: 0.008)

		assert_equal wanted(elastic), 0
	end

	test "decides only once workers have started and it has a reading of idle CPU from since then" do
		elastic = elastic(idle: [])
		record(elastic, 8, wall: 0.02, cpu: 0.0001)

		assert_equal wanted(elastic, starting: 1), 0
		assert_equal @idle_cpu.resets, 0
		settle(elastic)
		assert_equal @idle_cpu.resets, 1
		record(elastic, 8, wall: 0.02, cpu: 0.0001)
		assert_equal wanted(elastic), 0
	end

	test "doesn't add workers while a worker has nothing to do, or before every worker has a result" do
		elastic = elastic(idle: [0.9, 0.9])
		settle(elastic)
		record(elastic, 8, wall: 0.02, cpu: 0.0001)
		assert_equal wanted(elastic, busy: 7), 0

		record(elastic, 7, wall: 0.02, cpu: 0.0001)
		assert_equal wanted(elastic), 0
	end

	test "doesn't add workers when memory is short" do
		elastic = elastic(memory: 0.1)
		settle(elastic)
		record(elastic, 8, wall: 0.02, cpu: 0.0001)

		assert_equal wanted(elastic), 0
	end
end
