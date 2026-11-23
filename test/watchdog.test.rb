# frozen_string_literal: true

class WatchdogTest < Quickdraw::Test
	def setup
		skip "The watchdog exits its process, so these need fork" unless Process.respond_to?(:fork)
	end

	# Runs the block in a fork with a watchdog and returns what the block
	# returned, or [:timeout, seconds, the threads' names, how long the fork
	# ran for] if the watchdog timed it out.
	def watching
		reader, writer = IO.pipe

		pid = Process.fork do
			reader.close
			started_at = now

			watchdog = Quickdraw::Watchdog.new do |seconds, threads|
				writer.write(Marshal.dump([:timeout, seconds, threads.map { |thread| [thread["name"], thread["test"]] }, now - started_at]))
			end

			writer.write(Marshal.dump(yield(watchdog)))
			exit!(0)
		end

		writer.close
		data = reader.read
		reader.close
		_, status = Process.wait2(pid)

		outcome = Marshal.load(data)
		assert_equal status.exitstatus, (outcome in [:timeout, *]) ? 1 : 0
		outcome
	end

	def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

	test "runs the block, and says it didn't overrun" do
		ran = false

		outcome = watching do |watchdog|
			[watchdog.watch(5) { ran = true }, watchdog.watch(nil) { :untimed }, ran]
		end

		assert_equal outcome, [false, false, true]
	end

	test "times out a block that runs past its timeout, with its thread first" do
		outcome = watching do |watchdog|
			Thread.new { sleep }.name = "helper"
			watchdog.watch(0.1) { sleep }
		end

		match { outcome => [:timeout, 0.1, [["test", true], ["helper", false]], 0.1..2] }
	end

	test "doesn't time out blocks that each finish in time, however long they take together" do
		outcome = watching do |watchdog|
			Array.new(30) { watchdog.watch(0.2) { sleep 0.02 } }.uniq
		end

		assert_equal outcome, [false]
	end

	test "times out a block with a sooner deadline than the one before it" do
		outcome = watching do |watchdog|
			watchdog.watch(60) { sleep 0.05 }
			watchdog.watch(0.1) { sleep }
		end

		match { outcome => [:timeout, 0.1, [["test", true]], 0.15..2] }
	end

	test "times out a block that starts after the watchdog had nothing to watch" do
		outcome = watching do |watchdog|
			sleep 0.05
			watchdog.watch(0.1) { sleep }
		end

		match { outcome => [:timeout, 0.1, [["test", true]], 0.15..2] }
	end

	test "times out a later block after one that raised" do
		outcome = watching do |watchdog|
			begin
				watchdog.watch(60) { raise "Failed." }
			rescue RuntimeError
				nil
			end

			sleep 0.05
			watchdog.watch(0.1) { sleep }
		end

		match { outcome => [:timeout, 0.1, [["test", true]], 0.15..2] }
	end

	test "doesn't count the time it's paused for, from another thread" do
		outcome = watching do |watchdog|
			watchdog.watch(0.2) do
				Thread.new { watchdog.pause }.join
				sleep 0.5
				Thread.new { watchdog.resume }.join
			end
		end

		assert_equal outcome, false
	end

	test "gives a paused block what it had left once it's resumed" do
		outcome = watching do |watchdog|
			watchdog.watch(0.2) do
				watchdog.pause
				sleep 0.5
				watchdog.resume
				sleep
			end
		end

		match { outcome => [:timeout, 0.2, [["test", true]], 0.7..3] }
	end

	test "gives a block that starts while it's paused its whole timeout from when it's resumed" do
		outcome = watching do |watchdog|
			watchdog.pause
			sleep 0.2

			watchdog.watch(0.3) do
				sleep 0.4
				watchdog.resume
				sleep
			end
		end

		match { outcome => [:timeout, 0.3, [["test", true]], 0.9..3] }
	end

	test "pausing twice, or resuming when it isn't paused, changes nothing" do
		outcome = watching do |watchdog|
			watchdog.resume
			watchdog.pause
			sleep 0.1
			watchdog.pause
			watchdog.resume
			watchdog.resume
			watchdog.watch(0.1) { sleep }
		end

		match { outcome => [:timeout, 0.1, [["test", true]], 0.2..2] }
	end
end
