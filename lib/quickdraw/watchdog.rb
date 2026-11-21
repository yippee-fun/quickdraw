# frozen_string_literal: true

# Times out tests from a background thread in the worker. When a test runs past
# its timeout, the watchdog yields the timeout and every thread's backtrace,
# then exits the worker so the coordinator can report it and replace it.
#
# Runs alongside user code, so it must only use core Ruby.
#
# Starting and finishing a test take no lock. The test's thread and the
# watchdog's each write their own variable, then read the other's, so one of
# them always sees the other: #watch wakes the watchdog only for a deadline
# sooner than the one it's sleeping to, and waits for the lock only while the
# watchdog decides whether to time the test out. That needs each to see the
# other's last write, which only CRuby's GVL promises, so other engines always
# wake the watchdog and take the lock.
class Quickdraw::Watchdog
	MONOTONIC = Process::CLOCK_MONOTONIC
	ORDERED_WRITES = RUBY_ENGINE == "ruby"

	def initialize(&on_timeout)
		@on_timeout = on_timeout
		@mutex = Thread::Mutex.new
		@wakeups = Thread::Queue.new
		@deadline = nil
		@wake_at = Float::INFINITY
		@expiring = false
		# How long the clock has been stopped for in all, and since when it's
		# stopped, if it is. One object, so a reader never sees half a change.
		@pause = [0.0, nil].freeze
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

		# The deadline last, so the watchdog never sees it without the rest.
		@seconds = seconds
		@watched = Thread.current
		@armed = @pause
		deadline = @deadline = Process.clock_gettime(MONOTONIC) + seconds

		if !ORDERED_WRITES
			@wakeups << true
		elsif deadline < @wake_at
			@wake_at = deadline
			@wakeups << true
		end

		begin
			yield
			Process.clock_gettime(MONOTONIC) > deadline && overran?(deadline)
		ensure
			@deadline = nil
			# Never returns if the watchdog is timing the test out.
			@mutex.synchronize { nil } if @expiring || !ORDERED_WRITES
		end
	end

	# Stops the clock, e.g. while a debugger has the terminal, until #resume.
	def pause
		@mutex.synchronize do
			total, since = @pause
			@pause = [total, now].freeze unless since
		end
	end

	def resume
		@mutex.synchronize do
			total, since = @pause

			if since
				@pause = [total + (now - since), nil].freeze
				@wakeups << true
			end
		end
	end

	private def watch_deadlines
		loop do
			deadline = @deadline
			pause = @pause

			if deadline.nil? || pause[1]
				wait(deadline, Float::INFINITY, nil)
			else
				wake_at = deadline + stopped(deadline, pause)
				remaining = wake_at - now

				if remaining > 0
					wait(deadline, wake_at, remaining)
				else
					expire(deadline)
				end
			end
		end
	end

	# Not if the deadline changed before @wake_at did, as #watch only wakes
	# this thread for a deadline it can see is sooner.
	private def wait(deadline, wake_at, timeout)
		@wake_at = wake_at
		@wakeups.pop(timeout:) if @deadline == deadline
	end

	# A test that finishes meanwhile sees @expiring and waits for the lock, so
	# it's either timed out or reported, never both.
	private def expire(deadline)
		@mutex.synchronize do
			@expiring = true
			time_out if @deadline == deadline && overran?(deadline)
		ensure
			@expiring = false
		end
	end

	# Not while a debugger has the clock stopped.
	private def overran?(deadline)
		pause = @pause
		!pause[1] && now >= deadline + stopped(deadline, pause)
	end

	# How long the clock was stopped for while the watched block ran, as of
	# `pause`, which isn't stopped.
	private def stopped(deadline, pause)
		armed = @armed
		return 0.0 if armed.equal?(pause)

		total, since = armed
		# Armed while stopped, so not what had passed of that stop.
		total += deadline - @seconds - since if since
		pause[0] - total
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
		Process.clock_gettime(MONOTONIC)
	end
end
