# frozen_string_literal: true

module Quickdraw::Assertions
	DIFFER = Difftastic::Differ.new(
		left_label: "Actual",
		right_label: "Expected",
		color: :always,
		tab_width: 2,
	)

	def assert_equal(actual, expected)
		assert(actual == expected) do
			if String === actual && String === expected
				diff = DIFFER.diff_strings(actual, expected)
			else
				diff = DIFFER.diff_objects(actual, expected)
			end

			"Expected objects to be equal (compared with `actual == expected`):\n\n#{diff}"
		end
	end

	def assert_equal_sql(actual, expected)
		unless String === actual && String === expected
			raise ArgumentError.new("expected both actual and expected to be strings")
		end

		assert(actual == expected) do
			diff = DIFFER.diff_sql(actual, expected)
			diff = DIFFER.diff_strings(actual, expected) if no_syntactic_changes?(diff)

			"Expected SQL strings to be equal (compared with `actual == expected`):\n\n#{diff}"
		end
	end

	def assert_equal_html(actual, expected)
		unless String === actual && String === expected
			raise ArgumentError.new("expected both actual and expected to be strings")
		end

		assert(actual == expected) do
			diff = DIFFER.diff_html(actual, expected)
			diff = DIFFER.diff_strings(actual, expected) if no_syntactic_changes?(diff)

			if diff.end_with?("No syntactic changes.")
				diff = DIFFER.diff_strings(actual, expected)
			end

			"Expected HTML strings to be equal (compared with `actual == expected`):\n\n#{diff}"
		end
	end

	def assert_equivalent_html(actual, expected)
		if actual == expected
			success!
		else
			pretty_actual = Quickdraw::HTMLPrettifier.prettify(actual)
			pretty_expected = Quickdraw::HTMLPrettifier.prettify(expected)

			assert(pretty_actual == pretty_expected) do
				diff = DIFFER.diff_html(pretty_actual, pretty_expected)

				if diff.end_with?("No syntactic changes.")
					diff = DIFFER.diff_strings(pretty_actual, pretty_expected)
				end

				"Expected HTML to be equivalent (ignoring whitespace):\n\n#{diff}"
			end
		end
	end

	def assert_equal_ruby(actual, expected)
		unless String === actual && String === expected
			raise ArgumentError.new("expected both actual and expected to be strings")
		end

		assert(actual == expected) do
			diff = DIFFER.diff_ruby(actual, expected)
			diff = DIFFER.diff_strings(actual, expected) if no_syntactic_changes?(diff)

			"Expected Ruby strings to be equal (compared with `actual == expected`):\n\n#{diff}"
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

	private

	def syntactic_changes?(diff)
		!no_syntactic_changes?(diff)
	end

	def no_syntactic_changes?(diff)
		diff.include?("No syntactic changes.")
	end
end
