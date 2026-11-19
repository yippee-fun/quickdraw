# frozen_string_literal: true

class InterruptTest < Quickdraw::Test
	test "Ctrl-C during teardown still runs deferred blocks, then stops the worker" do
		deferred_ran = false
		interrupted_in_teardown = Class.new(Quickdraw::Test) { def teardown = raise(Quickdraw::Interrupted) }
		runner = Runner.new

		assert_raises(Quickdraw::Interrupted) do
			interrupted_in_teardown.new(description: nil, block: proc { defer { deferred_ran = true } }, runner:).run
		end

		assert deferred_ran
		assert_equal runner.errors, []
	end

	test "Ctrl-C in a deferred block still runs the rest" do
		ran = []
		runner = Runner.new

		block = proc do
			defer { ran << :first }
			defer { raise Quickdraw::Interrupted }
		end

		assert_raises(Quickdraw::Interrupted) { Quickdraw::Test.new(description: nil, block:, runner:).run }
		assert_equal ran, [:first]
	end
end
