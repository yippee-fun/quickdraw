# frozen_string_literal: true

class DifferenceTest < Quickdraw::Test
	test "#assert_difference passes if the block changes the value by the difference, and returns the block's value" do
		items = []
		returned = nil

		assert_test(passes: 2) do
			returned = assert_difference(-> { items.size }) { items << 1; :done }
			assert_difference(-> { items.size }, 2) { items.push(2, 3) }
		end

		assert_equal returned, :done
	end

	test "#assert_difference fails with how much the value changed" do
		items = []

		runner = assert_test(failures: 1) do
			assert_difference(-> { items.size }, 2) { items << 1 }
		end

		assert_match runner.failures.first["message"], %r{\Aexpected the value at test/assertions/difference\.test\.rb:\d+ to change by 2, but it changed by 1, from 0 to 1\z}
	end

	test "#assert_difference adds the difference to floats rather than subtracting them" do
		value = 0.2

		assert_test(passes: 1) do
			assert_difference(-> { value }, 0.1) { value += 0.1 }
		end
	end

	test "#assert_difference checks each expression in a Hash or Array" do
		users = []
		posts = [1]

		assert_test(passes: 3, failures: 1) do
			assert_difference(-> { users.size } => 1, -> { posts.size } => -1) { users << 1; posts.pop }
			assert_difference([-> { users.size }, -> { posts.size }], 1) { users << 1 }
		end
	end

	test "#assert_difference takes something to call" do
		assert_test(errors: 1) do
			assert_difference("User.count") { nil }
		end
	end

	test "#assert_no_difference" do
		items = []

		assert_test(passes: 1, failures: 1) do
			assert_no_difference(-> { items.size }) { nil }
			assert_no_difference(-> { items.size }) { items << 1 }
		end
	end

	test "#assert_changes passes if the value changes, from and to what's given" do
		value = "a"

		assert_test(passes: 3) do
			assert_changes(-> { value }) { value = "b" }
			assert_changes(-> { value }, from: "b", to: "c") { value = "c" }
			assert_changes(-> { value }, from: String, to: nil) { value = nil }
		end
	end

	test "#assert_changes fails if the value doesn't change, or isn't from or to what's given" do
		value = "a"

		runner = assert_test(failures: 3) do
			assert_changes(-> { value }) { nil }
			assert_changes(-> { value }, from: "x") { value = "b" }
			assert_changes(-> { value }, to: "x") { value = "c" }
		end

		messages = runner.failures.map { |failure| failure["message"].sub(/\Aexpected the value at \S+ /, "") }
		assert_equal messages, [%(to change, but it stayed "a"), %(to change from "x", but it was "a"), %(to change to "x", but it changed to "c")]
	end

	test "#assert_no_changes" do
		value = "a"

		assert_test(passes: 2, failures: 2) do
			assert_no_changes(-> { value }) { nil }
			assert_no_changes(-> { value }, from: "a") { nil }
			assert_no_changes(-> { value }, from: "x") { nil }
			assert_no_changes(-> { value }) { value = "b" }
		end
	end
end
