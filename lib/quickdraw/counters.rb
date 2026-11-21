# frozen_string_literal: true

# Counts things each test does, such as SQL queries or factories run, with the
# time they took. Results report them per test, and the summary averages them.
#
# A test's counts are kept in fiber storage, which the threads and fibers it
# starts inherit, so a thread it leaves running counts towards it, not the
# next test. Threads it didn't start count towards whichever test is running.
module Quickdraw::Counters
	extend self

	@counts = {}
	@mutex = Thread::Mutex.new
	@used = false
	EMPTY = {}.freeze

	def add(name, seconds = 0.0)
		raise ::ArgumentError, "A counter's name must be a String, not #{name.inspect}." unless String === name

		seconds = Float(seconds)

		@mutex.synchronize do
			@used = true
			count = ((Fiber[:quickdraw_counts] || @counts)[name] ||= [0, 0.0])
			count[0] += 1
			count[1] += seconds
		end

		nil
	end

	# Starts counting for a test, in this fiber.
	def start
		Fiber[:quickdraw_counts] = {}

		if @used
			@mutex.synchronize do
				@counts = {}
				@used = false
			end
		end
	end

	# The counts since #start, as {name => [count, seconds]}.
	def take
		unless @used
			Fiber[:quickdraw_counts] = nil
			return EMPTY
		end

		@mutex.synchronize do
			counts = Fiber[:quickdraw_counts] || {}
			Fiber[:quickdraw_counts] = nil
			others, @counts = @counts, {}
			@used = false

			others.each do |name, (count, seconds)|
				total = (counts[name] ||= [0, 0.0])
				total[0] += count
				total[1] += seconds
			end

			# Copies, which a thread the test left running can't change.
			counts.to_h { |name, (count, seconds)| [Quickdraw.utf8(name), [count, seconds]] }
		end
	end
end
