# frozen_string_literal: true

class RefuteTest < Quickdraw::Test
	test "#refute pass" do
		assert_test(passes: 1) do
			refute false
		end
	end

	test "#refute failure has a default message" do
		runner = assert_test(failures: 1) do
			refute 1
		end

		assert_equal runner.failures.last["message"], "expected 1 to be falsy"
	end

	test "#refute passes the value to its message block" do
		runner = assert_test(failures: 1) do
			refute(:value) { |value| "got #{value.inspect}" }
		end

		assert_equal runner.failures.last["message"], "got :value"
	end
end
