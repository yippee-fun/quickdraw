# frozen_string_literal: true

class NilTest < Quickdraw::Test
	test "#assert_nil" do
		assert_test(passes: 1) { assert_nil nil }
		assert_test(failures: 1) { assert_nil false }
	end

	test "#refute_nil" do
		assert_test(passes: 1) { refute_nil false }
		assert_test(failures: 1) { refute_nil nil }
	end
end
