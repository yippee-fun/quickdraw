# frozen_string_literal: true

# Makes a new case from a corpus entry by changing its choices rather than its
# values, so the case still has the shape its generators give it: a choice
# replaced or nudged, a span (such as an array's item, or a string's character
# or dictionary token) deleted, duplicated or zeroed, a span from another entry
# spliced in, or the end dropped for fresh choices. Up to STACK changes at
# once, as AFL does. Replaying the result clamps choices to their limits, and
# makes fresh choices once it runs out.
class Quickdraw::Fuzz::Mutator
	STACK = 4

	# A case the fuzzer kept, as Property::Run has it.
	Entry = Data.define(:choices, :limits, :spans)

	def initialize(random)
		@random = random
	end

	# New choices from `entry`'s, splicing in some from `other`.
	def call(entry, other)
		choices = entry.choices.dup
		(1 + @random.rand(STACK)).times { change(choices, entry, other) }
		choices.take(Quickdraw::Choices::LIMIT)
	end

	# Spans come from the entry as it was, so after a change that moves
	# choices, they can be out of place, which is just a different change.
	private def change(choices, entry, other)
		return if choices.empty?

		index = @random.rand(choices.size)
		span = pick(entry.spans, choices.size)
		splice = pick(other.spans, other.choices.size)

		case @random.rand(8)
		in 0 then choices[index] = choice(entry.limits[index])
		in 1 then choices[index] = (choices[index] + (@random.rand(1..16) * ((@random.rand(2) == 0) ? 1 : -1))).clamp(0, nil)
		in 2 then choices.slice!(span) if span
		in 3 then choices.insert(span.end, *choices[span]) if span
		in 4 then choices.fill(0, span) if span
		in 5 then choices[span] = other.choices[splice] if span && splice
		in 6 then choices.insert(span&.begin || index, *other.choices[splice]) if splice
		in 7 then choices.slice!(index..)
		end
	end

	# A new choice up to `limit`: often the lowest or highest, as bugs are
	# found there, or with no limit, of any size up to 64 bits.
	private def choice(limit)
		if limit.nil?
			@random.rand(1 << @random.rand(65))
		else
			case @random.rand(8)
			in 0 then 0
			in 1 then limit
			else @random.rand(limit + 1)
			end
		end
	end

	# A span that fits in `size` choices, if there's one.
	private def pick(spans, size)
		span = spans.sample(random: @random)
		span if span && span.end <= size
	end
end
