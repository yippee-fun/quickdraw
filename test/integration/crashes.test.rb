# frozen_string_literal: true

require_relative "../support/integration"

class CrashesTest < Quickdraw::Test
	include Integration

	def setup
		super
		skip "Replacing crashed workers and timing tests out need fork" unless Process.respond_to?(:fork)
	end

	test "reports a test that kills its worker and runs the rest on a replacement", timeout: 20 do
		result = project("crash.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "crash.test.rb")
			class Crash < Quickdraw::Test
				test("before") { assert true }
				test("kills its worker") { exit!(3) }
				test("after a") { assert true }
				test("after b") { assert true }
			end
		RUBY

		refute result.success?
		assert_includes result.output, "Crash › kills its worker"
		assert_includes result.output, "Quickdraw::WorkerCrashed"
		match { result => { summary: /\A4 tests · 3 assertions · 1 errored/ } }
	end

	test "starts a replacement in the crashed worker's slot", timeout: 20 do
		result = project("slot.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--no-capture", "slot.test.rb")
			class Slot < Quickdraw::Test
				test("kills its worker") { exit!(1) }
				3.times { |i| test("reports its slot \#{i}") { puts "slot=\#{ENV["QUICKDRAW_WORKER"]}"; assert true } }
			end
		RUBY

		assert_equal result.output.scan(/^slot=(\d+)$/).flatten.uniq, ["0"]
		match { result => { summary: /\A4 tests · 3 assertions · 1 errored/ } }
	end

	test "stops replacing workers once its spares are used up", timeout: 20 do
		result = project("crashes.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "--retry", "0", "--seed", "1", "crashes.test.rb")
			class Crashes < Quickdraw::Test
				10.times { |i| test("crash \#{i}") { exit!(1) } }
			end
		RUBY

		refute result.success?
		match { result => { summary: /\A5 tests · 0 assertions · 5 errored · 5 not run/ } }
	end

	test "reports a test that hangs, with every thread's backtrace", timeout: 20 do
		result = project("hang.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "hang.test.rb")
			class Hang < Quickdraw::Test
				test("waits forever", timeout: 0.5) do
					Thread.new { Thread.current.name = "helper"; sleep }.join
				end

				test("still runs") { assert true }
			end
		RUBY

		refute result.success?
		assert_includes result.output, "Quickdraw::Timeout: The test took longer than its 0.5s timeout."
		assert_includes result.output, "Thread helper:"
		match { result => { summary: /\A2 tests · 1 assertion · 1 errored/ } }
	end

	test "reports a test that finished, but after its timeout", timeout: 20 do
		result = project("late.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "late.test.rb")
			class Late < Quickdraw::Test
				test("spins past its timeout", timeout: 0.01) do
					finish = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05
					nil while Process.clock_gettime(Process::CLOCK_MONOTONIC) < finish
					assert true
				end
			end
		RUBY

		refute result.success?
		assert_includes result.output, "Quickdraw::Timeout"
		match { result => { summary: /\A1 test · 1 assertion · 1 errored/ } }
	end

	test "times out a hung test even if it closed $stdout", timeout: 20 do
		result = project("closed.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "closed.test.rb")
			class Closed < Quickdraw::Test
				test("closes stdout, then hangs", timeout: 0.5) { $stdout.close; sleep }
				test("still runs") { assert true }
			end
		RUBY

		match { result => { summary: /\A2 tests · 1 assertion · 1 errored/ } }
		assert(result.duration < 5) { "took #{result.duration}s" }
	end

	test "doesn't hang when a process a test forked holds a dead worker's pipes", timeout: 20 do
		result = project("orphan.test.rb" => <<~RUBY).run("-p", "1", "--no-history", "orphan.test.rb")
			class Orphan < Quickdraw::Test
				test("forks, then dies") { fork { sleep 30 }; exit!(1) }
				test("still runs") { assert true }
			end
		RUBY

		match { result => { summary: /\A2 tests · 1 assertion · 1 errored/ } }
		assert(result.duration < 5) { "took #{result.duration}s" }
	end

	test "doesn't hang when the loader fails to boot while a process it forked holds the pipes", timeout: 20 do
		result = project(
			"config/quickdraw.rb" => <<~RUBY,
				Quickdraw.configure do |config|
					config.before_forking do
						fork { sleep 30 }
						raise "boot failed"
					end
				end
			RUBY
			"test.test.rb" => <<~RUBY,
				class Never < Quickdraw::Test
					test("never runs") { assert true }
				end
			RUBY
		).run("-p", "2", "--no-history", "test.test.rb")

		refute result.success?
		assert_includes result.output, "ERROR test.test.rb could not be loaded\n\n  RuntimeError: boot failed\n\n  config/quickdraw.rb:4 in "
		match { result => { summary: /\A0 tests · 0 assertions · 1 errored/ } }
		assert(result.duration < 5) { "took #{result.duration}s" }
	end
end
