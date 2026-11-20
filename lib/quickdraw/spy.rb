# frozen_string_literal: true

# The calls to a spied method (see Stubs#spy), from any thread.
class Quickdraw::Spy
	# `result` and `error` are both nil when the call left by throw or break.
	Call = Data.define(:args, :kwargs, :block, :result, :error, :thread)
	# Not through Thread.current, which could be spied on.
	CURRENT_THREAD = Thread.method(:current)

	def initialize
		@calls = []
		@mutex = Thread::Mutex.new
	end

	def calls = @mutex.synchronize { @calls.dup.freeze }
	def count = @mutex.synchronize { @calls.size }
	def called? = count > 0

	def record(call)
		@mutex.synchronize { @calls << call }

		nil
	end
end
