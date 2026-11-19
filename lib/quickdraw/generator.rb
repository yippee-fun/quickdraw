# frozen_string_literal: true

# Makes a value from Quickdraw::Choices. Quickdraw::Generators has the core
# ones, and these methods build others from them.
#
# Runs in workers alongside user code, so it must only use core Ruby.
class Quickdraw::Generator
	FILTER_ATTEMPTS = 10

	def initialize(&block)
		raise ::ArgumentError, "A generator needs a block." unless block

		@block = block
	end

	def call(choices)
		@block.call(choices)
	end

	def map(&block)
		Quickdraw::Generator.new { |choices| block.call(call(choices)) }
	end

	# Discards the case if a few tries don't find a value the block accepts.
	def filter(&block)
		Quickdraw::Generator.new do |choices|
			attempts = 0

			loop do
				value = choices.draw(self)
				break value if block.call(value)

				attempts += 1
				choices.discard! if attempts == FILTER_ATTEMPTS
			end
		end
	end

	# The block takes a value and returns a generator to draw from.
	def flat_map(&block)
		Quickdraw::Generator.new { |choices| choices.draw(block.call(call(choices))) }
	end
end
