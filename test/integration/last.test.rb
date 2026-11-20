# frozen_string_literal: true

require_relative "../support/integration"

class LastTest < Quickdraw::Test
	include Integration

	def failing = project(
		"test/math.test.rb" => <<~RUBY,
			class MathTest < Quickdraw::Test
				test("adds") { assert_equal 3, 1 + 1 }
				test("subtracts") { assert_equal 0, 1 - 1 }
			end
		RUBY
	)

	test "shows an agent the last run's problems, however it was shown at the time", timeout: 20 do
		project = failing
		project.run("--format", "human", "test/math.test.rb")
		last = project.run("last")

		assert last.success?
		assert_match last.stdout, %r{\ARan `\S+ --format human test/math\.test\.rb` \d+s ago\.\n}
		assert_includes last.stdout, "FAILED test/math.test.rb:2 MathTest › adds"
		assert_includes last.stdout, "Expected  2"
		assert_match last.stdout, /^FAILED: 2 tests, 1 passed, 1 failed in /
	end

	test "says when no run has been recorded", timeout: 20 do
		project = failing
		project.run("--no-history")
		last = project.run("last")

		assert_equal last.exit_status, 1
		assert_includes last.stderr, "No run has been recorded here."
	end
end
