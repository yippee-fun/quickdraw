# frozen_string_literal: true

class InDeltaTest < Quickdraw::Test
	test "#assert_in_delta pass" do
		assert_test(passes: 2) do
			assert_in_delta 0.1 + 0.2, 0.3
			assert_in_delta 10, 12, 2
		end
	end

	test "#assert_in_delta failure says how far off it was" do
		runner = assert_test(failures: 1) do
			assert_in_delta 1.0, 1.5, 0.1
		end

		assert_includes runner.failures.last["message"], "but it's 0.5 away"
	end

	test "#refute_in_delta" do
		assert_test(passes: 1, failures: 1) do
			refute_in_delta 1.0, 2.0
			refute_in_delta 0.1 + 0.2, 0.3
		end
	end
end
