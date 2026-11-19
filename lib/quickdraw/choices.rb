# frozen_string_literal: true

# The choices a property's generators make for one case, as integers from zero,
# where smaller is simpler. Shrinking simplifies the choices rather than the
# values, so a value shrinks however it was built.
#
# Runs in workers alongside user code, so it must only use core Ruby.
class Quickdraw::Choices
	# Throws a case away, e.g. when a filter can't find a value. Not a
	# StandardError, so a generator's own `rescue => error` can't catch it.
	class Discard < Exception; end

	# So a recursive generator can't run forever.
	LIMIT = 10_000

	EMPTY = [].freeze

	# Replays `prefix`, then makes new choices with `random`, or the simplest
	# choices without it.
	def initialize(prefix = EMPTY, random = nil)
		@prefix = prefix
		@random = random
		@values = []
		@spans = []
	end

	attr_reader :values, :spans

	def draw(generator)
		raise ::ArgumentError, "Expected a Quickdraw::Generator, got #{generator.inspect}." unless Quickdraw::Generator === generator

		span { generator.call(self) }
	end

	# Marks the choices the block makes as a unit, which shrinking can delete or
	# simplify together, such as an array's item.
	def span
		start = @values.size
		yield
	ensure
		finish = @values.size
		@spans << (start...finish) if finish > start
	end

	# A choice from 0 to `limit`, which is unbounded if nil. The block makes a new
	# choice from a Random, so generators can favour interesting values; without
	# it, new choices are uniform.
	def choose(limit)
		index = @values.size
		discard! if index == LIMIT

		choice = if index < @prefix.size
			replayed = @prefix[index]
			(limit && replayed > limit) ? limit : replayed
		elsif @random
			block_given? ? yield(@random) : @random.rand(limit + 1)
		else
			0
		end

		if !(Integer === choice) || choice.negative? || (limit && choice > limit)
			raise "Choice #{choice.inspect} is outside 0..#{limit}."
		end

		@values << choice
		choice
	end

	def discard!
		raise Discard
	end
end
