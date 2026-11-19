# frozen_string_literal: true

class SkipTest < Quickdraw::Test
	test "skip stops the test and records a reason" do
		ran_after_skip = false

		runner = assert_test(passes: 1) do
			assert true
			skip "not on this platform"
			ran_after_skip = true
		end

		refute ran_after_skip
		assert_equal runner.skipped, { "pending" => false, "reason" => "not on this platform" }
	end

	test "skip isn't caught by the test's own rescue" do
		runner = assert_test do
			skip
		rescue => error
			assert(false) { "rescued #{error.inspect}" }
		end

		assert_equal runner.skipped, { "pending" => false, "reason" => nil }
	end

	test "skip still runs teardown and deferred blocks" do
		cleaned_up = false

		assert_test do
			defer { cleaned_up = true }
			skip
		end

		assert cleaned_up
	end
end
