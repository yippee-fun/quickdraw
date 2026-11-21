# frozen_string_literal: true

class AroundTestTest < Quickdraw::Test
	test "around_test callbacks nest, the first defined outermost, and see the test" do
		config = Quickdraw::Configuration.new
		calls = []

		config.around_test { |test, run| calls << [:outer, test]; run.call; calls << :outer_done }
		config.around_test { |_test, run| calls << :inner; run.call; calls << :inner_done }
		config.around(:a_test) { calls << :test }

		assert_equal calls, [[:outer, :a_test], :inner, :test, :inner_done, :outer_done]
	end

	test "around runs the block alone without callbacks" do
		assert_equal Quickdraw::Configuration.new.around(:a_test) { :result }, :result
	end
end

class CountersTest < Quickdraw::Test
	test "totals each name's count and time until taken" do
		Quickdraw::Counters.take
		Quickdraw::Counters.add("queries", 0.5)
		Quickdraw::Counters.add("queries", 0.25)
		Quickdraw::Counters.add("emails")

		assert_equal Quickdraw::Counters.take, { "queries" => [2, 0.75], "emails" => [1, 0.0] }
		assert_equal Quickdraw::Counters.take, {}
	end

	test "counts what a thread the test started adds, and what any other thread adds meanwhile" do
		Quickdraw::Counters.take
		waiting = Thread::Queue.new
		outsider = Thread.new { waiting.pop; Quickdraw::Counters.add("outside") }

		Quickdraw::Counters.start
		Thread.new { Quickdraw::Counters.add("inside", 0.5) }.join
		waiting << true
		outsider.join

		assert_equal Quickdraw::Counters.take, { "inside" => [1, 0.5], "outside" => [1, 0.0] }
		assert_equal Quickdraw::Counters.take, {}
	end

	test "start forgets what was counted before it" do
		Quickdraw::Counters.take
		Quickdraw::Counters.add("before")
		Quickdraw::Counters.start

		assert_equal Quickdraw::Counters.take, {}

		Quickdraw::Counters.start
		Quickdraw::Counters.add("after")

		assert_equal Quickdraw::Counters.take, { "after" => [1, 0.0] }
	end

	test "what a thread the test left running adds later isn't the next test's" do
		Quickdraw::Counters.start
		waiting = Thread::Queue.new
		left_running = Thread.new { waiting.pop; Quickdraw::Counters.add("late") }
		Quickdraw::Counters.take

		Quickdraw::Counters.start
		waiting << true
		left_running.join

		assert_equal Quickdraw::Counters.take, {}
	end

	# With nothing counted yet, take could return early. An add that's under
	# way, which holds the lock, would then finish first and still be missed.
	test "take waits for an add that's under way, even with nothing counted yet" do
		Quickdraw::Counters.take
		taking = nil

		Quickdraw::Counters.instance_variable_get(:@mutex).synchronize do
			taking = Thread.new { Quickdraw::Counters.take }
			assert_nil taking.join(0.05)
		end

		assert_equal taking.value, {}
	end

	test "a name must be a String" do
		assert_raises(ArgumentError) { Quickdraw::Counters.add(:queries) }
	end
end
