# frozen_string_literal: true

class MatchTest < Quickdraw::Test
	test "#assert_match pass" do
		assert_test(passes: 3) do
			assert_match "hello world", /wor/
			assert_match 5, 1..10
			assert_match "hello", String
		end
	end

	test "#assert_match failure" do
		runner = assert_test(failures: 1) do
			assert_match "hello", /bye/
		end

		assert_includes runner.failures.last["message"], "to match"
	end

	test "#assert_match shows where a long string comes closest to a pattern" do
		text = "#{'ok ' * 100}\nwarning: 3 tests failed\n#{'ok ' * 100}"

		runner = assert_test(failures: 1) do
			assert_match text, /^\d+ tests passed$/
		end

		message = runner.failures.last["message"].gsub(/\e\[[\d;]*m/, "")
		assert_includes message, "Expected a string of 625 characters to match:\n\n/^\\d+ tests passed$/\n\nClosest match, at line 2, column 10:\n\n"
		assert_includes message, "The whole string:\n\n#{text.inspect}\n"
	end

	test "#refute_match shows where a long string matched" do
		text = "#{'ok ' * 100}\nwarning: 3 tests failed\n"

		runner = assert_test(failures: 1) do
			refute_match text, /\d+ tests failed/
		end

		assert_includes runner.failures.last["message"], "Found at line 2, column 10:"
	end

	test "#refute_match pass" do
		assert_test(passes: 1) do
			refute_match "hello", /bye/
		end
	end

	test "#refute_match failure" do
		assert_test(failures: 1) do
			refute_match 5, 1..10
		end
	end
end
