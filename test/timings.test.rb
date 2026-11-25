# frozen_string_literal: true

class TimingsTest < Quickdraw::Test
	def record(timings, durations, path: "a.test.rb")
		durations.each_with_index do |duration, index|
			timings.record(path, { "line" => index }, { "duration" => duration, "stats" => [0.1, duration, 0.2, duration, 0.0, 3] })
		end
	end

	test "keeps only the slowest tests, slowest first" do
		timings = Quickdraw::Timings.new(keep: 3)
		record(timings, [0.4, 0.1, 0.9, 0.3, 0.9, 0.2, 0.5])

		assert_equal timings.slowest_tests.map(&:duration), [0.9, 0.9, 0.5]
		assert_equal timings.slowest_tests.map { |test| test.test["line"] }.sort, [2, 4, 6]
		assert_equal timings.slowest.duration, 0.9
	end

	test "keeps every test when there are fewer than it keeps" do
		timings = Quickdraw::Timings.new(keep: 10)
		record(timings, [0.2, 0.3, 0.1])

		assert_equal timings.slowest_tests.map(&:duration), [0.3, 0.2, 0.1]
	end

	test "keeps the slowest test by default" do
		timings = Quickdraw::Timings.new
		assert_equal timings.slowest, nil

		record(timings, [0.2, 0.3, 0.1])

		assert_equal timings.slowest.duration, 0.3
		assert_equal timings.slowest.test, { "line" => 1 }
		assert_equal timings.slowest_tests.size, 1
	end

	test "totals every test, kept or not" do
		timings = Quickdraw::Timings.new
		record(timings, [0.25, 0.5], path: "a.test.rb")
		record(timings, [0.5], path: "b.test.rb")
		record(timings, [0.25], path: +"a.test.rb")

		assert_equal timings.count, 4
		assert_equal timings.test_time, 1.5
		assert_equal timings.allocations_per_test, 3
		assert_equal timings.slowest_files(2), [["a.test.rb", 1.0, 3], ["b.test.rb", 0.5, 1]]
	end

	test "ignores results without a duration" do
		timings = Quickdraw::Timings.new
		timings.record("a.test.rb", { "line" => 1 }, { "duration" => nil })

		assert_equal timings.count, 0
	end
end
