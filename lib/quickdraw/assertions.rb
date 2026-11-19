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

			if expected_text.include?("\n") || actual_text.include?("\n") || (String === actual && String === expected)
				diff = Quickdraw::Diff.diff(expected_text, actual_text)

				unless diff.empty?
					next <<~MESSAGE
						\e[34mDiff (expected vs actual):\e[0m

						#{diff}
					MESSAGE
				end
			end

			<<~MESSAGE
				\e[34mActual:\e[0m

				#{actual.inspect}

				\e[34mExpected:\e[0m

				#{expected.inspect}
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

				unless diff.empty?
					next <<~MESSAGE
						\e[34mDiff (expected vs actual):\e[0m

						#{diff}
					MESSAGE
				end

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
end
