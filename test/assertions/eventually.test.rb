# frozen_string_literal: true

class EventuallyTest < Quickdraw::Test
	test "#assert_eventually passes once the block is truthy" do
		ready = false
		Thread.new { sleep 0.02; ready = true }

		assert_test(passes: 1) { assert_eventually { ready } }
	end

	test "#assert_eventually fails if the block never is, saying for how long" do
		runner = assert_test(failures: 1) { assert_eventually(within: 0.03) { false } }

		assert_match runner.failures.first["message"], /\Aexpected the block to return something truthy within 0\.03s, but it didn't in \d+ tries\z/
	end
end
