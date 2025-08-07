# frozen_string_literal: true

test "assert" do
	assert true
end

test "assert", skip: true do
	assert false
end

test "refute" do
	refute false
end

test "refute", skip: true do
	refute true
end

test "refute custom message" do
	runner = assert_test(failures: 1) do
		refute(32) { |val| "#{val} not falsy" }
	end
	assert_equal runner.failures.last["message"], "32 not falsy"
end

test "refute default message" do
	runner = assert_test(failures: 1) do
		refute 32
	end
	assert_equal runner.failures.last["message"], "expected 32 to be falsy"
end
