# frozen_string_literal: true

# A Watchdog whose deadline is kept by Quickdraw::Native: starting and
# stopping the clock are atomic stores, with no mutex and nothing woken, and a
# native thread writes to a pipe when the deadline passes.
#
# Runs alongside user code, so it must only use core Ruby.
class Quickdraw::NativeWatchdog < Quickdraw::Watchdog
	# Nil if the extension has no deadline left to give.
	def self.start(&on_timeout)
		wake_reader, wake_writer = IO.pipe
		fired, fire = IO.pipe
		slot = Quickdraw::Native.deadline_open(wake_reader.fileno, wake_writer.fileno, fire.fileno)

		if slot
			new(slot, [wake_reader, wake_writer, fired, fire], &on_timeout)
		else
			[wake_reader, wake_writer, fired, fire].each(&:close)
			nil
		end
	end

	def initialize(slot, pipes, &on_timeout)
		@on_timeout = on_timeout
		@slot = slot
		@pipes = pipes
		@fired = pipes[2]
		@reporting = Thread::Mutex.new
		@thread = Thread.new { await_deadline }
		@thread.name = "quickdraw-watchdog"
	end

	def watch(seconds)
		unless seconds
			yield
			return false
		end

		@seconds = seconds
		@watched = Thread.current
		Quickdraw::Native.deadline_arm(@slot, seconds)

		yield
		stop
	ensure
		if seconds
			stop
			@remaining = nil
		end
	end

	def pause
		@remaining = Quickdraw::Native.deadline_disarm(@slot)
	end

	def resume
		Quickdraw::Native.deadline_arm(@slot, @remaining / 1_000_000_000.0) if @remaining
		@remaining = nil
	end

	def close
		@thread.kill.join
		Quickdraw::Native.deadline_close(@slot)
		@pipes.each(&:close)
	end

	# Whether the block overran, which it didn't if a debugger has paused the
	# clock. Once it has, waits for a timeout that's being reported, so the
	# worker exits in this test and not the next.
	private def stop
		remaining = Quickdraw::Native.deadline_disarm(@slot)
		return false unless remaining && remaining < 0

		@reporting.synchronize { true }
	end

	private def await_deadline
		loop do
			@fired.readpartial(16)

			@reporting.synchronize do
				# The test may have finished since, and another started.
				remaining = Quickdraw::Native.deadline_remaining(@slot)
				time_out if remaining && remaining <= 0
			end
		end
	end
end
