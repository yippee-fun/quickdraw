# frozen_string_literal: true

class DeferTest < Quickdraw::Test
	test "runs deferred blocks after the test, in reverse order" do
		order = []

		assert_test(passes: 1) do
			defer { order << :first }
			defer { order << :second }
			order << :test
			assert true
		end

		assert_equal order, [:test, :second, :first]
	end

	test "runs deferred blocks when the test fails or raises" do
		ran = []

		assert_test(failures: 1) do
			defer { ran << :failed }
			assert false
		end

		assert_test(errors: 1) do
			defer { ran << :raised }
			raise "boom"
		end

		assert_equal ran, [:failed, :raised]
	end

	test "reports an error in a deferred block and still runs the others" do
		ran = false

		assert_test(passes: 1, errors: 1) do
			defer { ran = true }
			defer { raise "cleanup failed" }
			assert true
		end

		assert ran
	end
end
