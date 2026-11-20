# frozen_string_literal: true

module Quickdraw::Assertions
	def assert_equal(actual, expected)
		assert(actual == expected) do
			# Strings diff by line as they are; anything else, one element per line.
			expected_text, actual_text = if String === actual && String === expected
				[expected, actual]
			else
				[Quickdraw::Inspector.pretty(expected), Quickdraw::Inspector.pretty(actual)]
			end

			if expected_text.include?("\n") || actual_text.include?("\n")
				diff = Quickdraw::Diff.diff(expected_text, actual_text)
				next "#{Quickdraw::Diff::LEGEND}\n\n#{diff}\n" unless diff.empty?
			end

			<<~MESSAGE
				\e[2mExpected\e[0m  \e[32m#{expected.inspect}\e[0m
				\e[2mActual\e[0m    \e[31m#{actual.inspect}\e[0m
			MESSAGE
		end
	end

	def assert_equivalent_html(actual, expected)
		if actual == expected
			success!
		else
			normalized_actual = Quickdraw::HTMLPrettifier.prettify(actual)
			normalized_expected = Quickdraw::HTMLPrettifier.prettify(expected)

			assert(normalized_actual == normalized_expected) do
				<<~MESSAGE
					\e[34mActual HTML (prettified):\e[0m

					#{normalized_actual}

					\e[34mExpected HTML (prettified):\e[0m

					#{normalized_expected}
				MESSAGE
			end
		end
	end

	def assert_equivalent_ruby(actual, expected)
		if actual == expected
			success!
		else
			begin
				Quickdraw::Box.require("prism")
				Quickdraw::Box.require("refract")
			rescue LoadError
				raise LoadError, "assert_equivalent_ruby needs the `refract` gem in your Gemfile."
			end

			normalized_actual = Quickdraw::Box::Refract::Formatter.new.format_node(
				Quickdraw::Box::Refract::Converter.new.visit(
					Quickdraw::Box::Prism.parse(actual).value
				)
			).source

			normalized_expected = Quickdraw::Box::Refract::Formatter.new.format_node(
				Quickdraw::Box::Refract::Converter.new.visit(
					Quickdraw::Box::Prism.parse(expected).value
				)
			).source

			assert(normalized_actual == normalized_expected) do
				diff = Quickdraw::Diff.diff(expected, actual)

				next "#{Quickdraw::Diff::LEGEND}\n\n#{diff}\n" unless diff.empty?

				<<~MESSAGE
					\e[34mActual Ruby:\e[0m

					#{actual}

					\e[34mExpected Ruby:\e[0m

					#{expected}
				MESSAGE
			end
		end
	end

	def refute_equal(actual, expected)
		refute(actual == expected) do
			<<~MESSAGE
				\e[34mExpected:\e[0m

				#{actual.inspect}

				\e[34mnot to be == to:\e[0m

				#{expected.inspect}
			MESSAGE
		end
	end

	def assert_includes(collection, member)
		assert(collection.include?(member)) do
			<<~MESSAGE
				\e[34mExpected:\e[0m

				#{collection.inspect}

				\e[34mto include:\e[0m

				#{member.inspect}
			MESSAGE
		end
	end

	def refute_includes(collection, member)
		refute(collection.include?(member)) do
			<<~MESSAGE
				\e[34mExpected:\e[0m

				#{collection.inspect}

				\e[34mnot to include:\e[0m

				#{member.inspect}
			MESSAGE
		end
	end

	# Passes if `pattern === actual`, so the pattern can be a Regexp, Range,
	# Class, or anything else that defines ===.
	def assert_match(actual, pattern)
		assert(pattern === actual) do
			<<~MESSAGE
				\e[34mExpected:\e[0m

				#{actual.inspect}

				\e[34mto match:\e[0m

				#{pattern.inspect}
			MESSAGE
		end
	end

	def refute_match(actual, pattern)
		refute(pattern === actual) do
			<<~MESSAGE
				\e[34mExpected:\e[0m

				#{actual.inspect}

				\e[34mnot to match:\e[0m

				#{pattern.inspect}
			MESSAGE
		end
	end

	# For floats, which are rarely exactly equal.
	def assert_in_delta(actual, expected, delta = 0.001)
		difference = (actual - expected).abs

		assert(difference <= delta) do
			"expected #{actual.inspect} to be within #{delta.inspect} of #{expected.inspect}, but it's #{difference.inspect} away"
		end
	end

	def refute_in_delta(actual, expected, delta = 0.001)
		difference = (actual - expected).abs

		refute(difference <= delta) do
			"expected #{actual.inspect} not to be within #{delta.inspect} of #{expected.inspect}, but it's #{difference.inspect} away"
		end
	end

	def assert_operator(object, operator, other)
		assert object.public_send(operator, other) do
			<<~MESSAGE
				\e[34mExpected:\e[0m

				#{object.inspect}

				\e[34mto #{operator}:\e[0m

				#{other.inspect}
			MESSAGE
		end
	end

	def refute_operator(object, operator, other)
		refute object.public_send(operator, other) do
			<<~MESSAGE
				\e[34mExpected:\e[0m

				#{object.inspect}

				\e[34mnot to #{operator}:\e[0m

				#{other.inspect}
			MESSAGE
		end
	end

	def assert_raises(expected)
		yield
		failure! { "expected block to raise #{expected.inspect} but nothing was raised" }
	rescue Exception => error
		assert(expected === error) do
			"expected block to raise #{expected.inspect} but #{error.class.inspect} was raised instead"
		end

		error
	end

	def refute_raises
		yield
		success!
	rescue Exception => error
		failure! { "expected block not to raise, but #{error.class.inspect} was raised" }
	end

	# Passes if the block changes the value of `expression`, which is called
	# before and after it, by `difference`: `assert_difference(-> { User.count }) { … }`.
	# For several expressions, an Array of them, or a Hash of each to its
	# difference: `assert_difference(-> { User.count } => 1, -> { Post.count } => -1) { … }`.
	# Returns what the block returns.
	def assert_difference(expression, difference = 1)
		differences = case expression
			in Hash then expression
			in Array then expression.to_h { |it| [it, difference] }
			else { expression => difference }
		end

		before = differences.keys.map { |it| Quickdraw::Assertions.evaluate(it) }
		result = yield

		differences.each_with_index do |(expression, difference), index|
			after = expression.call

			# Rather than subtracting, which for floats can differ by a rounding error.
			assert(after == before[index] + difference) do
				"expected #{Quickdraw::Assertions.describe(expression)} to change by #{difference.inspect}, but it changed by #{(after - before[index]).inspect}, from #{before[index].inspect} to #{after.inspect}"
			end
		end

		result
	end

	def assert_no_difference(expression, &)
		raise ::ArgumentError, "assert_no_difference takes an expression or an Array of them, not a Hash." if Hash === expression

		assert_difference(expression, 0, &)
	end

	# Passes if the block changes the value of `expression`, which is called
	# before and after it, and the values before and after match `from` and `to`
	# (with ===), if given. Returns what the block returns.
	def assert_changes(expression, from: Quickdraw::Null, to: Quickdraw::Null)
		before = Quickdraw::Assertions.evaluate(expression)
		result = yield
		after = expression.call

		if !Quickdraw::Null.equal?(from) && !(from === before)
			failure! { "expected #{Quickdraw::Assertions.describe(expression)} to change from #{from.inspect}, but it was #{before.inspect}" }
		elsif before == after
			failure! { "expected #{Quickdraw::Assertions.describe(expression)} to change, but it stayed #{before.inspect}" }
		elsif !Quickdraw::Null.equal?(to) && !(to === after)
			failure! { "expected #{Quickdraw::Assertions.describe(expression)} to change to #{to.inspect}, but it changed to #{after.inspect}" }
		else
			success!
		end

		result
	end

	def assert_no_changes(expression, from: Quickdraw::Null)
		before = Quickdraw::Assertions.evaluate(expression)
		result = yield
		after = expression.call

		if !Quickdraw::Null.equal?(from) && !(from === before)
			failure! { "expected #{Quickdraw::Assertions.describe(expression)} to be #{from.inspect}, but it was #{before.inspect}" }
		elsif before != after
			failure! { "expected #{Quickdraw::Assertions.describe(expression)} not to change, but it changed from #{before.inspect} to #{after.inspect}" }
		else
			success!
		end

		result
	end

	# Module functions, so they aren't methods of tests.
	def self.evaluate(expression)
		raise ::ArgumentError, "Expected something to call, such as -> { User.count }, not #{expression.inspect}." unless expression.respond_to?(:call)

		expression.call
	end

	# Where a Proc is defined, as its source isn't available.
	def self.describe(expression)
		path, line = (Proc === expression) && expression.source_location
		path ? "the value at #{path.delete_prefix("#{Quickdraw::ROOT}/")}:#{line}" : expression.inspect
	end

	def assert_same(actual, expected)
		assert actual.equal?(expected) do
			"expected #{actual.inspect} to be the same object as #{expected.inspect}"
		end
	end

	def refute_same(actual, expected)
		refute actual.equal?(expected) do
			"expected #{actual.inspect} not to be the same object as #{expected.inspect}"
		end
	end

	def assert_nil(value)
		assert(nil == value) { "expected #{value.inspect} to be nil" }
	end

	def refute_nil(value)
		refute(nil == value) { "expected not to be nil" }
	end

	# Passes once the block returns something truthy, trying it again every
	# `interval` seconds until `within` seconds have passed, for what another
	# thread or process does, rather than sleeping for long enough.
	def assert_eventually(within: 1, interval: 0.01)
		raise ::ArgumentError, "assert_eventually needs a block." unless block_given?

		deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
		tries = 0

		loop do
			tries += 1
			return assert(true) if yield
			break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

			sleep interval
		end

		assert(false) { "expected the block to return something truthy within #{within}s, but it didn't in #{tries} tries" }
	end
end
