# frozen_string_literal: true

class IncludesTest < Quickdraw::Test
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
end
