# frozen_string_literal: true

class NativeTest < Quickdraw::Test
	test "reports availability without raising" do
		assert Quickdraw::Native.available? == true || Quickdraw::Native.available? == false
	end

	test "exposes monotonic_ns, cputime_ns, measure_snapshot and macos_core_levels when compiled" do
		skip "Rust native extension not compiled" unless Quickdraw::Native.available?

		t1 = Quickdraw::Native.monotonic_ns
		t2 = Quickdraw::Native.monotonic_ns
		assert_operator t1, :>, 0
		assert_operator t2, :>=, t1

		cpu = Quickdraw::Native.cputime_ns
		assert_operator cpu, :>, 0

		wall, snap_cpu = Quickdraw::Native.measure_snapshot
		assert_operator wall, :>=, t2
		assert_operator snap_cpu, :>=, cpu

		if Quickdraw::Platform.m_series?
			levels = Quickdraw::Native.macos_core_levels
			assert_equal levels.size, 2
			assert levels.all? { |count| Integer === count && count.positive? }
			assert_equal Quickdraw::Platform.performance_cores, levels.first
			assert_equal Quickdraw::Platform.efficiency_cores, levels.last
		end
	end

	test "metrics are how much time, GC and allocation happened between start and finish" do
		skip "Rust native extension not compiled" unless Quickdraw::Native.available?

		metrics = [0, 0, 0, 0]
		Quickdraw::Native.metrics_start(metrics)
		objects = Array.new(100) { Object.new }
		Process.wait(Process.spawn(RbConfig.ruby, "-e", "200_000.times { }"))
		duration, cpu, gc, allocations = Quickdraw::Native.metrics_finish(metrics)

		assert_equal objects.size, 100
		assert_operator duration, :>, 0
		assert_operator cpu, :>, 0
		assert_operator gc, :>=, 0
		assert_operator allocations, :>=, 100
		assert_raises(TypeError) { Quickdraw::Native.metrics_start(1) }
		assert_raises(TypeError) { Quickdraw::Native.metrics_finish(nil) }
	end

	test "a test's recorded stats are the same kind with or without the extension" do
		recorder = Quickdraw::Worker::Recorder.new
		recorder.measure_test { Array.new(100) { Object.new } }
		result = recorder.to_h
		stats = Quickdraw::STATS.zip(result.fetch("stats")).to_h

		assert_operator result.fetch("duration"), :>, 0
		assert_operator stats.fetch("cpu"), :>, 0
		assert_operator stats.fetch("gc"), :>=, 0
		assert_operator stats.fetch("allocations"), :>=, (GC.stat.key?(:total_allocated_objects) ? 100 : 0)
	end
end
