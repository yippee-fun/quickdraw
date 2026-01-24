# frozen_string_literal: true

class SameTest < Quickdraw::Test
	test "#assert_same pass" do
		object = Object.new
		assert_test(passes: 1) do
			assert_same object, object
		end
	end

	test "#assert_same failure" do
		assert_test(failures: 1) do
			assert_same Object.new, Object.new
		end
	end

	test "#refute_same pass" do
		assert_test(passes: 1) do
			refute_same Object.new, Object.new
		end
	end

	test "#refute_same failure" do
		object = Object.new
		assert_test(failures: 1) do
			refute_same object, object
		end
	end
end
