# frozen_string_literal: true

class EqualRubyTest < Quickdraw::Test
	test "#assert_equal_ruby pass" do
		assert_test(passes: 1) do
			assert_equal_ruby "foo = 1", "foo = 1"
		end
	end

	test "#assert_equal_ruby failure" do
		assert_test(failures: 1) do
			assert_equal_ruby "foo = 1", "foo = 2"
		end
	end

	test "#assert_equal_ruby raises when actual is not a string" do
		assert_raises(ArgumentError) do
			assert_equal_ruby 1, "foo = 1"
		end
	end

	test "#assert_equal_ruby raises when expected is not a string" do
		assert_raises(ArgumentError) do
			assert_equal_ruby "foo = 1", 1
		end
	end
end
