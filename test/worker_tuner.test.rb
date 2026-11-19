# frozen_string_literal: true

class WorkerTunerTest < Quickdraw::Test
	def tuner = Quickdraw::WorkerTuner.new(cores: 8, max: 36)

	def expected(test_time: 10.0, tests: 1000, longest_test: 0.01)
		Quickdraw::History::Expected.new(test_time:, tests:, longest_test:)
	end

	# Newest first, as History#recent_runs returns them.
	def runs(*specs)
		specs.map { |processes, duration, choice = "tuned"| Quickdraw::History::Run.new(processes, duration, choice, 100) }
	end

	def choose(runs: [], expected: self.expected, waiting_share: 0.0)
		tuner.choose(runs:, expected:, waiting_share:)
	end

	test "estimates the core count for CPU-bound tests" do
		assert_equal choose, Quickdraw::WorkerTuner::Choice.new(8, "estimated")
	end

	test "estimates more workers for tests that mostly wait" do
		assert_equal choose(waiting_share: 0.75).processes, 32
		assert_equal choose(waiting_share: 1.0).processes, 36
	end

	test "estimates fewer workers for a small suite" do
		assert_equal choose(expected: expected(test_time: 0.1, tests: 100)).processes, 2
	end

	test "counts per-test overhead for suites of very fast tests" do
		assert_equal choose(expected: expected(test_time: 0.08, tests: 20_000, longest_test: 0.0001)).processes, 6
	end

	test "doesn't estimate past what the longest test allows" do
		assert_equal choose(expected: expected(test_time: 2.0, longest_test: 1.0), waiting_share: 1.0).processes, 2
	end

	test "uses the core count when there's no history for the tests" do
		assert_equal choose(expected: expected(test_time: 0.0, tests: 0, longest_test: nil)).processes, 8
	end

	test "uses the count with the fastest recent runs" do
		choice = choose(runs: runs([8, 1.0], [6, 1.4, "exploring"], [8, 1.1], [8, 0.9, "estimated"]))
		assert_equal choice, Quickdraw::WorkerTuner::Choice.new(8, "tuned")
	end

	test "explores a neighbouring count after enough runs" do
		choice = choose(runs: runs([8, 1.0], [8, 1.0], [8, 1.0], [8, 1.0, "estimated"]))
		assert_equal choice.reason, "exploring"
		assert_includes [6, 11], choice.processes
	end

	test "tries a far-off estimate straight away" do
		choice = choose(runs: runs([8, 1.0, "estimated"]), waiting_share: 1.0)
		assert_equal choice, Quickdraw::WorkerTuner::Choice.new(36, "exploring")
	end

	test "keeps exploring in the same direction after a faster count" do
		choice = choose(runs: runs([11, 0.8, "exploring"], [8, 1.0], [8, 1.0], [8, 1.0], [8, 1.0, "estimated"]))
		assert_equal choice, Quickdraw::WorkerTuner::Choice.new(15, "exploring")
	end

	test "waits longer after an exploration that didn't help" do
		history = runs([8, 1.0], [8, 1.0], [8, 1.0], [8, 1.0], [6, 1.3, "exploring"], [8, 1.0], [8, 1.0], [8, 1.0], [8, 1.0, "estimated"])
		assert_equal choose(runs: history).reason, "tuned"
	end

	test "prefers fewer workers when counts are within noise of each other" do
		choice = choose(runs: runs([11, 1.01, "exploring"], [8, 1.0], [8, 1.0], [8, 1.0, "estimated"]))
		assert_equal choice, Quickdraw::WorkerTuner::Choice.new(8, "tuned")
	end

	test "tries finer steps once the coarse ones are tried" do
		settled = runs([8, 1.0]) * 16
		explored = runs([11, 1.2, "exploring"], [8, 1.0], [6, 1.3, "exploring"], [8, 1.0, "estimated"])
		choice = choose(runs: settled + explored)

		assert_equal choice.reason, "exploring"
		assert_includes [7, 9], choice.processes
	end

	test "ignores runs that ran far fewer tests" do
		history = [Quickdraw::History::Run.new(4, 0.1, "exploring", 3), *runs([8, 1.0], [8, 1.0], [8, 1.0, "estimated"])]
		assert_equal choose(runs: history).processes, 8
	end
end
