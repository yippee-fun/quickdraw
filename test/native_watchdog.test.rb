# frozen_string_literal: true

class NativeWatchdogTest < Quickdraw::Test
	LIB = File.expand_path("../lib", __dir__)
	WATCHDOG_CLASS = "print Quickdraw::Watchdog.start { nil }.class"

	test "the worker's watchdog is native when the extension is compiled" do
		skip "Rust native extension not compiled" unless Quickdraw::Native.available?

		assert_equal IO.popen([RbConfig.ruby, "-I", LIB, "-rquickdraw", "-e", WATCHDOG_CLASS], &:read), "Quickdraw::NativeWatchdog"
	end

	test "the worker's watchdog is the Ruby one with QUICKDRAW_NATIVE=0" do
		assert_equal IO.popen({ "QUICKDRAW_NATIVE" => "0" }, [RbConfig.ruby, "-I", LIB, "-rquickdraw", "-e", WATCHDOG_CLASS], &:read), "Quickdraw::Watchdog"
	end

	test "a closed watchdog's deadline can't reach the one opened after it" do
		skip "Rust native extension not compiled" unless Quickdraw::Native.available?

		first = Quickdraw::NativeWatchdog.start { nil }
		first.close
		second = Quickdraw::NativeWatchdog.start { nil }

		assert_raises(ArgumentError) { first.watch(5) { nil } }
		assert_equal second.watch(5) { :ran }, false
	ensure
		second&.close
	end

	test "a block that finishes in time didn't overrun" do
		with_watchdog do |watchdog|
			assert_equal watchdog.watch(5) { :ran }, false
			assert_equal watchdog.watch(nil) { :ran }, false
		end
	end

	test "pausing stops the clock" do
		with_watchdog do |watchdog|
			overran = watchdog.watch(0.05) do
				watchdog.pause
				sleep 0.15
				watchdog.resume
			end

			assert_equal overran, false
		end
	end

	test "a test past its timeout is reported with its backtrace, then the process exits" do
		skip "Rust native extension not compiled" unless Quickdraw::Native.available?

		reader, writer = IO.pipe

		pid = Process.fork do
			reader.close
			watchdog = Quickdraw::NativeWatchdog.start do |seconds, threads|
				writer.write(Marshal.dump([seconds, threads]))
				writer.flush
			end
			watchdog.watch(0.05) { sleep 5 }
			exit!(0)
		end

		writer.close
		seconds, threads = Marshal.load(reader.read)
		reader.close
		_, status = Process.wait2(pid)

		assert_equal status.exitstatus, 1
		assert_equal seconds, 0.05
		assert threads.first.fetch("test")
		assert threads.first.fetch("backtrace").any? { |frame| frame.include?("sleep") }
	end

	test "a deadline fires once it passes, and not once it's disarmed" do
		skip "Rust native extension not compiled" unless Quickdraw::Native.available?

		wake_reader, wake_writer = IO.pipe
		fired, fire = IO.pipe
		slot = Quickdraw::Native.deadline_open(wake_reader.fileno, wake_writer.fileno, fire.fileno)

		Quickdraw::Native.deadline_arm(slot, 300)
		assert_operator Quickdraw::Native.deadline_remaining(slot), :>, 299_000_000_000
		assert_operator Quickdraw::Native.deadline_disarm(slot), :>, 299_000_000_000
		assert_equal Quickdraw::Native.deadline_disarm(slot), nil

		Quickdraw::Native.deadline_arm(slot, 300)
		Quickdraw::Native.deadline_arm(slot, 0.02)
		assert fired.wait_readable(2)
		assert_operator Quickdraw::Native.deadline_disarm(slot), :<=, 0

		fired.read_nonblock(16)
		Quickdraw::Native.deadline_arm(slot, 0.02)
		Quickdraw::Native.deadline_disarm(slot)
		refute fired.wait_readable(0.1)
	ensure
		if slot
			Quickdraw::Native.deadline_close(slot)
			assert_raises(ArgumentError) { Quickdraw::Native.deadline_arm(slot, 1) }
			[wake_reader, wake_writer, fired, fire].each(&:close)
		end
	end

	private def with_watchdog
		skip "Rust native extension not compiled" unless Quickdraw::Native.available?

		watchdog = Quickdraw::NativeWatchdog.start { nil }

		begin
			yield watchdog
		ensure
			watchdog.close
		end
	end
end
