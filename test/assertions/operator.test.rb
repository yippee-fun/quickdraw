# frozen_string_literal: true

class OperatorTest < Quickdraw::Test
	test "#assert_operator pass with >" do
		assert_test(passes: 1) do
			assert_operator 5, :>, 3
		end
	end

	test "#assert_operator fail with >" do
		assert_test(failures: 1) do
			assert_operator 3, :>, 5
		end
	end

	test "#assert_operator pass with <" do
		assert_test(passes: 1) do
			assert_operator 3, :<, 5
		end
	end

	test "#assert_operator fail with <" do
		assert_test(failures: 1) do
			assert_operator 5, :<, 3
		end
	end

	test "#assert_operator pass with >=" do
		assert_test(passes: 1) do
			assert_operator 5, :>=, 5
		end
	end

	test "#assert_operator fail with >=" do
		assert_test(failures: 1) do
			assert_operator 3, :>=, 5
		end
	end

	test "#assert_operator pass with <=" do
		assert_test(passes: 1) do
			assert_operator 5, :<=, 5
		end
	end

	test "#assert_operator fail with <=" do
		assert_test(failures: 1) do
			assert_operator 5, :<=, 3
		end
	end

	test "#refute_operator pass with >" do
		assert_test(passes: 1) do
			refute_operator 3, :>, 5
		end
	end

	test "#refute_operator fail with >" do
		assert_test(failures: 1) do
			refute_operator 5, :>, 3
		end
	end

	test "#refute_operator pass with <" do
		assert_test(passes: 1) do
			refute_operator 5, :<, 3
		end
	end

	test "#refute_operator fail with <" do
		assert_test(failures: 1) do
			refute_operator 3, :<, 5
		end
	end
end
