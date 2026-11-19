# frozen_string_literal: true

# Times out tests from a background thread in the worker. When a test runs past
# its timeout, the watchdog yields the timeout and every thread's backtrace,
# then exits the worker so the coordinator can report it and replace it.
#
# Runs alongside user code, so it must only use core Ruby.
class Quickdraw::Watchdog
	def initialize(&on_timeout)
		@on_timeout = on_timeout
		@mutex = Thread::Mutex.new
		@changed = Thread::ConditionVariable.new
		@deadline = nil
		@thread = Thread.new { watch_deadlines }
		@thread.name = "quickdraw-watchdog"
	end

	# Runs the block, timing it out after `seconds`, or never if nil. Returns
	# whether the block overran: it can finish late before this thread gets a
	# chance to run, e.g. while it holds the GVL. Not reentrant.
	def watch(seconds)
		unless seconds
			yield
			return false
		end

		@mutex.synchronize do
			@seconds = seconds
			@watched = Thread.current
			@deadline = now + seconds
			@changed.signal
		end

		yield
		@mutex.synchronize { now > @deadline }
	ensure
		if seconds
			@mutex.synchronize do
				@deadline = nil
				@changed.signal
			end
		end
	end

	private def watch_deadlines
		@mutex.synchronize do
			loop do
				if @deadline.nil?
					@changed.wait(@mutex)
				elsif (remaining = @deadline - now) > 0
					@changed.wait(@mutex, remaining)
				else
					time_out
				end
			end
		end
	end

	private def time_out
		@on_timeout.call(@seconds, backtraces)

		# exit! skips flushing, which would lose what earlier tests printed.
		$stdout.flush
		$stderr.flush
	rescue Exception
		# Exits regardless, e.g. if the test closed $stdout.
		nil
	ensure
		exit!(1)
	end

	# The timed-out test's thread first.
	private def backtraces
		threads = Thread.list.reject { |thread| thread.equal?(@thread) }
		threads = threads.sort_by { |thread| thread.equal?(@watched) ? 0 : 1 }

		threads.map do |thread|
			{
				"name" => Quickdraw.plain_string(thread.name || (thread.equal?(@watched) ? "test" : "thread")),
				"test" => thread.equal?(@watched),
				"backtrace" => (thread.backtrace || []).map { |frame| Quickdraw.plain_string(frame) },
			}
		end
	end

	private def now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
end
