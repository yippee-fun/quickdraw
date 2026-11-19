# frozen_string_literal: true

# Runs one case of the test's first property, in a process a Session forked
# to see whether the case crashes or hangs it, as it minimises one that did.
# Writes [:drawn, choices, limits, spans, input] before running the case, in
# case it doesn't return, then [:ran, failure or nil], or [:discarded] if a
# filter discarded it, and exits.
class Quickdraw::Fuzz::Attempt
	def initialize(channel, prefix)
		@channel = channel
		@prefix = prefix
	end

	def call(property)
		run = property.execute(@prefix) do |choices|
			@channel.write([:drawn, choices.values, choices.limits, choices.spans, property.inspect_values(choices.values)])
		end

		@channel.write(run ? [:ran, run.failure] : [:discarded])
		exit!(0)
	end
end
