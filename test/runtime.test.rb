# frozen_string_literal: true

class RuntimeTest < Quickdraw::Test
	def choose(...) = Quickdraw::Runtime.choose(...)

	def yjit = Quickdraw::Platform.yjit_supported? ? ["yjit"] : []

	test "tunes nothing when history can't say how much work there is" do
		assert_equal choose(nil), []
	end

	test "defers GC for workers with little work" do
		assert_equal choose(0.01), ["defer_gc"]
		assert_equal choose(Quickdraw::Runtime::DEFER_GC_UNDER), []
	end

	test "enables YJIT for workers with enough work to repay compiling" do
		assert_equal choose(Quickdraw::Runtime::YJIT_FROM - 0.01), []
		assert_equal choose(Quickdraw::Runtime::YJIT_FROM), yjit
	end

	test "settings override history" do
		assert_equal choose(0.01, yjit: true, defer_gc: false), yjit
		assert_equal choose(60.0, yjit: false, defer_gc: true), ["defer_gc"]
		assert_equal choose(nil, yjit: true, defer_gc: true), [*yjit, "defer_gc"]
	end

	test "deferring GC puts it off until the worker has allocated its budget, and not in its forks", timeout: 20 do
		skip "Workers need fork" unless Process.respond_to?(:fork)

		reader, writer = IO.pipe

		pid = Process.fork do
			reader.close
			Quickdraw::Runtime.apply(["defer_gc"])
			count = GC.count
			strings = Array.new(10_000) { |index| "string #{index}" }
			deferred = GC.count == count && strings.size == 10_000

			fork_reader, fork_writer = IO.pipe
			in_fork = -> { Process.wait(Process.fork { fork_writer.write(GC.enable ? "disabled " : "enabled ") }) }
			in_fork.call

			strings << ("x" * 10_000) while Thread.list.any? { |thread| thread.name == "quickdraw-gc" }
			disabled_past_budget = GC.disable
			# The test's own, which its forks keep.
			in_fork.call
			fork_writer.close

			writer.write(Marshal.dump([deferred, fork_reader.read, disabled_past_budget]))
			exit!(0)
		end

		writer.close
		deferred, in_forks, disabled_past_budget = Marshal.load(reader.read)
		Process.wait(pid)

		assert deferred
		assert_equal in_forks, "enabled disabled "
		refute disabled_past_budget
	end
end
