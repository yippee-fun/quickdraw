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

	test "a name must be a String" do
		assert_raises(ArgumentError) { Quickdraw::Counters.add(:queries) }
	end
end
