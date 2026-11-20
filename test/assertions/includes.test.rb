# frozen_string_literal: true

class IncludesTest < Quickdraw::Test
	LONG = "#{(1..40).map { |i| "line #{i} of the output" }.join("\n")}\nERROR: no test at line 9, but nothing matches it\nFAILED 3 tests\n"

	def plain(message) = message.gsub(/\e\[[\d;]*m/, "")

	test "#assert_includes pass" do
		assert_test(passes: 1) do
			assert_includes([1, 2, 3], 2)
		end
	end

	test "#assert_includes fail" do
		assert_test(failures: 1) do
			assert_includes([1, 2, 3], 4)
		end
	end

	test "#assert_includes shows a short string whole" do
		runner = assert_test(failures: 1) do
			assert_includes("hello world", "bye")
		end

		assert_equal plain(runner.failures.last["message"]), %(Expected:\n\n"hello world"\n\nto include:\n\n"bye"\n)
	end

	test "#assert_includes shows where a long string comes closest, then the whole string" do
		runner = assert_test(failures: 1) do
			assert_includes(LONG, "but nothing matched it")
		end

		assert_equal plain(runner.failures.last["message"]), <<~MESSAGE
			Expected a string of #{LONG.size} characters to include:

			"but nothing matched it"

			Closest match, at line 41, column 27:

			…" the output\\nline 40 of the output\\nERROR: no test at line 9, but nothing matches it\\nFAILED 3 tests\\n"
			                                                                ^^^^^^^^^^^^^^^^^^^^^^

			- "but nothing matched it"
			+ "but nothing matches it"
			                     ^

			The whole string:

			#{LONG.inspect}
		MESSAGE
	end

	test "#assert_includes says when nothing in a long string is like what was expected" do
		runner = assert_test(failures: 1) do
			assert_includes(LONG, "@@")
		end

		assert_includes runner.failures.last["message"], "Nothing in it is like that."
	end

	test "#assert_includes marks a closest match that runs off the end of the string" do
		runner = assert_test(failures: 1) do
			assert_includes("#{'.' * 300}abc", "abcdef")
		end

		assert_includes plain(runner.failures.last["message"]), %(#{'.' * 60}abc"\n#{' ' * 62}^^^\n)
	end

	test "#refute_includes shows a long string that isn't ASCII-compatible whole" do
		text = "#{'x' * 300}needle".encode(Encoding::UTF_16LE)

		runner = assert_test(failures: 1) do
			refute_includes(text, "needle".encode(Encoding::UTF_16LE))
		end

		assert_includes runner.failures.last["message"], "not to include:"
	end

	test "#refute_includes pass" do
		assert_test(passes: 1) do
			refute_includes([1, 2, 3], 4)
		end
	end

	test "#refute_includes fail" do
		assert_test(failures: 1) do
			refute_includes([1, 2, 3], 2)
		end
	end

	test "#refute_includes shows where a long string has what it shouldn't" do
		runner = assert_test(failures: 1) do
			refute_includes(LONG, "FAILED 3")
		end

		message = plain(runner.failures.last["message"])
		assert_includes message, "Found at line 42, column 1:\n\n…\""
		assert_includes message, %(matches it\\nFAILED 3 tests\\n"\n)
		assert_includes message, "The whole string:\n\n#{LONG.inspect}\n"
	end
end
