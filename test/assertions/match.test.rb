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
