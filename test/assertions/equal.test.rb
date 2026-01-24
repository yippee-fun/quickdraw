# frozen_string_literal: true

class EqualTest < Quickdraw::Test
	test "#assert_equal pass" do
		assert_test(passes: 1) do
			assert_equal 1, 1
		end
	end

	test "#assert_equal failure" do
		assert_test(failures: 1) do
			assert_equal 1, 2
		end
	end

	test "#refute_equal pass" do
		assert_test(passes: 1) do
			refute_equal 1, 2
		end
	end

	test "#refute_equal failure" do
		assert_test(failures: 1) do
			refute_equal 1, 1
		end
	end
end
