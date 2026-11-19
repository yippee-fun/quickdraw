# frozen_string_literal: true

# Counts things each test does, such as SQL queries or factories run, with the
# time they took. Results report them per test, and the summary averages them.
module Quickdraw::Counters
	extend self

	@counts = {}

	def add(name, seconds = 0.0)
		raise ::ArgumentError, "A counter's name must be a String, not #{name.inspect}." unless String === name

		count = (@counts[name] ||= [0, 0.0])
		count[0] += 1
		count[1] += Float(seconds)

		nil
	end

	# The counts since the last take, as {name => [count, seconds]}.
	def take
		counts = @counts
		@counts = {}
		counts.transform_keys { |name| Quickdraw.utf8(name) }
	end
end
